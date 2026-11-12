// calls.c: one call to an MCP tool. A call is a request on its server's
// connection, with no process of its own: it waits until the server is
// ready, goes out as tools/call, and ends with the response, at its
// timeout, on Ctrl-C or when the server exits. arx never repeats a
// tools/call, since it may have had an effect. mcp_search and mcp_select
// are calls too: they end once the servers they need have listed.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/mcp/mcp.h"

typedef enum CallKind { kCallTool, kCallSearch, kCallSelect } CallKind;

struct McpCall {
  struct Agent* a;
  CallKind kind;
  McpServer* server;  // NULL for mcp_search and mcp_select
  char* name;         // the tool as the model called it
  char* id;           // the model's call id
  char* out_path;
  cJSON* args;
  int64_t request;  // the tools/call id while it is in flight, else 0
  int token;        // its progressToken
  double start, deadline, timeout;
  int done, is_error;
  char* text;
  McpCall* next;
};

static McpCall* g_calls;  // the calls that run
static int g_tokens;

// Ends a call with `text` (consumed).
static void End(McpCall* c, char* text, int is_error) {
  c->text = text;
  c->is_error = is_error;
  c->done = 1;
}

// Decodes base64 `text` into `out`.
static void Base64Decode(const char* text, Buffer* out) {
  static const char kDigits[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  unsigned bits = 0;
  int count = 0;
  for (const char* p = text; *p && *p != '='; p++) {
    const char* at = strchr(kDigits, *p);
    if (!at) continue;
    bits = bits << 6 | (unsigned)(at - kDigits);
    if (++count == 4) {
      char bytes[3] = {(char)(bits >> 16), (char)(bits >> 8), (char)bits};
      BufferAppend(out, bytes, 3);
      bits = 0;
      count = 0;
    }
  }
  if (count > 1) {
    bits <<= 6 * (4 - count);
    char bytes[2] = {(char)(bits >> 16), (char)(bits >> 8)};
    BufferAppend(out, bytes, (size_t)count - 1);
  }
}

// Saves base64 `data` next to the call's output file, as tool-NNNN-<n>.<ext>,
// and appends "[image/png, 34 KB: path]".
static void SaveBlob(McpCall* c, int n, const char* mime, const char* data,
                     Buffer* out) {
  Buffer bytes = {0};
  Base64Decode(data, &bytes);
  char ext[9] = "bin";
  const char* sub = strchr(mime, '/');
  size_t len = sub ? strspn(sub + 1, kNameChars) : 0;
  if (len && len < sizeof(ext))
    snprintf(ext, sizeof(ext), "%.*s", (int)len, sub + 1);
  size_t stem = strlen(c->out_path);
  if (stem > 4 && !strcmp(c->out_path + stem - 4, ".out")) stem -= 4;
  char* path = XAsprintf("%.*s-%d.%s", (int)stem, c->out_path, n, ext);
  WriteFileAtomic(path, bytes.data ? bytes.data : "", bytes.len);
  BufferPrintf(out, "[%s, %zu KB: %s]", *mime ? mime : "file",
               (bytes.len + 1023) / 1024, path);
  free(path);
  BufferFree(&bytes);
}

// Appends one content item of a result as text.
static void AppendItem(McpCall* c, int n, cJSON* item, Buffer* out) {
  const char* type = JsonStr(item, "type", "");
  if (!strcmp(type, "text")) {
    BufferAppendStr(out, JsonStr(item, "text", ""));
  } else if (!strcmp(type, "image") || !strcmp(type, "audio")) {
    SaveBlob(c, n, JsonStr(item, "mimeType", type), JsonStr(item, "data", ""),
             out);
  } else if (!strcmp(type, "resource_link")) {
    BufferPrintf(out, "[resource: %s (%s, %s)]", JsonStr(item, "uri", ""),
                 JsonStr(item, "name", ""), JsonStr(item, "mimeType", ""));
  } else if (!strcmp(type, "resource")) {
    const char* text = JsonStr(item, "resource.text", NULL);
    if (text) {
      BufferAppendStr(out, text);
    } else {
      SaveBlob(c, n, JsonStr(item, "resource.mimeType", ""),
               JsonStr(item, "resource.blob", ""), out);
    }
  } else {
    char* json = cJSON_PrintUnformatted(item);
    BufferAppendStr(out, json ? json : "");
    free(json);
  }
}

// Turns a tools/call result into the text for the model.
static void Convert(McpCall* c, cJSON* result) {
  Buffer out = {0};
  BufferAppendStr(&out, "");
  if (!strcmp(JsonStr(result, "resultType", ""), "input_required")) {
    cJSON* ask = JsonGet(result, "inputRequests");
    ask = ask ? ask->child : NULL;
    BufferPrintf(&out, "the server asked for input arx cannot give (%s): %s",
                 JsonStr(ask, "method", "input_required"),
                 JsonStr(ask, "params.message", ""));
    End(c, BufferTake(&out), 1);
    return;
  }
  int n = 0;
  cJSON* item;
  cJSON_ArrayForEach(item, JsonGet(result, "content")) {
    if (n++) BufferAppendStr(&out, "\n");
    AppendItem(c, n, item, &out);
  }
  cJSON* structured = JsonGet(result, "structuredContent");
  if (!n && structured) {
    char* json = cJSON_PrintUnformatted(structured);
    BufferAppendStr(&out, json);
    free(json);
  }
  End(c, BufferTake(&out), JsonBool(result, "isError", 0));
}

// RpcDoneFn for tools/call.
static void OnResult(void* ctx, RpcStatus status, cJSON* value) {
  McpCall* c = ctx;
  c->request = 0;
  c->server->calls--;
  if (status == kRpcOk) {
    Convert(c, value);
  } else if (status == kRpcError) {
    End(c,
        XAsprintf("MCP error %d: %s", (int)JsonNum(value, "code", 0),
                  JsonStr(value, "message", "")),
        1);
  } else {
    End(c,
        XStrdup(cJSON_IsString(value) ? value->valuestring
                                      : "the MCP server closed"),
        1);
  }
}

// Sends the call to its server, which is ready. A name the server does not
// list ends the call and leaves the selection.
static void Send(McpCall* c) {
  McpServer* s = c->server;
  McpTool* tool = McpFindTool(c->name, NULL);
  if (!tool) {
    cJSON* names = cJSON_CreateArray();
    cJSON* n;
    cJSON_ArrayForEach(n, McpSelection()) {
      if (strcmp(n->valuestring, c->name)) {
        cJSON_AddItemToArray(names, cJSON_Duplicate(n, 1));
      }
    }
    McpSelectionSet(c->a, names);
    End(c,
        XAsprintf("the server %s has no tool \"%s\" (it may have been "
                  "removed). Find its tools with mcp_search.",
                  s->name, c->name + strlen(s->name) + 2),
        1);
    return;
  }
  cJSON* params = cJSON_CreateObject();
  cJSON_AddStringToObject(params, "name", JsonStr(tool->def, "name", ""));
  cJSON_AddItemToObject(params, "arguments", cJSON_Duplicate(c->args, 1));
  cJSON* meta = cJSON_AddObjectToObject(params, "_meta");
  cJSON_AddNumberToObject(meta, "progressToken", c->token);
  s->calls++;
  c->request = McpRequest(s, "tools/call", params, 0, OnResult, c);
}

// Cancels a call that waits or is in flight, with `text` as its result.
static void Cancel(McpCall* c, const char* reason, char* text) {
  if (c->request && c->server->peer) {
    cJSON* params = cJSON_CreateObject();
    cJSON_AddNumberToObject(params, "requestId", (double)c->request);
    cJSON_AddStringToObject(params, "reason", reason);
    RpcForget(c->server->peer, c->request);
    RpcNotify(c->server->peer, "notifications/cancelled", params);
    c->server->calls--;
  }
  c->request = 0;
  End(c, text, 1);
}

// The servers a search or a select needs: the one `server` names, or all.
static int InScope(const McpCall* c, const McpServer* s) {
  const char* only =
      c->kind == kCallSearch ? JsonStr(c->args, "server", "") : "";
  return !*only || !strcmp(only, s->name) || !McpServerFind(only);
}

// Starts each server in the call's scope whose list is not fresh. Returns
// how many still have to list.
static int NeedServers(McpCall* c) {
  int waiting = 0;
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    if (!InScope(c, s) || s->fresh || s->state == kMcpFailed) continue;
    McpServerNeed(c->a, s);
    waiting += s->state != kMcpFailed;
  }
  return waiting;
}

// Runs mcp_search or mcp_select over the catalog as it is now.
static void Answer(McpCall* c) {
  if (c->kind == kCallSelect) {
    int is_error = 0;
    char* text = McpSelectApply(c->a, JsonGet(c->args, "names"),
                                JsonGet(c->args, "drop"), &is_error);
    End(c, text, is_error);
    return;
  }
  Buffer out = {0};
  McpSearchText(c->a, JsonStr(c->args, "query", ""),
                JsonStr(c->args, "server", NULL),
                (int)JsonNum(c->args, "limit", 0), &out);
  End(c, BufferTake(&out), 0);
}

// One round for a call that is not done.
static void Step(McpCall* c) {
  McpServer* s = c->server;
  if (g_interrupted) {
    Cancel(c, "interrupted", XStrdup("[interrupted]"));
  } else if (c->kind != kCallTool) {
    if (!NeedServers(c) || Now() > c->deadline) Answer(c);
  } else if (Now() > c->deadline) {
    Cancel(c, "timeout",
           XAsprintf("[timed out after %.0fs; arx cancelled the call]",
                     c->timeout));
  } else if (c->request) {
    // in flight: OnResult ends it
  } else if (s->state == kMcpFailed) {
    End(c, XAsprintf("the MCP server %s failed: %s", s->name, s->error), 1);
  } else if (s->state == kMcpReady) {
    Send(c);
  } else {
    McpServerNeed(c->a, s);
  }
}

// Starts a call; see mcp.h.
McpCall* McpCallStart(struct Agent* a, const Tool* t, cJSON* args,
                      const char* id, const char* out_path) {
  McpCall* c = XMalloc(sizeof(*c));
  memset(c, 0, sizeof(*c));
  c->a = a;
  c->kind = t->server                        ? kCallTool
            : !strcmp(t->name, "mcp_search") ? kCallSearch
                                             : kCallSelect;
  c->server = t->server ? McpServerFind(t->server) : NULL;
  c->name = XStrdup(t->name);
  c->id = XStrdup(id);
  c->out_path = XStrdup(out_path);
  c->args = cJSON_Duplicate(args, 1);
  c->token = ++g_tokens;
  c->start = Now();
  c->timeout = t->timeout;
  for (int i = 0; c->kind != kCallTool && i < McpServerCount(); i++) {
    double startup =
        JsonDuration(McpServerAt(i)->entry, "startup_timeout", 60) + 5;
    if (startup > c->timeout) c->timeout = startup;
  }
  c->deadline = c->start + c->timeout;
  c->next = g_calls;
  g_calls = c;
  if (c->kind == kCallTool && !c->server) {
    End(c, XAsprintf("the MCP server %s is not in mcp_servers", t->server), 1);
  } else {
    Step(c);
  }
  return c;
}

// True when the call ended; see mcp.h.
int McpCallDone(const McpCall* c) { return c->done; }

// Ends and frees a call; see mcp.h.
char* McpCallFinish(McpCall* c, int* is_error, double* secs) {
  if (!c->done) Cancel(c, "interrupted", XStrdup("[interrupted]"));
  for (McpCall** at = &g_calls; *at; at = &(*at)->next) {
    if (*at != c) continue;
    *at = c->next;
    break;
  }
  char* text = c->text;
  *is_error = c->is_error;
  *secs = Now() - c->start;
  cJSON_Delete(c->args);
  free(c->name);
  free(c->id);
  free(c->out_path);
  free(c);
  return text;
}

// Sends tool.progress for a call; see mcp.h.
void McpCallProgress(McpServer* s, cJSON* params) {
  double token = JsonNum(params, "progressToken", -1);
  for (McpCall* c = g_calls; c; c = c->next) {
    if (c->server != s || c->token != (int)token || c->done) continue;
    cJSON* e = EventNew("tool.progress");
    cJSON_AddStringToObject(e, "id", c->id);
    cJSON_AddStringToObject(e, "name", c->name);
    cJSON_AddStringToObject(e, "server", s->name);
    cJSON_AddNumberToObject(e, "progress", JsonNum(params, "progress", 0));
    cJSON* total = JsonGet(params, "total");
    if (cJSON_IsNumber(total)) {
      cJSON_AddNumberToObject(e, "total", total->valuedouble);
    }
    const char* message = JsonStr(params, "message", NULL);
    if (message) JsonAddTruncated(e, "message", message, 300);
    EventSend(e);
  }
}

// One round of the client; see mcp.h.
void McpPump(struct Agent* a) {
  McpServersPump(a);
  for (McpCall* c = g_calls; c; c = c->next) {
    if (!c->done) Step(c);
  }
}

// Before each model call; see mcp.h.
void McpTurn(struct Agent* a) {
  if (!McpServerCount()) return;
  McpPump(a);
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    cJSON* preload = JsonGet(s->entry, "preload");
    int wanted = cJSON_IsTrue(preload) || cJSON_GetArraySize(preload) > 0;
    if (wanted && !s->fresh) McpServerWait(a, s);
    // A list that changed is on its way: the next request gets it.
    for (double end = Now() + 5; s->listing && s->state == kMcpReady &&
                                 Now() < end && !g_interrupted;) {
      ProcPoll(NULL, 0, 0.05);
      McpServersPump(a);
    }
  }
  McpSelectionLoad(a);
}
