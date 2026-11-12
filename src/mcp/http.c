// http.c: `arx mcp http`, the bridge that puts one HTTP MCP server behind
// stdio, so the agent process speaks one transport. arx starts it as the
// server's command. It speaks modern MCP to arx, and each request of arx's
// becomes one HttpStart (natively one curl child), so requests run in
// parallel and HTTP, tokens and sign-in stay out of the agent process.

#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

static const int kTransientExits[] = {6, 7, 28, 35, 52, 56, 0};
static const int kTransientStatus[] = {429, 502, 503, 504, 0};
static const double kRetryDelays[] = {1, 4, 16};

// RpcHandlers.write: one line to arx.
static void Write(void* ctx, const char* data, size_t n) {
  (void)ctx;
  WriteAll(1, data, n);
}

// Ends a job with an error for arx; see mcp.h.
void McpHttpFail(Bridge* b, HttpJob* j, const char* fmt, ...) {
  Buffer text = {0};
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(&text, fmt, ap);
  va_end(ap);
  if (j->id) {
    RpcReplyError(b->up, j->id, -32000, text.data, NULL);
  } else {
    fprintf(stderr, "[arx mcp http] %s: %s\n", j->method, text.data);
  }
  BufferFree(&text);
  j->over = 1;
}

// Takes one JSON-RPC message (consumed) of a reply: a notification goes to
// arx at once, and the response waits for the end of the request.
static void Message(Bridge* b, HttpJob* j, cJSON* m) {
  const char* method = JsonStr(m, "method", NULL);
  cJSON* id = cJSON_GetObjectItemCaseSensitive(m, "id");
  if (method && !id) {
    RpcNotify(b->up, method, cJSON_DetachItemFromObject(m, "params"));
  } else if (!method && cJSON_IsObject(m)) {
    cJSON_Delete(j->response);
    j->response = m;
    return;
  } else if (method) {
    fprintf(stderr, "[arx mcp http] ignored the server's request %s\n", method);
  }
  cJSON_Delete(m);
}

// Reads the whole events of a stream that are in j->in; with `final`, also
// the last one, which no blank line ends.
static void Events(Bridge* b, HttpJob* j, int final) {
  for (;;) {
    char* end = j->in.len ? strstr(j->in.data, "\n\n") : NULL;
    if (!end && !(final && j->in.len)) return;
    size_t len = end ? (size_t)(end - j->in.data) : j->in.len;
    Buffer data = {0};
    for (char* line = j->in.data; line < j->in.data + len;) {
      char* nl = memchr(line, '\n', (size_t)(j->in.data + len - line));
      size_t n = nl ? (size_t)(nl - line) : (size_t)(j->in.data + len - line);
      if (n >= 5 && !strncmp(line, "data:", 5)) {
        size_t skip = 5 + (n > 5 && line[5] == ' ');
        if (data.len) BufferAppendStr(&data, "\n");
        BufferAppend(&data, line + skip, n - skip);
      }
      line += n + 1;
    }
    cJSON* m = data.len ? cJSON_Parse(data.data) : NULL;
    if (m) Message(b, j, m);
    BufferFree(&data);
    size_t used = end ? len + 2 : len;
    memmove(j->in.data, j->in.data + used, j->in.len - used + 1);
    j->in.len -= used;
  }
}

static Bridge* g_bridge;  // for OnBody, whose context is the job

// DataFn for a reply's body: `ctx` is the job. The response headers come
// only at the end, so the first bytes tell an event stream (a field name)
// from JSON or an error page.
static void OnBody(void* ctx, const char* data, size_t n) {
  HttpJob* j = ctx;
  for (size_t i = 0; i < n; i++) {
    if (data[i] != '\r') BufferAppend(&j->in, data + i, 1);
  }
  const char* text = j->in.data + strspn(j->in.data, " \n\t");
  if (j->sse < 0 && (strlen(text) >= 6 || strchr(text, '\n'))) {
    static const char* const kFields[] = {
        "data:", "event:", "id:", "retry:", ":"};
    j->sse = 0;
    for (int i = 0; i < 5; i++) {
      j->sse |= !strncmp(text, kFields[i], strlen(kFields[i]));
    }
  }
  if (j->sse == 1) Events(g_bridge, j, 0);
}

// Sends a job's request; see mcp.h.
void McpHttpStart(Bridge* b, HttpJob* j) {
  Buffer why = {0};
  const char* path = JsonStr(b->entry, "credential", NULL);
  int due = !b->credential ||
            (b->expires > 0 && (double)time(NULL) >= b->expires - 60);
  if (path && due &&
      McpHttpCredential(b, b->credential ? "expired" : "start", 0, NULL,
                        &why)) {
    McpHttpFail(b, j, "%s", why.data ? why.data : "the credential failed");
    BufferFree(&why);
    return;
  }
  BufferFree(&why);
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "jsonrpc", "2.0");
  if (j->id) {
    cJSON_AddItemToObject(m, "id", cJSON_Duplicate(j->id, 1));
  } else if (!j->notify) {
    cJSON_AddNumberToObject(m, "id", 1000000 + ++b->next_id);
  }
  cJSON_AddStringToObject(m, "method", j->method);
  if (j->params)
    cJSON_AddItemToObject(m, "params", cJSON_Duplicate(j->params, 1));
  free(j->body);
  free(j->headers);
  j->body = cJSON_PrintUnformatted(m);
  j->headers = McpHttpHeaders(b, j);
  cJSON_Delete(m);
  cJSON_Delete(j->response);
  j->response = NULL;
  j->in.len = 0;
  j->sse = -1;
  j->retry_at = 0;
  j->parked = 0;
  int listen = !strcmp(j->method, "subscriptions/listen");
  j->http = (HttpRequest){
      .method = "POST",
      .url = b->url,
      .headers = j->headers,
      .body = j->body,
      .body_len = strlen(j->body),
      .timeout = listen ? 0 : JsonNum(b->entry, "timeout", 120) + 5,
      .stream = 1,
      .tmp_dir = b->tmp_dir,
      .on_body = OnBody,
      .body_ctx = j};
  j->child = HttpStart(&j->http);
  if (!j->child) McpHttpFail(b, j, "cannot start curl for %s", b->host);
}

// Schedules a transient failure again; see mcp.h.
int McpHttpRetry(HttpJob* j, const HttpResult* r) {
  int transient = 0;
  for (const int* e = kTransientExits; *e; e++) transient |= r->net_error == *e;
  for (const int* s = kTransientStatus; *s; s++) transient |= r->status == *s;
  int safe = !strcmp(j->method, "server/discover") ||
             !strcmp(j->method, "tools/list") ||
             !strcmp(j->method, "initialize");
  if (!transient || !safe || j->attempts >= 3) return 0;
  double wait =
      r->retry_after >= 0 ? r->retry_after : kRetryDelays[j->attempts];
  j->attempts++;
  j->retry_at = Now() + wait;
  return 1;
}

// Sends the job's response to arx.
static void Reply(Bridge* b, HttpJob* j) {
  cJSON* error = cJSON_GetObjectItemCaseSensitive(j->response, "error");
  if (!j->id) {
    // a request of the bridge's own: its done function read the response
  } else if (error) {
    RpcReplyError(b->up, j->id, (int)JsonNum(error, "code", -32000),
                  JsonStr(error, "message", ""),
                  cJSON_DetachItemFromObject(error, "data"));
  } else {
    cJSON* result = cJSON_DetachItemFromObject(j->response, "result");
    if (!result) result = cJSON_CreateObject();
    if (!strcmp(j->method, "tools/list")) McpHttpTools(b, result);
    RpcReply(b->up, j->id, result);
  }
  j->over = 1;
}

// HttpJobDone for a request of arx's: the response, a retry, a fresh
// credential, the legacy fallback, or an error arx can act on.
static void Forward(Bridge* b, HttpJob* j, const HttpResult* r) {
  int s = r->status;
  Buffer why = {0};
  if (j->response && (s / 100 == 2 || JsonGet(j->response, "error"))) {
    b->known = 1;
    Reply(b, j);
  } else if (McpHttpRetry(j, r)) {
    // the main loop sends it again
  } else if ((s == 401 || s == 403) && !j->reauthed &&
             JsonStr(b->entry, "credential", NULL)) {
    char* challenge = McpHttpHeader(r, "www-authenticate");
    j->reauthed = 1;
    if (McpHttpCredential(b, "rejected", s, challenge, &why) == 0) {
      McpHttpStart(b, j);
    } else {
      McpHttpFail(b, j, "%d from %s: %s", s, b->host, why.data);
    }
    free(challenge);
  } else if (b->session && s == 404 && !j->resessioned) {
    j->resessioned = j->parked = 1;  // the session ended: make a new one
    free(b->session);
    b->session = NULL;
    McpHttpLegacy(b);
  } else if (!b->known && !b->legacy && (s == 400 || s == 404 || s == 405)) {
    j->parked = 1;
    McpHttpLegacy(b);
  } else if (s == 202 || (s / 100 == 2 && j->notify)) {
    j->over = 1;
  } else if (s / 100 == 2) {
    McpHttpFail(b, j, "the reply from %s ended without a response", b->host);
  } else if (!s) {
    McpHttpFail(b, j, "cannot reach %s (curl exit %d): %.300s", b->host,
                r->net_error, r->err.data ? r->err.data : "");
  } else if (s == 401 || s == 403) {
    McpHttpFail(b, j,
                JsonStr(b->entry, "credential", NULL)
                    ? "%d from %s: the server rejected the credential of "
                      "mcp_servers.%s twice"
                    : "%d from %s: the server wants a credential. Set "
                      "mcp_servers.%s.credential; the mcp-oauth plugin "
                      "signs in.",
                s, b->host, b->name);
  } else {
    while (j->in.len && strchr(" \n\t", j->in.data[j->in.len - 1])) {
      j->in.data[--j->in.len] = 0;
    }
    McpHttpFail(b, j, "HTTP %d from %s: %.300s", s, b->host,
                j->in.data ? j->in.data : "");
  }
  BufferFree(&why);
}

// Creates and starts a job; see mcp.h.
HttpJob* McpHttpJob(Bridge* b, cJSON* id, const char* method, cJSON* params,
                    HttpJobDone done) {
  HttpJob* j = XMalloc(sizeof(*j));
  memset(j, 0, sizeof(*j));
  j->id = id;
  j->method = XStrdup(method);
  j->params = params;
  j->done = done;
  j->notify = !id && !strncmp(method, "notifications/", 14);
  j->next = b->jobs;
  b->jobs = j;
  if (b->handshaking && id) {
    j->parked = 1;
  } else {
    McpHttpStart(b, j);
  }
  return j;
}

// RpcHandlers.request: a request of arx's becomes one HTTP request.
static void OnRequest(void* ctx, RpcPeer* p, cJSON* id, const char* method,
                      cJSON* params) {
  Bridge* b = ctx;
  if (b->legacy && !b->handshaking && !strcmp(method, "server/discover")) {
    RpcReply(p, id, McpHttpDiscover(b));
    return;
  }
  McpHttpJob(b, cJSON_Duplicate(id, 1), method, cJSON_Duplicate(params, 1),
             Forward);
}

// RpcHandlers.notify: notifications/cancelled stops that request, which
// closes its stream: the HTTP way to cancel.
static void OnNotify(void* ctx, const char* method, cJSON* params) {
  Bridge* b = ctx;
  if (strcmp(method, "notifications/cancelled")) return;
  cJSON* id = cJSON_GetObjectItemCaseSensitive(params, "requestId");
  for (HttpJob* j = b->jobs; j; j = j->next) {
    if (j->id && cJSON_Compare(j->id, id, 1)) j->over = 1;
  }
}

// Frees a job, stopping its request when it still runs.
static void FreeJob(HttpJob* j) {
  if (j->child) {
    HttpResult r;
    HttpFinish(j->child, &r);
    BufferFree(&r.err);
    BufferFree(&r.headers);
  }
  cJSON_Delete(j->id);
  cJSON_Delete(j->params);
  cJSON_Delete(j->response);
  BufferFree(&j->in);
  free(j->method);
  free(j->body);
  free(j->headers);
  free(j);
}

// One round over the jobs: ends the requests that are done, sends the ones
// whose retry is due, and frees the ones that are over.
static void Sweep(Bridge* b) {
  for (HttpJob* j = b->jobs; j; j = j->next) {
    if (j->over) continue;
    if (j->child && ProcDone(j->child)) {
      HttpResult r;
      HttpFinish(j->child, &r);
      j->child = NULL;
      cJSON* m = j->sse != 1 && j->in.len ? cJSON_Parse(j->in.data) : NULL;
      if (j->sse == 1) Events(b, j, 1);
      if (m) Message(b, j, m);
      j->done(b, j, &r);
      BufferFree(&r.err);
      BufferFree(&r.headers);
    } else if (!j->child && j->retry_at && Now() >= j->retry_at) {
      McpHttpStart(b, j);
    }
  }
  for (HttpJob** at = &b->jobs; *at;) {
    HttpJob* j = *at;
    if (!j->over) {
      at = &j->next;
      continue;
    }
    *at = j->next;
    FreeJob(j);
  }
}

// The bridge; see mcp.h.
int McpHttpMain(void) {
  Bridge b;
  memset(&b, 0, sizeof(b));
  const char* session = getenv("ARX_SESSION_DIR");
  const char* text = getenv("ARX_MCP_SERVER");
  b.entry = cJSON_Parse(text ? text : "");
  b.name = JsonStr(b.entry, "name", "server");
  b.url = JsonStr(b.entry, "url", NULL);
  if (!b.url) {
    fprintf(stderr,
            "arx: mcp http is started by arx, with the server in "
            "ARX_MCP_SERVER\n");
    return kExitUsage;
  }
  Buffer host = {0};
  AppendHost(&host, b.url);
  b.host = BufferTake(&host);
  b.tmp_dir = session ? XAsprintf("%s/mcp", session) : XStrdup(".arx/mcp");
  MakeDirs(b.tmp_dir);
  RpcHandlers h = {Write, OnRequest, OnNotify, NULL, &b};
  b.up = RpcNew(&h, 0);
  g_bridge = &b;
  fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
  int open = 1;
  while (open && !g_interrupted) {
    int n = 0;
    for (HttpJob* j = b.jobs; j; j = j->next) n += j->child != NULL;
    ProcChild** kids = XMalloc((size_t)(n + 1) * sizeof(*kids));
    n = 0;
    for (HttpJob* j = b.jobs; j; j = j->next) {
      if (j->child) kids[n++] = j->child;
    }
    struct pollfd in = {.fd = 0, .events = POLLIN};
    ProcPollWith(kids, n, &in, 1, 0.1);
    free(kids);
    char buf[65536];
    ssize_t got = in.revents ? read(0, buf, sizeof(buf)) : -1;
    if (got > 0) RpcFeed(b.up, buf, (size_t)got);
    if (got == 0) open = 0;  // arx closed our stdin: stop
    Sweep(&b);
  }
  McpHttpLegacyEnd(&b);
  while (b.jobs) {
    HttpJob* j = b.jobs;
    b.jobs = j->next;
    FreeJob(j);
  }
  RpcFree(b.up);
  cJSON_Delete(b.entry);
  cJSON_Delete(b.credential);
  cJSON_Delete(b.init);
  cJSON_Delete(b.tool_headers);
  free(b.host);
  free(b.tmp_dir);
  free(b.session);
  free(b.version);
  return kExitDone;
}
