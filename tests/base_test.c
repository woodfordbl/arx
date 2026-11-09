// base_test.c: unit tests for src/base that the end-to-end suites can't
// reach yet: the JSON-RPC peer (rpc.c), LineSink and LinePop, and the
// process helpers that later items build on (Proc.dir, ProcClose, ProcKeep,
// ProcStop). `make test` builds it with the sanitizers and runs it first.

#include "src/base/base.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_passed, g_failed;

// Records one check.
static void Check(const char* what, int ok) {
  if (ok) {
    g_passed++;
    printf("  ok    %s\n", what);
  } else {
    g_failed++;
    printf("  FAIL  %s\n", what);
  }
}

// ---- helpers for the RPC peer ----

// What the handlers saw.
typedef struct Seen {
  Buffer out;  // every line the peer wrote
  int done_count, last_status, bad_count, notify_count, request_count;
  char last_value[256];  // the done value, printed
  char last_bad[256];    // the last bad_line reason
  char last_method[64];
  RpcPeer* peer;
  cJSON* held_id;  // an id kept to answer later
  int free_in_request;
  int call_in_done;
} Seen;

// write: appends the line.
static void Write(void* ctx, const char* data, size_t n) {
  Seen* s = ctx;
  BufferAppend(&s->out, data, n);
}

// The JSON of the `k`th line the peer wrote (0-based), parsed; free it.
static cJSON* Written(Seen* s, int k) {
  char* copy = XStrdup(s->out.data ? s->out.data : "");
  Buffer b = {0};
  BufferAppendStr(&b, copy);
  free(copy);
  char* line = NULL;
  for (int i = 0; i <= k; i++) {
    free(line);
    line = LinePop(&b);
  }
  cJSON* m = line ? cJSON_Parse(line) : NULL;
  free(line);
  BufferFree(&b);
  return m;
}

// Counts the lines the peer wrote.
static int Lines(const Seen* s) {
  int n = 0;
  for (size_t i = 0; i < s->out.len; i++) n += s->out.data[i] == '\n';
  return n;
}

// done: records the status and the value.
static void Done(void* ctx, RpcStatus status, cJSON* value) {
  Seen* s = ctx;
  s->done_count++;
  s->last_status = status;
  char* text = value ? cJSON_PrintUnformatted(value) : XStrdup("NULL");
  snprintf(s->last_value, sizeof(s->last_value), "%s", text);
  free(text);
  if (s->call_in_done) {
    s->call_in_done = 0;
    RpcCall(s->peer, "again", NULL, 0, Done, s);
  }
}

// bad_line: records why.
static void BadLine(void* ctx, const char* line, const char* why) {
  (void)line;
  Seen* s = ctx;
  s->bad_count++;
  snprintf(s->last_bad, sizeof(s->last_bad), "%s", why);
}

// notify: records the method.
static void Notify(void* ctx, const char* method, cJSON* params) {
  (void)params;
  Seen* s = ctx;
  s->notify_count++;
  snprintf(s->last_method, sizeof(s->last_method), "%s", method);
}

// request: "echo" answers at once, "later" keeps the id, "free" frees the
// peer from inside the callback.
static void Request(void* ctx, RpcPeer* p, cJSON* id, const char* method,
                    cJSON* params) {
  Seen* s = ctx;
  s->request_count++;
  if (!strcmp(method, "echo")) {
    RpcReply(p, id, cJSON_Duplicate(params, 1));
  } else if (!strcmp(method, "later")) {
    s->held_id = cJSON_Duplicate(id, 1);
  } else if (!strcmp(method, "free")) {
    RpcFree(p);
  }
}

// Feeds a string in pieces of `piece` bytes.
static void FeedIn(RpcPeer* p, const char* text, size_t piece) {
  size_t n = strlen(text);
  for (size_t at = 0; at < n; at += piece) {
    RpcFeed(p, text + at, at + piece < n ? piece : n - at);
  }
}

// ---- tests ----

// LineSink and LinePop.
static void TestLines(void) {
  Buffer b = {0};
  LineSink(&b, "a\nbc\n\npart", 10);
  char* l1 = LinePop(&b);
  char* l2 = LinePop(&b);
  char* l3 = LinePop(&b);
  char* l4 = LinePop(&b);
  Check("LinePop returns each line without its newline",
        l1 && l2 && l3 && !strcmp(l1, "a") && !strcmp(l2, "bc") && !*l3);
  Check("LinePop returns NULL while a line has not ended", l4 == NULL);
  Check("the rest stays in the buffer", !strcmp(b.data, "part") && b.len == 4);
  free(l1);
  free(l2);
  free(l3);
  BufferFree(&b);
}

// The client role: calls, responses, errors, timeouts, forget, close.
static void TestClient(void) {
  Seen s = {0};
  RpcHandlers h = {
      .write = Write, .notify = Notify, .bad_line = BadLine, .ctx = &s};
  RpcPeer* p = RpcNew(&h, 0);
  s.peer = p;
  cJSON* params = cJSON_CreateObject();
  cJSON_AddNumberToObject(params, "x", 1);
  int64_t a = RpcCall(p, "tools/list", params, 0, Done, &s);
  int64_t b = RpcCall(p, "tools/call", NULL, 0, Done, &s);
  cJSON* m = Written(&s, 0);
  Check("ids count from 1", a == 1 && b == 2);
  Check("a request has jsonrpc, id, method and params",
        !strcmp(JsonStr(m, "jsonrpc", ""), "2.0") && JsonNum(m, "id", 0) == 1 &&
            !strcmp(JsonStr(m, "method", ""), "tools/list") &&
            JsonNum(m, "params.x", 0) == 1);
  cJSON_Delete(m);
  m = Written(&s, 1);
  Check("NULL params are left out", !cJSON_GetObjectItem(m, "params"));
  cJSON_Delete(m);
  Check("two calls wait", RpcPending(p) == 2);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n", 7);
  Check("a response in pieces ends its call",
        s.done_count == 1 && s.last_status == kRpcOk &&
            !strcmp(s.last_value, "{\"ok\":true}"));
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-1}}\r\n", 100);
  Check("an error response gives kRpcError and the error",
        s.done_count == 2 && s.last_status == kRpcError &&
            !strcmp(s.last_value, "{\"code\":-1}"));
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":{}}\n", 100);
  Check("a notification reaches notify",
        s.notify_count == 1 && !strcmp(s.last_method, "note"));
  int lines = Lines(&s);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"ping\"}\n", 100);
  m = Written(&s, lines);
  Check("without a request handler a request gets -32601, with its id",
        JsonNum(m, "error.code", 0) == -32601 &&
            !strcmp(JsonStr(m, "id", ""), "q"));
  cJSON_Delete(m);
  lines = Lines(&s);
  FeedIn(p, "not json\n\n", 100);
  Check("in the client role, a line that is not JSON goes to bad_line only",
        s.bad_count == 1 && Lines(&s) == lines);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":1}\n", 100);
  Check("a response to no request of ours is a bad line", s.bad_count == 2);
  int64_t c = RpcCall(p, "slow", NULL, 0, Done, &s);
  RpcForget(p, c);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":1}\n", 100);
  Check("a forgotten call never calls back, and its response is quiet",
        s.done_count == 2 && s.bad_count == 2 && RpcPending(p) == 0);
  RpcCall(p, "t", NULL, 0.5, Done, &s);
  RpcCall(p, "u", NULL, 0, Done, &s);
  double next = RpcTick(p, Now());
  Check("RpcTick says when the next deadline is", next > 0 && next <= 0.5);
  s.call_in_done = 1;
  next = RpcTick(p, Now() + 1);
  Check("a passed deadline gives kRpcTimeout",
        s.done_count == 3 && s.last_status == kRpcTimeout &&
            !strcmp(s.last_value, "NULL"));
  Check("a callback may call RpcCall", RpcPending(p) == 2 && next == -1);
  RpcClose(p, "the server exited");
  Check("RpcClose ends every waiting call with its reason",
        s.done_count == 5 && s.last_status == kRpcClosed &&
            !strcmp(s.last_value, "\"the server exited\"") &&
            RpcPending(p) == 0);
  lines = Lines(&s);
  Check("a closed peer takes no calls",
        RpcCall(p, "x", NULL, 0, Done, &s) == 0 && Lines(&s) == lines);
  RpcFree(p);
  BufferFree(&s.out);
}

// The server role: answers, errors and bad lines.
static void TestServer(void) {
  Seen s = {0};
  RpcHandlers h = {
      .write = Write, .request = Request, .bad_line = BadLine, .ctx = &s};
  RpcPeer* p = RpcNew(&h, 64);
  s.peer = p;
  FeedIn(p,
         "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"echo\",\"params\":[1]}\n",
         5);
  cJSON* m = Written(&s, 0);
  Check("RpcReply answers with the id as it came",
        JsonNum(m, "id", 0) == 7 &&
            cJSON_GetArraySize(cJSON_GetObjectItem(m, "result")) == 1);
  cJSON_Delete(m);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"later\"}\n", 100);
  Check("a request may be answered later", Lines(&s) == 1 && s.held_id);
  RpcReplyError(p, s.held_id, -32000, "no", cJSON_CreateString("why"));
  m = Written(&s, 1);
  Check("RpcReplyError sends code, message and data",
        !strcmp(JsonStr(m, "id", ""), "s1") &&
            JsonNum(m, "error.code", 0) == -32000 &&
            !strcmp(JsonStr(m, "error.data", ""), "why"));
  cJSON_Delete(m);
  cJSON_Delete(s.held_id);
  FeedIn(p, "{oops\n", 100);
  m = Written(&s, 2);
  Check("a line that is not JSON gets -32700 with a null id",
        JsonNum(m, "error.code", 0) == -32700 &&
            cJSON_IsNull(cJSON_GetObjectItem(m, "id")));
  cJSON_Delete(m);
  FeedIn(p, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\"}]\n", 100);
  m = Written(&s, 3);
  Check("a batch gets -32600", JsonNum(m, "error.code", 0) == -32600);
  cJSON_Delete(m);
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"echo\"}\n", 100);
  m = Written(&s, 4);
  Check("a request with a bad id gets -32600 with a null id",
        JsonNum(m, "error.code", 0) == -32600 &&
            cJSON_IsNull(cJSON_GetObjectItem(m, "id")));
  cJSON_Delete(m);
  int bad = s.bad_count;
  FeedIn(p, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"echo\",\"params\":\"",
         10);
  FeedIn(p, "0123456789012345678901234567890123456789012345678901234567890",
         10);
  FeedIn(p, "\"}\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"echo\"}\n", 3);
  m = Written(&s, Lines(&s) - 1);
  Check("a line over max_line is skipped and reported",
        s.bad_count == bad + 1 && strstr(s.last_bad, "longer"));
  Check("and the next line is handled", JsonNum(m, "id", 0) == 9);
  cJSON_Delete(m);
  int requests = s.request_count;
  FeedIn(p,
         "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"free\"}\n"
         "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"echo\"}\n",
         200);
  Check("RpcFree in a callback waits for it, and no more lines run",
        s.request_count == requests + 1);
  BufferFree(&s.out);
}

// Proc.dir, ProcClose, ProcKeep and ProcStop.
static void TestProc(void) {
  char tmpl[] = "/tmp/arx-base-test.XXXXXX";
  char* dir = mkdtemp(tmpl);
  char real[PATH_MAX];
  if (!dir || !realpath(dir, real)) {
    Check("make a temp folder", 0);
    return;
  }
  Buffer out = {0};
  char* pwd[] = {"sh", "-c", "pwd -P", NULL};
  Proc p = {.argv = pwd, .dir = real, .on_out = BufferSink, .out_ctx = &out};
  ProcResult r;
  ProcRun(&p, &r);
  Check("Proc.dir runs the child in that folder",
        out.data && !strncmp(out.data, real, strlen(real)));
  out.len = 0;
  char* cat[] = {"cat", NULL};
  Proc q = {.argv = cat, .open_in = 1, .on_out = BufferSink, .out_ctx = &out};
  ProcChild* c = ProcStart(&q);
  ProcWrite(c, "hello\n", 6);
  ProcClose(c);
  ProcWrite(c, "dropped\n", 8);
  while (!ProcDone(c)) ProcPoll(&c, 1, 0.1);
  ProcFinish(c, &r);
  Check("ProcClose writes what was queued, then closes stdin",
        r.code == 0 && out.data && !strcmp(out.data, "hello\n"));
  Buffer kept = {0};
  char* talk[] = {"sh", "-c", "echo kept; exec sleep 30", NULL};
  Proc k = {.argv = talk, .on_out = LineSink, .out_ctx = &kept};
  ProcChild* helper = ProcStart(&k);
  ProcKeep(helper);
  char* nap[] = {"sh", "-c", "sleep 0.3", NULL};
  Proc n = {.argv = nap};
  ProcRun(&n, &r);
  char* line = LinePop(&kept);
  Check("a kept child's output drains while arx runs another",
        line && !strcmp(line, "kept"));
  free(line);
  double t = Now();
  ProcStop(helper);
  while (!ProcDone(helper)) ProcPoll(NULL, 0, 0.1);
  ProcFinish(helper, &r);
  Check("ProcStop stops a kept child without a wait of its own",
        r.code == 128 + 15 && Now() - t < 2);
  BufferFree(&out);
  BufferFree(&kept);
  rmdir(dir);
}

// Runs every test.
int main(void) {
  TestLines();
  TestClient();
  TestServer();
  TestProc();
  printf("\n%d passed, %d failed\n", g_passed, g_failed);
  return g_failed ? 1 : 0;
}
