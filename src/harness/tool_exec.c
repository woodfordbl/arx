// tool_exec.c: runs one tool call. Output goes to a file in the session, and
// the model sees only its head and tail. Subagents are this same binary run
// one level deeper, with their events forwarded into ours.

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// Captured output: the head and tail in memory, everything in a file.
typedef struct Capture {
  Buffer head, tail;
  size_t total, head_max, tail_max;
  int fd;
} Capture;

// DataFn: saves output to the file and keeps the head and the tail.
static void CaptureSink(void* ctx, const char* data, size_t n) {
  Capture* c = ctx;
  if (c->fd >= 0) WriteAll(c->fd, data, n);
  c->total += n;
  if (c->head.len < c->head_max) {
    size_t room = c->head_max - c->head.len;
    BufferAppend(&c->head, data, n < room ? n : room);
  }
  BufferAppend(&c->tail, data, n);
  if (c->tail.len > 2 * c->tail_max + 65536) {  // trim now and then, not always
    memmove(c->tail.data, c->tail.data + c->tail.len - c->tail_max,
            c->tail_max);
    c->tail.len = c->tail_max;
  }
}

// What the model sees: all of a short output, or head + marker + tail.
static char* CaptureText(const Capture* c, const char* path) {
  Buffer b = {0};
  BufferAppend(&b, NULL, 0);
  BufferAppend(&b, c->head.data, c->head.len);
  if (c->total > c->head_max + c->tail_max) {
    BufferPrintf(&b, "\n[... %zu bytes omitted; full output: %s ...]\n",
                 c->total - c->head_max - c->tail_max, path);
    BufferAppend(&b, c->tail.data + c->tail.len - c->tail_max, c->tail_max);
  } else if (c->total > c->head_max) {
    size_t rest = c->total - c->head_max;
    BufferAppend(&b, c->tail.data + c->tail.len - rest, rest);
  }
  char* text = Utf8Clean(b.data, b.len);
  BufferFree(&b);
  return text;
}

// ARX_* variables so tools and hooks know where they run.
char** ToolEnv(Agent* a, const char* plugin_dir) {
  char cwd[4096];
  char** env = XMalloc(10 * sizeof(*env));
  env[0] = XAsprintf("ARX_SESSION=%s", a->session.id);
  env[1] = XAsprintf("ARX_SESSION_DIR=%s", a->session.dir);
  env[2] = XAsprintf("ARX_TURN=%d", a->session.turns);
  env[3] = XAsprintf("ARX_CWD=%s", getcwd(cwd, sizeof(cwd)) ? cwd : ".");
  env[4] = XAsprintf("ARX_SPEC=%s", a->spec.path);
  env[5] = XAsprintf("ARX_SPEC_DIR=%s", a->spec.dir);
  env[6] = XAsprintf("ARX_DEPTH=%d", a->depth);
  env[7] = XAsprintf("ARX_BIN=%s", g_self);
  env[8] = plugin_dir ? XAsprintf("ARX_PLUGIN_DIR=%s", plugin_dir) : NULL;
  env[9] = NULL;
  return env;
}

// Frees the strings and the array.
void FreeEnv(char** env) {
  for (char** p = env; *p; p++) free(*p);
  free(env);
}

// Creates `path` with `text`, refusing to overwrite.
static char* CreateFile(const char* path, const char* text, int* is_error) {
  char* dir = DirName(path);
  MakeDirs(dir);
  free(dir);
  if (WriteFileAtomic(path, text, strlen(text))) {
    return XAsprintf("cannot create %s: %s", path, strerror(errno));
  }
  *is_error = 0;
  return XAsprintf("created %s (%zu bytes)", path, strlen(text));
}

// The edit tool: replace one exact, unique occurrence, or create a file.
static char* Edit(cJSON* args, int* is_error) {
  const char* path = JsonStr(args, "path", NULL);
  const char* old = JsonStr(args, "old", NULL);
  const char* new_text = JsonStr(args, "new", NULL);
  *is_error = 1;
  if (!path || !old || !new_text) {
    return XStrdup("edit needs string arguments path, old and new");
  }
  size_t n;
  char* text = ReadFile(path, &n);
  if (!*old) {
    if (!text) return CreateFile(path, new_text, is_error);
    free(text);
    return XAsprintf("%s exists; pass the exact text to replace in `old`",
                     path);
  }
  if (!text) return XAsprintf("cannot read %s: %s", path, strerror(errno));
  size_t old_len = strlen(old), count = 0;
  char* hit = NULL;
  for (char* p = text; (p = memmem(p, n - (size_t)(p - text), old, old_len));
       p += old_len) {
    if (!count++) hit = p;
  }
  char* result;
  if (count != 1) {
    result = count ? XAsprintf(
                         "`old` occurs %zu times in %s; include more "
                         "context so it is unique",
                         count, path)
                   : XAsprintf(
                         "`old` was not found in %s (it must match "
                         "exactly, including whitespace)",
                         path);
  } else {
    Buffer b = {0};
    BufferAppend(&b, text, (size_t)(hit - text));
    BufferAppendStr(&b, new_text);
    BufferAppend(&b, hit + old_len, n - (size_t)(hit - text) - old_len);
    if (WriteFileAtomic(path, b.data, b.len)) {
      result = XAsprintf("cannot write %s: %s", path, strerror(errno));
    } else {
      result = XAsprintf("edited %s", path);
      *is_error = 0;
    }
    BufferFree(&b);
  }
  free(text);
  return result;
}

// DataFn for a subagent's fd 3: forwards each complete event line.
static void ForwardSink(void* ctx, const char* data, size_t n) {
  Buffer* b = ctx;
  BufferAppend(b, data, n);
  char* nl;
  while (b->len && (nl = memchr(b->data, '\n', b->len))) {
    size_t len = (size_t)(nl - b->data) + 1;
    EventForward(b->data, len);
    memmove(b->data, b->data + len, b->len - len);
    b->len -= len;
  }
}

// Runs a subagent: `arx -p - --spec <path> --json --events fd:3`, with our
// caps and one more level of depth.
static void RunSubagent(Agent* a, Tool* t, const char* task, char** env,
                        Capture* cap, Buffer* out, ProcResult* r) {
  Buffer forward = {0};
  int k = 0;
  char** argv = XMalloc((size_t)(12 + 2 * a->cap_count) * sizeof(*argv));
  char* fixed[] = {g_self,   "-p",      "-",        "--spec", t->path,
                   "--json", "--quiet", "--events", "fd:3"};
  for (size_t i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++) {
    argv[k++] = fixed[i];
  }
  for (int i = 0; i < a->cap_count; i++) {
    argv[k++] = "--cap";
    argv[k++] = a->cap_args[i];
  }
  argv[k] = NULL;
  free(env[6]);
  env[6] = XAsprintf("ARX_DEPTH=%d", a->depth + 1);
  Proc p = {.argv = argv,
            .in = task,
            .in_len = strlen(task),
            .timeout = t->timeout,
            .env = env,
            .on_out = BufferSink,
            .out_ctx = out,
            .on_err = CaptureSink,
            .err_ctx = cap,
            .on_fd3 = ForwardSink,
            .fd3_ctx = &forward};
  ProcRun(&p, r);
  free(argv);
  BufferFree(&forward);
}

// Turns a subagent's --json output and exit code into the tool result.
static char* SubagentResult(const Buffer* out, const Capture* cap,
                            const char* path, int code) {
  cJSON* result = cJSON_Parse(out->data ? out->data : "");
  const char* answer = JsonStr(result, "final_output", "");
  char* text;
  if (code == kExitDone) {
    text = XStrdup(answer);
  } else if (code == kExitCap) {
    text = XAsprintf("[the subagent stopped at a cap]\n%s", answer);
  } else {
    char* err = CaptureText(cap, path);
    text = XAsprintf("[the subagent failed with exit %d]\n%s%s", code, answer,
                     err);
    free(err);
  }
  cJSON_Delete(result);
  return text;
}

// Output plus a status line for timeouts, interrupts and non-zero exits.
static char* ProcessResult(const Capture* cap, const char* path,
                           const ProcResult* r, double timeout) {
  char* body = CaptureText(cap, path);
  Buffer b = {0};
  BufferAppendStr(&b, *body || r->code ? body : "(no output)");
  if (r->timed_out) {
    BufferPrintf(&b,
                 "\n[timed out after %.0fs; the process group was "
                 "killed]",
                 timeout);
  } else if (r->interrupted) {
    BufferAppendStr(&b, "\n[interrupted]");
  } else if (r->code) {
    BufferPrintf(&b, "\n[exit code %d]", r->code);
  }
  free(body);
  return BufferTake(&b);
}

// Checks the arguments a tool needs; returns an error message or NULL.
static char* CheckArgs(const Tool* t, cJSON* args) {
  if (t->kind == kToolBash && !JsonStr(args, "command", NULL)) {
    return XStrdup("bash needs a string argument `command`");
  }
  if (t->kind == kToolAgent && !JsonStr(args, "task", NULL)) {
    return XStrdup("this subagent needs a string argument `task`");
  }
  return NULL;
}

// Finds a tool by name, or NULL.
static Tool* FindTool(Agent* a, const char* name) {
  for (int i = 0; i < a->tools.count; i++) {
    if (!strcmp(a->tools.items[i].name, name)) return &a->tools.items[i];
  }
  return NULL;
}

// Runs a process-backed tool (bash, executable or subagent).
static char* RunProcessTool(Agent* a, Tool* t, cJSON* args, const char* raw,
                            int* is_error, char* path, cJSON* end_event) {
  Capture cap = {.head_max = JsonSize(a->spec.root, "tool_output.head", 2048),
                 .tail_max = JsonSize(a->spec.root, "tool_output.tail", 6144)};
  cap.fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  char** env = ToolEnv(a, t->plugin_dir);
  Buffer out = {0};
  ProcResult r;
  char* text;
  if (t->kind == kToolAgent) {
    RunSubagent(a, t, JsonStr(args, "task", ""), env, &cap, &out, &r);
    text = r.spawn_failed ? NULL : SubagentResult(&out, &cap, path, r.code);
  } else {
    char* bash_argv[] = {"sh", "-c", (char*)JsonStr(args, "command", ""), NULL};
    char* exec_argv[] = {t->path, NULL};
    Proc p = {.argv = t->kind == kToolBash ? bash_argv : exec_argv,
              .timeout = t->timeout,
              .env = env,
              .on_out = CaptureSink,
              .out_ctx = &cap};
    if (t->kind == kToolExec) {
      p.in = raw;
      p.in_len = strlen(raw);
    }
    ProcRun(&p, &r);
    text = r.spawn_failed ? NULL : ProcessResult(&cap, path, &r, t->timeout);
  }
  if (!text) text = XAsprintf("could not start the tool: %s", strerror(errno));
  if (cap.fd >= 0) close(cap.fd);
  *is_error = r.spawn_failed || r.code != 0 || r.timed_out;
  cJSON_AddNumberToObject(end_event, "exit", r.code);
  cJSON_AddNumberToObject(end_event, "secs", r.secs);
  cJSON_AddNumberToObject(end_event, "bytes", (double)cap.total);
  cJSON_AddStringToObject(end_event, "path", path);
  BufferFree(&cap.head);
  BufferFree(&cap.tail);
  BufferFree(&out);
  FreeEnv(env);
  return text;
}

// Runs one tool call; see harness.h.
char* ToolCall(Agent* a, const char* name, const char* args, int* is_error,
               char** output_path, cJSON* end_event) {
  *is_error = 1;
  *output_path = NULL;
  Tool* t = FindTool(a, name);
  if (!t) {
    Buffer names = {0};
    for (int i = 0; i < a->tools.count; i++) {
      BufferPrintf(&names, "%s%s", i ? ", " : "", a->tools.items[i].name);
    }
    char* text = XAsprintf("unknown tool \"%s\" (available: %s)", name,
                           names.data ? names.data : "none");
    BufferFree(&names);
    return text;
  }
  const char* raw = args && *args ? args : "{}";
  cJSON* parsed = cJSON_Parse(raw);
  char* text;
  if (!cJSON_IsObject(parsed)) {
    text = XAsprintf("the arguments are not a valid JSON object: %.200s", raw);
  } else if (t->kind == kToolEdit) {
    text = Edit(parsed, is_error);
  } else if (!(text = CheckArgs(t, parsed))) {
    *output_path = SessionOutputPath(&a->session);
    text = RunProcessTool(a, t, parsed, raw, is_error, *output_path, end_event);
  }
  cJSON_Delete(parsed);
  return text;
}
