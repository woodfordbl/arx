// proc_host.c: the browser side of the platform section in base.h, on the
// host interface ABI v1 that arx.js serves (plans/0.2.0/wasm.md). It takes
// the place of proc.c and proc_posix.c in `make wasm`: children and HTTP
// requests are handles in the runtime, and poll and sleep suspend through
// JSPI. When either returns -3, the page pressed Stop, and arx takes its
// Ctrl-C path. There is no exec, observer or signal here. ProcStop and
// ProcClose are stubs until the ABI can stop a child and close its stdin.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wasi/api.h>

#include "src/base/base.h"

// The imports of module "arx", ABI v1, put after each declaration.
#define ARX_IMPORT(name) \
  __attribute__((import_module("arx"), import_name(#name)))

// Starts a fetch; returns its id, or -errno.
int32_t HostHttpOpen(const char* req, size_t req_len, const char* body,
                     size_t body_len) ARX_IMPORT(http_open);

// Starts a child; returns its id, or -ENOENT when no runner takes argv[0].
int32_t HostTaskStart(const char* req, size_t req_len, const char* in,
                      size_t in_len) ARX_IMPORT(task_start);

// Waits for any of `ids`; returns how many are ready, or -3 on Stop.
int32_t HostPoll(const int32_t* ids, int32_t n, int32_t ms) ARX_IMPORT(poll);

// Reads stream 1, 2 or 3: bytes, 0 at the end, -2 when nothing waits.
int32_t HostRead(int32_t id, int32_t stream, char* buf, size_t cap)
    ARX_IMPORT(read);

// Writes to the stdin of an `open_in` child; returns the bytes taken.
int32_t HostWrite(int32_t id, const char* buf, size_t len) ARX_IMPORT(write);

// Writes the handle's status as JSON; returns its length.
int32_t HostStatus(int32_t id, char* out, size_t cap) ARX_IMPORT(status);

// Stops the child or aborts the fetch, and frees the handle.
void HostClose(int32_t id) ARX_IMPORT(close);

// 1 when a runner takes the file at `path`.
int32_t HostRunnable(const char* path, size_t len) ARX_IMPORT(runnable);

// Waits `ms`; returns 0, or -3 on Stop.
int32_t HostSleep(int32_t ms) ARX_IMPORT(sleep);

// What the runtime returns when the page pressed Stop.
static const int32_t kStopped = -3;

// A child or an HTTP request: a runtime handle and what arx keeps of it.
struct ProcChild {
  Proc p;       // a copy; its buffers and contexts belong to the caller
  int32_t id;   // the runtime's handle, or 0 once closed
  Buffer more;  // stdin queued by ProcWrite
  size_t written;
  int closing, done, ended[4];
  ProcResult r;
  int http_status, net_error;  // a request's status
  double retry_after;
  Buffer err;  // a request's error text
};

// The session-lived children that every ProcPoll round serves.
static ProcChild** g_kept;
static int g_kept_count, g_kept_cap;

// The platform section: what a browser cannot do, and the waits.
void ProcInit(void) {}

// No exec in a browser; see base.h.
int ProcExec(char* const* argv, int null_stdin) {
  (void)argv;
  (void)null_stdin;
  errno = ENOSYS;
  return -1;
}

// The runtime decides what can run; see base.h.
int IsRunnable(const char* path) {
  return HostRunnable(path, strlen(path)) == 1;
}

// No `sh -c` for observers in a browser; see base.h.
int ProcObserverStart(const char* command, char* const* env, int* pid) {
  (void)command;
  (void)env;
  (void)pid;
  errno = ENOSYS;
  return -1;
}

// No observers, so nothing to wait for; see base.h.
void ProcObserverWait(int pid, double secs) {
  (void)pid;
  (void)secs;
}

// `--events -` needs dup, which WASI lacks; see base.h.
int ProcDupStdout(void) { return -1; }

// A timer in the runtime; Stop ends it early. See base.h.
void SleepSeconds(double s) {
  if (s <= 0 || g_interrupted) return;
  if (HostSleep((int32_t)(s * 1000)) == kStopped) g_interrupted = 1;
}

// A new child for handle `id`.
static ProcChild* NewChild(const Proc* p, int32_t id) {
  ProcChild* c = XMalloc(sizeof(*c));
  memset(c, 0, sizeof(*c));
  c->p = *p;
  c->id = id;
  c->retry_after = -1;
  return c;
}

// Sends a JSON request (consumed) to `start`. Returns the handle, or 0.
static int32_t Open(cJSON* req, const char* data, size_t len,
                    int32_t (*start)(const char*, size_t, const char*,
                                     size_t)) {
  char* text = cJSON_PrintUnformatted(req);
  cJSON_Delete(req);
  int32_t id = start(text, strlen(text), data, data ? len : 0);
  free(text);
  if (id > 0) return id;
  errno = id < 0 ? -id : EIO;
  return 0;
}

// Adds a NULL-terminated list of strings to `o` as an array.
static void AddList(cJSON* o, const char* key, char* const* list) {
  cJSON* a = cJSON_AddArrayToObject(o, key);
  for (char* const* s = list; s && *s; s++) {
    cJSON_AddItemToArray(a, cJSON_CreateString(*s));
  }
}

// Starts a child in the runtime; see base.h.
ProcChild* ProcStart(const Proc* p) {
  cJSON* req = cJSON_CreateObject();
  AddList(req, "argv", p->argv);
  AddList(req, "env", p->env);
  if (p->dir) cJSON_AddStringToObject(req, "cwd", p->dir);
  cJSON_AddNumberToObject(req, "timeout_ms", p->timeout * 1000);
  cJSON_AddBoolToObject(req, "open_in", p->open_in);
  cJSON_AddBoolToObject(req, "fd3", p->on_fd3 != NULL);
  cJSON_AddBoolToObject(req, "keep_on_interrupt", p->keep_on_interrupt);
  int32_t id = Open(req, p->in, p->in_len, HostTaskStart);
  return id ? NewChild(p, id) : NULL;
}

// Starts a fetch; see base.h. The headers stay in memory.
ProcChild* HttpStart(const HttpRequest* req) {
  cJSON* r = cJSON_CreateObject();
  const char* method = req->method ? req->method : req->body ? "POST" : "GET";
  cJSON_AddStringToObject(r, "method", method);
  cJSON_AddStringToObject(r, "url", req->url);
  cJSON* headers = cJSON_AddArrayToObject(r, "headers");
  for (const char* line = req->headers; line && *line;) {
    size_t len = strcspn(line, "\n");
    const char* colon = memchr(line, ':', len);
    if (colon) {
      const char* value = colon + 1 + strspn(colon + 1, " ");
      char* name = XStrndup(line, (size_t)(colon - line));
      char* text = XStrndup(value, len - (size_t)(value - line));
      cJSON* pair = cJSON_CreateArray();
      cJSON_AddItemToArray(pair, cJSON_CreateString(name));
      cJSON_AddItemToArray(pair, cJSON_CreateString(text));
      cJSON_AddItemToArray(headers, pair);
      free(name);
      free(text);
    }
    line += len + (line[len] == '\n');
  }
  cJSON_AddNumberToObject(r, "timeout_ms", req->timeout * 1000);
  if (req->adapter) cJSON_AddStringToObject(r, "adapter", req->adapter);
  int32_t id = Open(r, req->body, req->body_len, HostHttpOpen);
  Proc p = {.on_out = req->on_body, .out_ctx = req->body_ctx};
  return id ? NewChild(&p, id) : NULL;
}

// Queues stdin; see base.h.
void ProcWrite(ProcChild* c, const char* data, size_t n) {
  if (c->id && !c->closing && !c->done) BufferAppend(&c->more, data, n);
}

// A stub until the ABI can close a child's stdin: later writes are dropped.
void ProcClose(ProcChild* c) { c->closing = 1; }

// True when the child has ended and its output is read; see base.h.
int ProcDone(const ProcChild* c) { return c->done; }

// Ends a child at once, as a stop would: SIGTERM's code, output so far.
static void Stopped(ProcChild* c) {
  if (c->done) return;
  if (c->id) HostClose(c->id);
  c->id = 0;
  c->r.code = 128 + 15;
  c->done = 1;
}

// A stub until the ABI can stop a child without freeing it: ends it at once.
void ProcStop(ProcChild* c) { Stopped(c); }

// Writes what the child's stdin can take now.
static void Feed(ProcChild* c) {
  size_t n = c->more.len - c->written;
  if (!n) return;
  int32_t w = HostWrite(c->id, c->more.data + c->written, n);
  if (w > 0) c->written += (size_t)w;
  if (c->written == c->more.len) c->more.len = c->written = 0;
}

// Reads every stream that has bytes into its DataFn.
static void Drain(ProcChild* c) {
  static char chunk[65536];
  DataFn fns[] = {NULL, c->p.on_out, c->p.on_err ? c->p.on_err : c->p.on_out,
                  c->p.on_fd3};
  void* ctxs[] = {NULL, c->p.out_ctx, c->p.on_err ? c->p.err_ctx : c->p.out_ctx,
                  c->p.fd3_ctx};
  for (int s = 1; s <= 3; s++) {
    while (!c->ended[s]) {
      int32_t n = HostRead(c->id, s, chunk, sizeof(chunk));
      if (n > 0 && fns[s]) fns[s](ctxs[s], chunk, (size_t)n);
      if (n == 0 || (n < 0 && n != -2)) c->ended[s] = 1;
      if (n <= 0) break;
    }
  }
}

// Reads the handle's status. Returns 1 when it has ended.
static int Status(ProcChild* c) {
  char small[4096];
  char* out = small;
  int32_t n = HostStatus(c->id, out, sizeof(small) - 1);
  if (n >= (int32_t)sizeof(small)) {
    out = XMalloc((size_t)n + 1);
    n = HostStatus(c->id, out, (size_t)n);
  }
  out[n > 0 ? n : 0] = 0;
  cJSON* s = cJSON_Parse(out);
  if (out != small) free(out);
  int done = JsonBool(s, "done", 0);
  if (done) {
    c->r.code = (int)JsonNum(s, "code", 0);
    c->r.timed_out = JsonBool(s, "timed_out", 0);
    c->r.secs = JsonNum(s, "secs", 0);
    c->http_status = (int)JsonNum(s, "http_status", 0);
    c->retry_after = JsonNum(s, "retry_after", -1);
    c->net_error = (int)JsonNum(s, "net_error", 0);
    const char* error = JsonStr(s, "error", NULL);
    if (error) BufferAppendStr(&c->err, error);
  }
  cJSON_Delete(s);
  return done;
}

// Serves one child after a wait: stdin, output, Ctrl-C and its end.
static void Serve(ProcChild* c) {
  if (g_interrupted && !c->p.keep_on_interrupt) {
    Drain(c);
    c->r.interrupted = 1;
    Stopped(c);
    return;
  }
  Feed(c);
  Drain(c);
  if (!Status(c)) return;
  Drain(c);  // what came after the last read, up to the end of each stream
  c->done = 1;
}

// One round for the children and the kept ones; see base.h.
void ProcPoll(ProcChild* const* kids, int count, double max_wait) {
  ProcChild** all = XMalloc((size_t)(count + g_kept_count + 1) * sizeof(*all));
  int32_t* ids = XMalloc((size_t)(count + g_kept_count + 1) * sizeof(*ids));
  int m = 0;
  for (int k = 0; k < count; k++) all[m++] = kids[k];
  for (int j = 0; j < g_kept_count; j++) {
    int listed = 0;
    for (int k = 0; k < count && !listed; k++) listed = kids[k] == g_kept[j];
    if (!listed) all[m++] = g_kept[j];
  }
  int n = 0;
  for (int k = 0; k < m; k++) {
    if (!all[k]->done) ids[n++] = all[k]->id;
  }
  double wait = max_wait > 0.1 ? 0.1 : max_wait < 0 ? 0 : max_wait;
  if (HostPoll(ids, n, (int32_t)(wait * 1000) + 1) == kStopped) {
    g_interrupted = 1;
  }
  for (int k = 0; k < m; k++) {
    if (!all[k]->done) Serve(all[k]);
  }
  free(ids);
  free(all);
}

// The browser has no descriptors to wait on; see base.h.
void ProcPollWith(ProcChild* const* kids, int n, struct pollfd* extra,
                  int n_extra, double max_wait) {
  (void)extra;
  (void)n_extra;
  ProcPoll(kids, n, max_wait);
}

// Keeps a child for the session; see base.h.
void ProcKeep(ProcChild* c) {
  for (int k = 0; k < g_kept_count; k++) {
    if (g_kept[k] == c) return;
  }
  if (g_kept_count == g_kept_cap) {
    g_kept_cap = g_kept_cap ? 2 * g_kept_cap : 8;
    g_kept = XRealloc(g_kept, (size_t)g_kept_cap * sizeof(*g_kept));
  }
  g_kept[g_kept_count++] = c;
}

// Stops keeping a child; see base.h.
void ProcRelease(ProcChild* c) {
  for (int k = 0; k < g_kept_count; k++) {
    if (g_kept[k] != c) continue;
    g_kept[k] = g_kept[--g_kept_count];
    return;
  }
}

// Stops a child that still runs, frees its handle and the child.
static void Free(ProcChild* c) {
  ProcRelease(c);
  Stopped(c);
  BufferFree(&c->more);
  BufferFree(&c->err);
  free(c);
}

// Fills `r` and frees the child; see base.h.
void ProcFinish(ProcChild* c, ProcResult* r) {
  if (!c->done) c->r.interrupted = g_interrupted && !c->p.keep_on_interrupt;
  if (c->id) HostClose(c->id);
  c->id = 0;
  Stopped(c);
  *r = c->r;
  Free(c);
}

// Runs a child to its end; see base.h.
int ProcRun(const Proc* p, ProcResult* r) {
  ProcChild* c = ProcStart(p);
  if (!c) {
    memset(r, 0, sizeof(*r));
    r->code = -1;
    r->spawn_failed = 1;
    return -1;
  }
  while (!c->done) ProcPoll(&c, 1, 0.1);
  ProcFinish(c, r);
  return 0;
}

// Ends a request and frees it; see base.h.
void HttpFinish(ProcChild* c, HttpResult* r) {
  int ended = c->done && !c->r.interrupted;
  memset(r, 0, sizeof(*r));
  r->status = ended ? c->http_status : 0;
  r->retry_after = ended ? c->retry_after : -1;
  r->net_error = ended ? c->net_error : 0;
  r->interrupted = c->r.interrupted || (!c->done && g_interrupted);
  r->secs = c->r.secs;
  r->err = c->err;
  memset(&c->err, 0, sizeof(c->err));
  ProcResult ignored;
  ProcFinish(c, &ignored);
}

// arx's entry point, in src/main.c.
int main(int argc, char** argv);

// What arx.js calls for each run; a reactor never exits, so flush here.
__attribute__((export_name("arx_main"))) int ArxMain(void) {
  size_t argc = 0, size = 0;
  if (__wasi_args_sizes_get(&argc, &size)) return kExitError;
  char** argv = XMalloc((argc + 1) * sizeof(*argv));
  char* buf = XMalloc(size ? size : 1);
  if (__wasi_args_get((uint8_t**)argv, (uint8_t*)buf)) return kExitError;
  argv[argc] = NULL;
  int code = main((int)argc, argv);
  fflush(NULL);
  free(buf);
  free(argv);
  return code;
}

// The ABI version, which arx.js checks before the first run.
__attribute__((export_name("arx_abi"))) int ArxAbi(void) { return 1; }
