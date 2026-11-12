// http_headers.c: what the bridge puts on each HTTP request. The current
// MCP revision repeats the method, the tool name and marked arguments in
// headers (Mcp-Method, Mcp-Name, Mcp-Param-*), so a gateway can route a
// request without reading its body. The Authorization header comes from a
// credential program, the one contract model calls use.

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"
#include "src/model/model.h"

// Appends `text` in base64.
static void Base64(Buffer* out, const char* text) {
  static const char kDigits[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t n = strlen(text);
  for (size_t i = 0; i < n; i += 3) {
    unsigned bits = (unsigned char)text[i] << 16;
    if (i + 1 < n) bits |= (unsigned)(unsigned char)text[i + 1] << 8;
    if (i + 2 < n) bits |= (unsigned char)text[i + 2];
    char four[4] = {kDigits[bits >> 18], kDigits[(bits >> 12) & 63],
                    i + 1 < n ? kDigits[(bits >> 6) & 63] : '=',
                    i + 2 < n ? kDigits[bits & 63] : '='};
    BufferAppend(out, four, 4);
  }
}

// Appends "Name: value\n". A value that is not plain ASCII, or that has
// spaces at its ends, goes as =?base64?...?=, as the spec says.
static void AppendEncoded(Buffer* out, const char* name, const char* value) {
  size_t n = strlen(value);
  int plain = n && value[0] != ' ' && value[n - 1] != ' ';
  for (const char* p = value; *p && plain; p++) {
    plain = (unsigned char)*p >= 0x20 && (unsigned char)*p < 0x7f;
  }
  BufferPrintf(out, "%s: ", name);
  if (plain) {
    BufferAppendStr(out, value);
  } else {
    BufferAppendStr(out, "=?base64?");
    Base64(out, value);
    BufferAppendStr(out, "?=");
  }
  BufferAppendStr(out, "\n");
}

// Appends the header lines of the map `headers`, skipping a name the
// lines already have and any value that would break a line.
static void AppendMap(Buffer* out, cJSON* headers) {
  cJSON* h;
  cJSON_ArrayForEach(h, headers) {
    if (!cJSON_IsString(h) || strpbrk(h->valuestring, "\r\n") ||
        strpbrk(h->string, "\r\n: ")) {
      continue;
    }
    BufferPrintf(out, "%s: %s\n", h->string, h->valuestring);
  }
}

// The header lines of a job; see mcp.h.
char* McpHttpHeaders(const Bridge* b, const HttpJob* j) {
  Buffer out = {0};
  BufferAppendStr(&out,
                  "Content-Type: application/json\n"
                  "Accept: application/json, text/event-stream\n");
  // The handshake itself names no version: it negotiates one.
  if (strcmp(j->method, "initialize")) {
    BufferPrintf(&out, "MCP-Protocol-Version: %s\n",
                 b->legacy && b->version ? b->version : MCP_VERSION);
  }
  if (*j->method) AppendEncoded(&out, "Mcp-Method", j->method);
  const char* tool = JsonStr(j->params, "name", NULL);
  if (tool && !strcmp(j->method, "tools/call")) {
    AppendEncoded(&out, "Mcp-Name", tool);
    cJSON* h;
    cJSON_ArrayForEach(
        h, cJSON_GetObjectItemCaseSensitive(b->tool_headers, tool)) {
      cJSON* v = cJSON_GetObjectItemCaseSensitive(
          JsonGet(j->params, "arguments"), h->string);
      if (!v || cJSON_IsNull(v) || cJSON_IsObject(v) || cJSON_IsArray(v)) {
        continue;
      }
      char* name = XAsprintf("Mcp-Param-%s", h->valuestring);
      char* value = cJSON_IsString(v) ? XStrdup(v->valuestring)
                                      : cJSON_PrintUnformatted(v);
      AppendEncoded(&out, name, value);
      free(value);
      free(name);
    }
  }
  if (b->session) BufferPrintf(&out, "Mcp-Session-Id: %s\n", b->session);
  cJSON* mine = JsonGet(b->credential, "headers");
  const char* key = JsonStr(b->credential, "api_key", NULL);
  AppendMap(&out, mine);
  if (key && !cJSON_GetObjectItem(mine, "Authorization")) {
    BufferPrintf(&out, "Authorization: Bearer %s\n", key);
  }
  AppendMap(&out, JsonGet(b->entry, "headers"));
  return BufferTake(&out);
}

// The header name an argument's x-mcp-header gives, or NULL when it breaks
// the rules: a string of letters, digits and -, on a string, number or
// boolean argument.
static const char* HeaderOf(cJSON* property) {
  const char* name = JsonStr(property, "x-mcp-header", NULL);
  const char* type = JsonStr(property, "type", "");
  if (!name || !*name) return NULL;
  for (const char* p = name; *p; p++) {
    if (!isalnum((unsigned char)*p) && *p != '-') return NULL;
  }
  return !strcmp(type, "string") || !strcmp(type, "number") ||
                 !strcmp(type, "integer") || !strcmp(type, "boolean")
             ? name
             : NULL;
}

// Reads the x-mcp-header marks of a tool list; see mcp.h.
void McpHttpTools(Bridge* b, cJSON* result) {
  cJSON* tools = cJSON_GetObjectItemCaseSensitive(result, "tools");
  if (!b->tool_headers) b->tool_headers = cJSON_CreateObject();
  for (cJSON* tool = tools ? tools->child : NULL; tool;) {
    cJSON* next = tool->next;
    const char* name = JsonStr(tool, "name", "");
    cJSON* map = cJSON_CreateObject();
    int bad = 0;
    cJSON* property;
    cJSON_ArrayForEach(property, JsonGet(tool, "inputSchema.properties")) {
      if (!cJSON_GetObjectItemCaseSensitive(property, "x-mcp-header")) continue;
      const char* header = HeaderOf(property);
      cJSON* h;
      cJSON_ArrayForEach(h, map) {  // two arguments may not share a header
        bad |= header && !strcasecmp(h->valuestring, header);
      }
      bad |= !header;
      if (header) cJSON_AddStringToObject(map, property->string, header);
    }
    cJSON_DeleteItemFromObjectCaseSensitive(b->tool_headers, name);
    if (bad) {
      fprintf(stderr,
              "[arx mcp http] dropped the tool %s: its x-mcp-header is not "
              "valid\n",
              name);
      cJSON_Delete(map);
      cJSON_Delete(cJSON_DetachItemViaPointer(tools, tool));
    } else {
      cJSON_AddItemToObject(b->tool_headers, name, map);
    }
    tool = next;
  }
}

// Runs the credential program; see mcp.h.
int McpHttpCredential(Bridge* b, const char* reason, int status,
                      const char* challenge, Buffer* why) {
  cJSON* in = cJSON_CreateObject();
  cJSON_AddStringToObject(in, "reason", reason);
  cJSON_AddStringToObject(in, "server", b->name);
  cJSON_AddStringToObject(in, "url", b->url);
  cJSON_AddStringToObject(in, "base_url", b->url);
  if (status) cJSON_AddNumberToObject(in, "status", status);
  if (challenge) cJSON_AddStringToObject(in, "challenge", challenge);
  cJSON* value = NULL;
  CredentialStatus result =
      CredentialRun(JsonStr(b->entry, "credential", ""), in, &value, why);
  if (result != kCredentialOk) return -1;
  cJSON_Delete(b->credential);
  b->credential = value;
  b->expires = JsonNum(value, "expires_at", 0);
  return 0;
}

// One response header; see mcp.h.
char* McpHttpHeader(const HttpResult* r, const char* name) {
  size_t n = strlen(name);
  for (const char* line = r->headers.data; line && *line;) {
    const char* nl = strchr(line, '\n');
    size_t len = nl ? (size_t)(nl - line) : strlen(line);
    if (len > n && !strncasecmp(line, name, n) && line[n] == ':') {
      const char* value = line + n + 1;
      while (*value == ' ') value++;
      size_t end = (size_t)(line + len - value);
      while (end && (value[end - 1] == '\r' || value[end - 1] == ' ')) end--;
      return XStrndup(value, end);
    }
    line = nl ? nl + 1 : NULL;
  }
  return NULL;
}
