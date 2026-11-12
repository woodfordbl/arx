// http_legacy.c: the bridge's side of a legacy HTTP server, one that
// speaks 2025-11-25 or earlier. When the first request gets 400, 404 or
// 405 without a JSON-RPC error, the bridge sends `initialize`, keeps the
// Mcp-Session-Id, sends notifications/initialized, and answers arx's
// server/discover from the InitializeResult, so arx sees a modern server.
// It opens no GET stream: a legacy server's list changes show at the next
// start.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

// The DiscoverResult for arx; see mcp.h.
cJSON* McpHttpDiscover(const Bridge* b) {
  cJSON* result = cJSON_CreateObject();
  const char* versions[] = {MCP_VERSION};
  cJSON_AddItemToObject(result, "supportedVersions",
                        cJSON_CreateStringArray(versions, 1));
  cJSON* capabilities = cJSON_AddObjectToObject(result, "capabilities");
  cJSON_AddObjectToObject(capabilities, "tools");
  const char* keep[] = {"serverInfo", "instructions"};
  for (int i = 0; i < 2; i++) {
    cJSON* v = cJSON_GetObjectItemCaseSensitive(b->init, keep[i]);
    if (v) cJSON_AddItemToObject(result, keep[i], cJSON_Duplicate(v, 1));
  }
  return result;
}

// Ends the handshake: the parked jobs go out, or end with `error`.
static void Unpark(Bridge* b, const char* error) {
  b->handshaking = 0;
  for (HttpJob* j = b->jobs; j; j = j->next) {
    if (!j->parked || j->over) continue;
    if (error) {
      McpHttpFail(b, j, "%s", error);
    } else if (!strcmp(j->method, "server/discover")) {
      RpcReply(b->up, j->id, McpHttpDiscover(b));
      j->over = 1;
    } else {
      McpHttpStart(b, j);
    }
  }
}

// HttpJobDone for notifications/initialized: the session is ready.
static void OnInitialized(Bridge* b, HttpJob* j, const HttpResult* r) {
  (void)r;
  j->over = 1;
  b->known = 1;
  Unpark(b, NULL);
}

// HttpJobDone for initialize: keeps the session and the result.
static void OnInitialize(Bridge* b, HttpJob* j, const HttpResult* r) {
  cJSON* result = cJSON_GetObjectItemCaseSensitive(j->response, "result");
  if (!result && McpHttpRetry(j, r)) return;
  j->over = 1;
  if (!result) {
    char* text = XAsprintf(
        "%s answered neither server/discover nor initialize (HTTP %d%s%.200s)",
        b->host, r->status, r->err.len ? ": " : "",
        r->err.len ? r->err.data : "");
    Unpark(b, text);
    free(text);
    return;
  }
  b->legacy = 1;
  free(b->version);
  b->version = XStrdup(JsonStr(result, "protocolVersion", MCP_LEGACY_VERSION));
  free(b->session);
  b->session = McpHttpHeader(r, "mcp-session-id");
  cJSON_Delete(b->init);
  b->init = cJSON_Duplicate(result, 1);
  McpHttpJob(b, NULL, "notifications/initialized", NULL, OnInitialized);
}

// Starts the handshake; see mcp.h.
void McpHttpLegacy(Bridge* b) {
  if (b->handshaking) return;
  b->handshaking = 1;
  cJSON* params = cJSON_CreateObject();
  cJSON_AddStringToObject(params, "protocolVersion", MCP_LEGACY_VERSION);
  cJSON_AddObjectToObject(params, "capabilities");
  cJSON* info = cJSON_AddObjectToObject(params, "clientInfo");
  cJSON_AddStringToObject(info, "name", "arx");
  cJSON_AddStringToObject(info, "version", ARX_VERSION);
  McpHttpJob(b, NULL, "initialize", params, OnInitialize);
}

// Ends the session; see mcp.h.
void McpHttpLegacyEnd(Bridge* b) {
  if (!b->session) return;
  HttpJob end = {.method = ""};
  char* headers = McpHttpHeaders(b, &end);
  HttpRequest req = {.method = "DELETE",
                     .url = b->url,
                     .headers = headers,
                     .timeout = 2,
                     .tmp_dir = b->tmp_dir};
  HttpResult r;
  HttpRun(&req, &r);
  BufferFree(&r.err);
  BufferFree(&r.headers);
  free(headers);
}
