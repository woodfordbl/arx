// spec.c: the `mcp_servers` key of agent.yaml, config.yaml and plugin.yaml.
// The field table (src/harness/fields.c) checks the types; this file checks
// what a table cannot say, makes a plugin's paths absolute, and expands
// ${NAME} when a server starts, so tokens stay out of the spec.

#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

// True when the entry is a server arx may start; see mcp.h.
int McpEnabled(const cJSON* entry) {
  cJSON* e = (cJSON*)entry;
  return cJSON_IsObject(e) && JsonBool(e, "enabled", 1) &&
         (JsonStr(e, "command", NULL) || JsonStr(e, "url", NULL));
}

// Reports each value of the map `key` of server `name` that is no string.
static void CheckStrings(const Spec* spec, const char* name, cJSON* entry,
                         const char* key, Buffer* err) {
  cJSON* v;
  cJSON_ArrayForEach(v, cJSON_GetObjectItemCaseSensitive(entry, key)) {
    if (cJSON_IsString(v)) continue;
    char* path = XAsprintf("mcp_servers.%s.%s.%s", name, key, v->string);
    SpecProblem(spec, err, path, "must be a string (quote it)");
    free(path);
  }
}

// True when `credential` is a name in `credentials:` or a program.
static int CredentialResolves(const Spec* spec, const char* credential) {
  cJSON* map = JsonGet(spec->root, "credentials");
  if (cJSON_GetObjectItemCaseSensitive(map, credential)) return 1;
  char* path = PathJoin(spec->dir, credential);
  int ok = IsRunnable(path);
  free(path);
  return ok;
}

// Checks one server entry.
static void CheckServer(const Spec* spec, cJSON* e, int plugin, Buffer* err) {
  char* at = XAsprintf("mcp_servers.%s", e->string);
  char* key = XAsprintf("%s.type", at);
  size_t len = strlen(e->string);
  const char* command = JsonStr(e, "command", NULL);
  const char* url = JsonStr(e, "url", NULL);
  const char* type = JsonStr(e, "type", NULL);
  const char* credential = JsonStr(e, "credential", NULL);
  if (!len || len > 32 || strspn(e->string, kNameChars) != len ||
      strstr(e->string, "__")) {
    SpecProblem(spec, err, at,
                "server names use letters, digits, _ and - (32 max), and "
                "no \"__\"");
  }
  if (command && url) {
    SpecProblem(spec, err, at, "give command (stdio) or url (http), not both");
  } else if (!command && !url && JsonBool(e, "enabled", 1)) {
    SpecProblem(spec, err, at, "needs command (stdio) or url (http)");
  }
  if (type && !strcmp(type, "sse")) {
    SpecProblem(spec, err, key,
                "the HTTP+SSE transport is not supported; use the server's "
                "streamable HTTP URL with type: http");
  } else if (type && strcmp(type, "stdio") && strcmp(type, "http")) {
    SpecProblem(spec, err, key, "must be stdio or http");
  } else if (type && ((command && *type == 'h') || (url && *type == 's'))) {
    SpecProblem(spec, err, key, "%s goes with %s", type,
                *type == 'h' ? "url, not command" : "command, not url");
  }
  if (url && strncmp(url, "http://", 7) && strncmp(url, "https://", 8) &&
      strncmp(url, "${", 2)) {
    free(key);
    key = XAsprintf("%s.url", at);
    SpecProblem(spec, err, key, "must start with http:// or https://");
  }
  if (JsonStr(e, "api_key_env", NULL) && !(command && credential)) {
    free(key);
    key = XAsprintf("%s.api_key_env", at);
    SpecProblem(spec, err, key, "needs command and credential");
  }
  if (credential && !plugin && !CredentialResolves(spec, credential)) {
    free(key);
    key = XAsprintf("%s.credential", at);
    SpecProblem(spec, err, key,
                "not a name in credentials, and not an executable");
  }
  CheckStrings(spec, e->string, e, "env", err);
  CheckStrings(spec, e->string, e, "headers", err);
  free(key);
  free(at);
}

// Checks every server; see mcp.h.
void McpValidate(const Spec* spec, int plugin, Buffer* err) {
  cJSON* e;
  cJSON_ArrayForEach(e, JsonGet(spec->root, "mcp_servers")) {
    if (cJSON_IsObject(e)) CheckServer(spec, e, plugin, err);
  }
}

// Makes a plugin's server paths absolute; see mcp.h.
void McpAdopt(cJSON* servers, const char* dir) {
  cJSON* e;
  cJSON_ArrayForEach(e, servers) {
    if (!cJSON_IsObject(e)) continue;
    const char* keys[] = {"command", "cwd"};
    for (int i = 0; i < 2; i++) {
      cJSON* v = cJSON_GetObjectItemCaseSensitive(e, keys[i]);
      if (!cJSON_IsString(v) || (i == 0 && !strchr(v->valuestring, '/'))) {
        continue;
      }
      char* path = PathJoin(dir, v->valuestring);
      cJSON_SetValuestring(v, path);
      free(path);
    }
    cJSON* env = cJSON_GetObjectItemCaseSensitive(e, "env");
    if (!env && JsonStr(e, "command", NULL)) {
      env = cJSON_AddObjectToObject(e, "env");
    }
    if (cJSON_IsObject(env) && !cJSON_GetObjectItem(env, "ARX_PLUGIN_DIR")) {
      cJSON_AddStringToObject(env, "ARX_PLUGIN_DIR", dir);
    }
  }
}

// Adds the hosts of the servers' URLs; see mcp.h.
void McpHosts(const Spec* spec, cJSON* hosts) {
  cJSON* e;
  cJSON_ArrayForEach(e, JsonGet(spec->root, "mcp_servers")) {
    const char* url = JsonStr(e, "url", NULL);
    if (!url || !McpEnabled(e)) continue;
    Buffer host = {0};
    AppendHost(&host, url);
    int have = !host.len;
    cJSON* c;
    cJSON_ArrayForEach(c, hosts) {
      have |= cJSON_IsString(c) && !strcmp(c->valuestring, host.data);
    }
    if (!have) cJSON_AddItemToArray(hosts, cJSON_CreateString(host.data));
    BufferFree(&host);
  }
}

// The servers for `arx check`; see mcp.h.
void McpCheck(const Spec* spec, Buffer* line, Buffer* warnings) {
  cJSON* e;
  cJSON_ArrayForEach(e, JsonGet(spec->root, "mcp_servers")) {
    const char* url = JsonStr(e, "url", NULL);
    if (!McpEnabled(e)) continue;
    int cached = McpCachedCount(e->string, e);
    BufferPrintf(line, " %s (%s, ", e->string, url ? "http" : "stdio");
    BufferPrintf(line, cached < 0 ? "not listed)" : "%d tools cached)", cached);
    Buffer host = {0};
    AppendHost(&host, url ? url : "");
    if (url && !strncmp(url, "http://", 7) && strcmp(host.data, "localhost") &&
        strncmp(host.data, "127.", 4) && strcmp(host.data, "[::1]")) {
      BufferPrintf(warnings,
                   "- mcp_servers.%s.url is http, not https: what it sends "
                   "to %s is not encrypted\n",
                   e->string, host.data);
    }
    BufferFree(&host);
  }
}

// Expands ${NAME} and ${NAME:-default}; see mcp.h.
char* McpExpand(const char* text, Buffer* err) {
  Buffer b = {0};
  BufferAppendStr(&b, "");
  for (const char* p = text; *p;) {
    const char* open = strstr(p, "${");
    const char* close = open ? strchr(open, '}') : NULL;
    if (!close) {
      BufferAppendStr(&b, p);
      break;
    }
    BufferAppend(&b, p, (size_t)(open - p));
    char* name = XStrndup(open + 2, (size_t)(close - open - 2));
    char* fallback = strstr(name, ":-");
    if (fallback) *fallback = 0;
    const char* value = getenv(name);
    if (!value && fallback) value = fallback + 2;
    if (!value) {
      BufferPrintf(err, "the environment variable %s is not set", name);
      free(name);
      BufferFree(&b);
      return NULL;
    }
    BufferAppendStr(&b, value);
    free(name);
    p = close + 1;
  }
  return BufferTake(&b);
}
