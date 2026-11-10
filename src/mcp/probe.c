// probe.c: the first messages to a server that just started. A start
// probes which era the server speaks: the current revision (stateless,
// `server/discover`) or the `initialize` handshake of 2025-11-25 and
// earlier. The cache remembers the answer, so only the first start probes.
// Then arx lists the tools and the server is ready. This file also answers
// what a server sends on its own: list changes, progress, pings.

#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

// How long a server of unknown era may take to answer server/discover.
static const double kProbeSeconds = 5;

static const char* const kLegacyVersions[] = {MCP_LEGACY_VERSION, "2025-06-18",
                                              "2025-03-26", "2024-11-05", NULL};

// The _meta of every modern request.
static cJSON* Meta(void) {
  cJSON* meta = cJSON_CreateObject();
  cJSON* info = cJSON_CreateObject();
  cJSON_AddStringToObject(info, "name", "arx");
  cJSON_AddStringToObject(info, "version", ARX_VERSION);
  cJSON_AddStringToObject(meta, "io.modelcontextprotocol/protocolVersion",
                          MCP_VERSION);
  cJSON_AddItemToObject(meta, "io.modelcontextprotocol/clientInfo", info);
  cJSON_AddItemToObject(meta, "io.modelcontextprotocol/clientCapabilities",
                        cJSON_CreateObject());
  return meta;
}

// Sends a request; see mcp.h.
int64_t McpRequest(McpServer* s, const char* method, cJSON* params,
                   double timeout, RpcDoneFn done, void* ctx) {
  if (!s->peer) {
    cJSON_Delete(params);
    return 0;
  }
  if (s->modern) {
    if (!params) params = cJSON_CreateObject();
    cJSON* meta = cJSON_GetObjectItemCaseSensitive(params, "_meta");
    cJSON* ours = Meta();
    if (cJSON_IsObject(meta)) {
      JsonMergeOver(meta, ours);
      cJSON_Delete(ours);
    } else {
      cJSON_AddItemToObject(params, "_meta", ours);
    }
  }
  return RpcCall(s->peer, method, params, timeout, done, ctx);
}

// The seconds left of the startup time.
static double StartupLeft(const McpServer* s) {
  double left = s->ready_by - Now();
  return left > 0.1 ? left : 0.1;
}

// Why a call ended without a result, for messages.
static char* CallProblem(RpcStatus status, cJSON* value) {
  if (status == kRpcError) {
    return XAsprintf("MCP error %d: %s", (int)JsonNum(value, "code", 0),
                     JsonStr(value, "message", ""));
  }
  return XStrdup(status == kRpcTimeout ? "no answer in time" : "it exited");
}

static void List(McpServer* s, const char* cursor);

// RpcDoneFn for tools/list: keeps the page, asks for the next, and at the
// end stores the list and makes a starting server ready.
static void OnList(void* ctx, RpcStatus status, cJSON* value) {
  McpServer* s = ctx;
  if (status == kRpcClosed) return;
  if (status != kRpcOk) {
    char* why = CallProblem(status, value);
    char* text = XAsprintf("tools/list failed: %s", why);
    if (s->state == kMcpStarting) McpServerFail(s, text);
    free(text);
    free(why);
    return;
  }
  cJSON* tool;
  cJSON_ArrayForEach(tool, JsonGet(value, "tools")) {
    cJSON_AddItemToArray(s->listing, cJSON_Duplicate(tool, 1));
  }
  const char* next = JsonStr(value, "nextCursor", NULL);
  if (next && *next && ++s->pages < 50) {
    List(s, next);
    return;
  }
  double ttl = JsonNum(value, "ttlMs", JsonNum(s->info, "ttlMs", 0));
  cJSON* listing = s->listing;
  s->listing = NULL;
  int starting = s->state == kMcpStarting;
  if (starting) s->state = kMcpReady;
  McpCacheStore(s, listing, s->modern ? "modern" : "legacy", s->version,
                JsonStr(s->info, "instructions", NULL), ttl);
  if (starting) McpAnnounce(s, "ready", NULL, -1);
}

// Asks for one page of the tool list.
static void List(McpServer* s, const char* cursor) {
  cJSON* params = cJSON_CreateObject();
  if (cursor) {
    cJSON_AddStringToObject(params, "cursor", cursor);
  } else {
    cJSON_Delete(s->listing);
    s->listing = cJSON_CreateArray();
    s->pages = 0;
  }
  double limit = s->state == kMcpStarting ? StartupLeft(s) : 60;
  McpRequest(s, "tools/list", params, limit, OnList, s);
}

// The era is known and `result` describes the server: subscribe to list
// changes when it has them, then list the tools.
static void AfterEra(McpServer* s, cJSON* result, const char* version) {
  free(s->version);
  s->version = XStrdup(version);
  cJSON_Delete(s->info);
  s->info = cJSON_Duplicate(result, 1);
  if (s->modern && JsonBool(result, "capabilities.tools.listChanged", 0)) {
    cJSON* params = cJSON_CreateObject();
    cJSON* what = cJSON_AddObjectToObject(params, "notifications");
    cJSON_AddTrueToObject(what, "toolsListChanged");
    McpRequest(s, "subscriptions/listen", params, 0, NULL, NULL);
  }
  List(s, NULL);
}

// RpcDoneFn for initialize: a legacy server answered, or the start failed.
static void OnInitialize(void* ctx, RpcStatus status, cJSON* value) {
  McpServer* s = ctx;
  if (status == kRpcClosed) return;
  const char* version = JsonStr(value, "protocolVersion", "");
  int known = 0;
  for (const char* const* v = kLegacyVersions; *v; v++) {
    known |= !strcmp(*v, version);
  }
  if (status != kRpcOk) {
    char* why = CallProblem(status, value);
    char* text = XAsprintf(
        "it answered neither server/discover nor initialize (%s)", why);
    McpServerFail(s, text);
    free(text);
    free(why);
  } else if (!known) {
    char* text = XAsprintf("it speaks MCP %s, which arx does not", version);
    McpServerFail(s, text);
    free(text);
  } else {
    RpcNotify(s->peer, "notifications/initialized", NULL);
    AfterEra(s, value, version);
  }
}

// Sends the legacy handshake.
static void Initialize(McpServer* s) {
  cJSON* params = cJSON_CreateObject();
  cJSON_AddStringToObject(params, "protocolVersion", MCP_LEGACY_VERSION);
  cJSON_AddObjectToObject(params, "capabilities");
  cJSON* info = cJSON_AddObjectToObject(params, "clientInfo");
  cJSON_AddStringToObject(info, "name", "arx");
  cJSON_AddStringToObject(info, "version", ARX_VERSION);
  s->modern = 0;
  RpcCall(s->peer, "initialize", params, StartupLeft(s), OnInitialize, s);
}

// RpcDoneFn for server/discover. A result means a modern server. Error
// -32022 means a modern server without our revision. Anything else, also no
// answer, means a legacy server: the fallback depends on no one error code.
static void OnDiscover(void* ctx, RpcStatus status, cJSON* value) {
  McpServer* s = ctx;
  if (status == kRpcClosed) return;
  cJSON* versions = status == kRpcOk ? JsonGet(value, "supportedVersions")
                                     : JsonGet(value, "data.supported");
  int ours = 0;
  cJSON* v;
  cJSON_ArrayForEach(v, versions) {
    ours |= cJSON_IsString(v) && !strcmp(v->valuestring, MCP_VERSION);
  }
  int modern = status == kRpcOk ||
               (status == kRpcError && JsonNum(value, "code", 0) == -32022);
  if (!modern) {
    Initialize(s);
  } else if (!ours) {
    char* list = versions ? cJSON_PrintUnformatted(versions) : XStrdup("[]");
    char* text =
        XAsprintf("it speaks MCP %s, and arx speaks %s", list, MCP_VERSION);
    McpServerFail(s, text);
    free(text);
    free(list);
  } else {
    s->modern = 1;
    AfterEra(s, value, MCP_VERSION);
  }
}

// RpcHandlers.write: one line to the server's stdin.
static void Write(void* ctx, const char* data, size_t n) {
  McpServer* s = ctx;
  if (s->child) ProcWrite(s->child, data, n);
}

// RpcHandlers.request: a legacy ping gets {}; arx offers nothing else.
static void OnRequest(void* ctx, RpcPeer* p, cJSON* id, const char* method,
                      cJSON* params) {
  (void)ctx;
  (void)params;
  if (!strcmp(method, "ping")) {
    RpcReply(p, id, cJSON_CreateObject());
  } else {
    RpcReplyError(p, id, -32601, "arx does not serve this method", NULL);
  }
}

// RpcHandlers.notify: list changes, progress and log messages.
static void OnNotify(void* ctx, const char* method, cJSON* params) {
  McpServer* s = ctx;
  if (!strcmp(method, "notifications/tools/list_changed")) {
    if (s->state == kMcpReady && !s->listing) List(s, NULL);
  } else if (!strcmp(method, "notifications/progress")) {
    McpCallProgress(s, params);
  } else if (!strcmp(method, "notifications/message")) {
    char* text = cJSON_PrintUnformatted(params);
    McpLog(s, "message: %s", text ? text : "");
    free(text);
  }
}

// RpcHandlers.bad_line: a line that is not JSON-RPC goes to the log.
static void OnBadLine(void* ctx, const char* line, const char* why) {
  McpLog(ctx, "not JSON-RPC (%s): %.200s", why, line);
}

// Starts the probe on a server that just started; see mcp.h.
void McpProbe(McpServer* s) {
  RpcHandlers h = {Write, OnRequest, OnNotify, OnBadLine, s};
  s->peer = RpcNew(&h, 0);
  const char* era = JsonStr(s->cache, "era", "");
  if (!strcmp(era, "legacy")) {
    Initialize(s);
    return;
  }
  cJSON* params = cJSON_CreateObject();
  cJSON_AddItemToObject(params, "_meta", Meta());
  RpcCall(s->peer, "server/discover", params,
          *era ? StartupLeft(s) : kProbeSeconds, OnDiscover, s);
}
