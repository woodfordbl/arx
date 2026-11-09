// rpc.c: JSON-RPC 2.0 over newline-delimited JSON, in either role, with no
// I/O of its own. The owner feeds it the bytes it reads (RpcFeed is a
// DataFn) and gives it a function that writes one whole line, so a peer
// fits arx's single poll loop: a child's stdout and ProcWrite, or fd 0 and
// fd 1. Deadlines fire only in RpcTick. The ids, params and values a
// callback gets are borrowed and freed when it returns. A callback may call
// RpcCall, RpcNotify, RpcReply and RpcForget; RpcFree inside one waits
// until it returns.

#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"

// Error codes from the JSON-RPC 2.0 specification.
enum { kParseError = -32700, kInvalidRequest = -32600, kNoMethod = -32601 };

// The default longest line: 64 MB.
static const size_t kMaxLine = (size_t)64 << 20;

// How much of a skipped line bad_line gets.
static const size_t kSkippedShown = 200;

// A call of ours that waits for its response.
typedef struct Waiting {
  int64_t id;
  double deadline;  // Now() when it times out, or 0
  RpcDoneFn done;
  void* ctx;
} Waiting;

struct RpcPeer {
  RpcHandlers h;
  size_t max_line;
  Buffer in;         // bytes of a line that has not ended yet
  int skipping;      // dropping a line that is too long, up to its newline
  Waiting* waiting;  // our calls in flight
  int count, cap;
  int64_t next_id;
  int busy;    // public calls running; RpcFree waits for them
  int freed;   // RpcFree came while busy
  int closed;  // RpcClose ran: nothing more is sent or read
};

// Creates a peer; see base.h.
RpcPeer* RpcNew(const RpcHandlers* h, size_t max_line) {
  RpcPeer* p = XMalloc(sizeof(*p));
  memset(p, 0, sizeof(*p));
  p->h = *h;
  p->max_line = max_line ? max_line : kMaxLine;
  p->next_id = 1;
  return p;
}

// Frees the peer and everything it holds.
static void Destroy(RpcPeer* p) {
  BufferFree(&p->in);
  free(p->waiting);
  free(p);
}

// Ends a public call that may have run callbacks, and frees the peer when
// RpcFree came during them. The caller must not touch `p` afterwards.
static void Leave(RpcPeer* p) {
  if (--p->busy == 0 && p->freed) Destroy(p);
}

// Writes `m` (consumed) as one line. cJSON escapes newlines in strings, so
// the line holds none of its own.
static void Send(RpcPeer* p, cJSON* m) {
  char* text = p->closed ? NULL : cJSON_PrintUnformatted(m);
  cJSON_Delete(m);
  if (!text) return;
  size_t n = strlen(text);
  text = XRealloc(text, n + 2);
  memcpy(text + n, "\n", 2);
  p->h.write(p->h.ctx, text, n + 1);
  free(text);
}

// A new message: "jsonrpc": "2.0", and `id` (copied; NULL: none).
static cJSON* Message(const cJSON* id) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "jsonrpc", "2.0");
  if (id) cJSON_AddItemToObject(m, "id", cJSON_Duplicate(id, 1));
  return m;
}

// A request or notification: `params` (consumed) is left out when NULL.
static cJSON* Request(const char* method, cJSON* params, int64_t id) {
  cJSON* m = Message(NULL);
  if (id) cJSON_AddNumberToObject(m, "id", (double)id);
  cJSON_AddStringToObject(m, "method", method);
  if (params) cJSON_AddItemToObject(m, "params", params);
  return m;
}

// Sends a request and waits for its response; see base.h.
int64_t RpcCall(RpcPeer* p, const char* method, cJSON* params, double timeout,
                RpcDoneFn done, void* ctx) {
  if (p->closed) {
    cJSON_Delete(params);
    return 0;
  }
  int64_t id = p->next_id++;
  if (p->count == p->cap) {
    p->cap = p->cap ? 2 * p->cap : 8;
    p->waiting = XRealloc(p->waiting, (size_t)p->cap * sizeof(*p->waiting));
  }
  Waiting* w = &p->waiting[p->count++];
  w->id = id;
  w->deadline = timeout > 0 ? Now() + timeout : 0;
  w->done = done;
  w->ctx = ctx;
  p->busy++;
  Send(p, Request(method, params, id));
  Leave(p);
  return id;
}

// Sends a notification; see base.h.
void RpcNotify(RpcPeer* p, const char* method, cJSON* params) {
  p->busy++;
  Send(p, Request(method, params, 0));
  Leave(p);
}

// Sends `m` (consumed) with `id` (borrowed; NULL: null) as an answer.
static void Answer(RpcPeer* p, const cJSON* id, cJSON* m) {
  cJSON* copy = id ? cJSON_Duplicate(id, 1) : cJSON_CreateNull();
  cJSON* answer = Message(NULL);
  cJSON_AddItemToObject(answer, "id", copy);
  cJSON* field = m->child;
  cJSON_DetachItemViaPointer(m, field);
  cJSON_AddItemToObject(answer, field->string, field);
  cJSON_Delete(m);
  p->busy++;
  Send(p, answer);
  Leave(p);
}

// Answers a request; see base.h.
void RpcReply(RpcPeer* p, cJSON* id, cJSON* result) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddItemToObject(m, "result", result ? result : cJSON_CreateNull());
  Answer(p, id, m);
}

// Answers a request with an error; see base.h.
void RpcReplyError(RpcPeer* p, cJSON* id, int code, const char* message,
                   cJSON* data) {
  cJSON* m = cJSON_CreateObject();
  cJSON* e = cJSON_AddObjectToObject(m, "error");
  cJSON_AddNumberToObject(e, "code", code);
  cJSON_AddStringToObject(e, "message", message ? message : "");
  if (data) cJSON_AddItemToObject(e, "data", data);
  Answer(p, id, m);
}

// Removes our call `id` from the waiting list into `*w`. Returns 0, or -1
// when no call has that id.
static int Take(RpcPeer* p, int64_t id, Waiting* w) {
  for (int i = 0; i < p->count; i++) {
    if (p->waiting[i].id != id) continue;
    *w = p->waiting[i];
    memmove(&p->waiting[i], &p->waiting[i + 1],
            (size_t)(p->count - i - 1) * sizeof(*p->waiting));
    p->count--;
    return 0;
  }
  return -1;
}

// Drops a call without calling it back; see base.h.
void RpcForget(RpcPeer* p, int64_t id) {
  Waiting w;
  Take(p, id, &w);
}

// Tells the owner about a line that is not JSON-RPC.
static void Bad(RpcPeer* p, const char* line, const char* why) {
  if (p->h.bad_line) p->h.bad_line(p->h.ctx, line, why);
}

// Ends one of our calls with its response.
static void Response(RpcPeer* p, const char* line, cJSON* m, cJSON* id) {
  cJSON* error = cJSON_GetObjectItemCaseSensitive(m, "error");
  cJSON* result = cJSON_GetObjectItemCaseSensitive(m, "result");
  Waiting w;
  int ours = cJSON_IsNumber(id) && id->valuedouble >= 1 &&
             id->valuedouble < (double)p->next_id;
  if (!ours || Take(p, (int64_t)id->valuedouble, &w)) {
    // A response to a call we forgot is expected; anything else is not.
    if (!ours) Bad(p, line, "a response to no request of ours");
    return;
  }
  if (w.done) w.done(w.ctx, error ? kRpcError : kRpcOk, error ? error : result);
}

// True for an id a request may have: a string, a number or null.
static int IdOk(const cJSON* id) {
  return cJSON_IsString(id) || cJSON_IsNumber(id) || cJSON_IsNull(id);
}

// Handles one message (a parsed line).
static void Handle(RpcPeer* p, const char* line, cJSON* m) {
  cJSON* id = cJSON_GetObjectItemCaseSensitive(m, "id");
  cJSON* method = cJSON_GetObjectItemCaseSensitive(m, "method");
  cJSON* params = cJSON_GetObjectItemCaseSensitive(m, "params");
  int answer = cJSON_GetObjectItemCaseSensitive(m, "result") ||
               cJSON_GetObjectItemCaseSensitive(m, "error");
  if (cJSON_IsString(method) && id && IdOk(id)) {
    if (p->h.request) {
      p->h.request(p->h.ctx, p, id, method->valuestring, params);
    } else {
      RpcReplyError(p, id, kNoMethod, "Method not found", NULL);
    }
  } else if (cJSON_IsString(method) && !id) {
    if (p->h.notify) p->h.notify(p->h.ctx, method->valuestring, params);
  } else if (answer && id && !method) {
    Response(p, line, m, id);
  } else {
    if (p->h.request) {
      RpcReplyError(p, IdOk(id) ? id : NULL, kInvalidRequest, "Invalid Request",
                    NULL);
    }
    Bad(p, line, "not a JSON-RPC request, notification or response");
  }
}

// Handles one whole line, without its newline.
static void Line(RpcPeer* p, const char* line) {
  if (!line[strspn(line, " \t\r")]) return;  // a blank line
  cJSON* m = cJSON_Parse(line);
  if (cJSON_IsObject(m)) {
    Handle(p, line, m);
  } else {
    // An array is a batch, which neither MCP nor ACP sends.
    int batch = cJSON_IsArray(m);
    if (p->h.request) {
      RpcReplyError(p, NULL, batch ? kInvalidRequest : kParseError,
                    batch ? "Invalid Request" : "Parse error", NULL);
    }
    Bad(p, line, batch ? "a batch, which arx does not take" : "not JSON");
  }
  cJSON_Delete(m);
}

// Reads bytes and handles each line that ends in them; see base.h.
void RpcFeed(void* peer, const char* data, size_t n) {
  RpcPeer* p = peer;
  if (p->closed || p->freed) return;
  p->busy++;
  BufferAppend(&p->in, data, n);
  char* nl;
  while (!p->closed && !p->freed && p->in.len &&
         (nl = memchr(p->in.data, '\n', p->in.len))) {
    size_t len = (size_t)(nl - p->in.data);
    char* line = XStrndup(p->in.data, len);
    memmove(p->in.data, nl + 1, p->in.len - len - 1);
    p->in.len -= len + 1;
    if (p->skipping) {
      p->skipping = 0;  // the rest of a line that was too long
    } else if (len > p->max_line) {
      if (len > kSkippedShown) line[kSkippedShown] = 0;
      Bad(p, line, "longer than the longest line allowed");
    } else {
      Line(p, line);
    }
    free(line);
  }
  if (!p->skipping && p->in.len > p->max_line) {
    p->in.data[p->in.len < kSkippedShown ? p->in.len : kSkippedShown] = 0;
    Bad(p, p->in.data, "longer than the longest line allowed");
    p->skipping = 1;
  }
  if (p->skipping) p->in.len = 0;
  Leave(p);
}

// Fires the deadlines that have passed; see base.h.
double RpcTick(RpcPeer* p, double now) {
  p->busy++;
  for (int i = 0; i < p->count && !p->freed;) {
    if (!p->waiting[i].deadline || p->waiting[i].deadline > now) {
      i++;
      continue;
    }
    Waiting w;
    Take(p, p->waiting[i].id, &w);
    if (w.done) w.done(w.ctx, kRpcTimeout, NULL);
    i = 0;  // the callback may have changed the list
  }
  double next = -1;
  for (int i = 0; i < p->count && !p->freed; i++) {
    double left = p->waiting[i].deadline - now;
    if (p->waiting[i].deadline && (next < 0 || left < next)) next = left;
  }
  Leave(p);
  return next;
}

// Ends every waiting call with kRpcClosed; see base.h.
void RpcClose(RpcPeer* p, const char* why) {
  p->busy++;
  p->closed = 1;
  cJSON* reason = why ? cJSON_CreateString(why) : NULL;
  while (p->count && !p->freed) {
    Waiting w;
    Take(p, p->waiting[0].id, &w);
    if (w.done) w.done(w.ctx, kRpcClosed, reason);
  }
  cJSON_Delete(reason);
  Leave(p);
}

// The calls that wait for a response; see base.h.
int RpcPending(const RpcPeer* p) { return p->count; }

// Frees the peer, or marks it to be freed when its callbacks return.
void RpcFree(RpcPeer* p) {
  if (!p) return;
  if (p->busy) {
    p->freed = 1;
    return;
  }
  Destroy(p);
}
