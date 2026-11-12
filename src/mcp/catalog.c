// catalog.c: what arx knows about MCP tools without a running server. Each
// enabled server of the spec has a cache file, .arx/mcp/<server>.json, with
// the tools it listed last. The model sees a tool as <server>__<tool>.

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

static McpServer** g_servers;
static int g_count;
static struct Agent* g_agent;  // the agent McpSync ran for

// The number of servers; see mcp.h.
int McpServerCount(void) { return g_count; }

// One server by index; see mcp.h.
McpServer* McpServerAt(int i) {
  return i >= 0 && i < g_count ? g_servers[i] : NULL;
}

// One server by name; see mcp.h.
McpServer* McpServerFind(const char* name) {
  for (int i = 0; i < g_count; i++) {
    if (!strcmp(g_servers[i]->name, name)) return g_servers[i];
  }
  return NULL;
}

// FNV-1a over the entry's JSON; see mcp.h.
uint64_t McpHash(const cJSON* entry) {
  char* text = cJSON_PrintUnformatted(entry);
  uint64_t h = 1469598103934665603ULL;
  for (const char* p = text; p && *p; p++) {
    h = (h ^ (unsigned char)*p) * 1099511628211ULL;
  }
  free(text);
  return h;
}

// Reads the cache file of server `name` when it is for `hash`, or NULL.
static cJSON* ReadCache(const char* name, uint64_t hash) {
  char hex[32];
  snprintf(hex, sizeof(hex), "%016" PRIx64, hash);
  char* path = XAsprintf(".arx/mcp/%s.json", name);
  char* text = ReadFile(path, NULL);
  cJSON* cache = text ? cJSON_Parse(text) : NULL;
  free(text);
  free(path);
  if (strcmp(JsonStr(cache, "hash", ""), hex)) {
    cJSON_Delete(cache);
    return NULL;
  }
  return cache;
}

// The cached tool count; see mcp.h.
int McpCachedCount(const char* name, const cJSON* entry) {
  cJSON* cache = ReadCache(name, McpHash(entry));
  int n = cache ? cJSON_GetArraySize(JsonGet(cache, "tools")) : -1;
  cJSON_Delete(cache);
  return n;
}

// The server that `name` (<server>__<tool>) belongs to in `servers`, a
// mcp_servers map, or NULL.
static cJSON* OwnerEntry(cJSON* servers, const char* name) {
  cJSON* e;
  cJSON_ArrayForEach(e, servers) {
    size_t n = strlen(e->string);
    if (!strncmp(name, e->string, n) && !strncmp(name + n, "__", 2) &&
        name[n + 2]) {
      return e;
    }
  }
  return NULL;
}

// True for a name a configured server owns; see mcp.h.
int McpOwns(cJSON* root, const char* name) {
  return OwnerEntry(JsonGet(root, "mcp_servers"), name) != NULL;
}

// True when `s` matches the glob `pattern` (* and ?).
static int Glob(const char* pattern, const char* s) {
  for (; *pattern; pattern++, s++) {
    if (*pattern == '*') {
      for (const char* rest = s;; rest++) {
        if (Glob(pattern + 1, rest)) return 1;
        if (!*rest) return 0;
      }
    }
    if (!*s || (*pattern != '?' && *pattern != *s)) return 0;
  }
  return !*s;
}

// True when a pattern of the list matches `s`.
static int AnyGlob(cJSON* patterns, const char* s) {
  cJSON* p;
  cJSON_ArrayForEach(p, patterns) {
    if (cJSON_IsString(p) && Glob(p->valuestring, s)) return 1;
  }
  return 0;
}

// The name the model sees for the server's tool `remote`: other characters
// become _, and a name that is too long or taken ends in a hash.
static char* ModelName(const McpServer* s, const char* remote) {
  char* name = XAsprintf("%s__%s", s->name, remote);
  for (char* c = name; *c; c++) {
    if (!strchr(kNameChars, *c)) *c = '_';
  }
  int taken = 0;
  for (int i = 0; i < s->tool_count; i++) {
    taken |= !strcmp(s->tools[i].name, name);
  }
  if (strlen(name) <= 64 && !taken) return name;
  uint64_t h = 1469598103934665603ULL;
  for (const char* p = remote; *p; p++) {
    h = (h ^ (unsigned char)*p) * 1099511628211ULL;
  }
  char* hashed = XAsprintf("%.55s_%06x", name, (unsigned)(h & 0xffffff));
  free(name);
  return hashed;
}

// Frees a server's catalog tools; the definitions belong to the cache.
static void FreeTools(McpServer* s) {
  for (int i = 0; i < s->tool_count; i++) free(s->tools[i].name);
  free(s->tools);
  s->tools = NULL;
  s->tool_count = 0;
}

// Builds s->tools from the cache: the tools that pass include and exclude
// and that the spec's `tools.<name>.enabled` leaves on.
static void BuildTools(McpServer* s) {
  cJSON* root = g_agent ? g_agent->spec.root : NULL;
  cJSON* include = JsonGet(s->entry, "include");
  cJSON* def;
  FreeTools(s);
  cJSON_ArrayForEach(def, JsonGet(s->cache, "tools")) {
    const char* remote = JsonStr(def, "name", NULL);
    if (!remote || !*remote || (include && !AnyGlob(include, remote)) ||
        AnyGlob(JsonGet(s->entry, "exclude"), remote)) {
      continue;
    }
    char* name = ModelName(s, remote);
    cJSON* options =
        cJSON_GetObjectItemCaseSensitive(JsonGet(root, "tools"), name);
    if (!JsonBool(options, "enabled", 1)) {
      free(name);
      continue;
    }
    s->tools =
        XRealloc(s->tools, (size_t)(s->tool_count + 1) * sizeof(*s->tools));
    s->tools[s->tool_count].name = name;
    s->tools[s->tool_count++].def = def;
  }
}

// Takes the cache (may be NULL) as the server's list.
static void UseCache(McpServer* s, cJSON* cache) {
  FreeTools(s);
  cJSON_Delete(s->cache);
  s->cache = cache;
  double ttl = JsonNum(cache, "ttlMs", 0) / 1000;
  double age = (double)time(NULL) - JsonNum(cache, "listed_at", 0);
  s->fresh = cache && age < (ttl > 0 ? ttl : 86400);
  BuildTools(s);
}

// Stores a new list; see mcp.h.
void McpCacheStore(McpServer* s, cJSON* tools, const char* era,
                   const char* version, const char* instructions, double ttl) {
  char hex[32];
  snprintf(hex, sizeof(hex), "%016" PRIx64, s->hash);
  cJSON* cache = cJSON_CreateObject();
  cJSON_AddStringToObject(cache, "hash", hex);
  cJSON_AddStringToObject(cache, "era", era);
  cJSON_AddStringToObject(cache, "version", version ? version : "");
  if (instructions)
    cJSON_AddStringToObject(cache, "instructions", instructions);
  cJSON_AddNumberToObject(cache, "listed_at", (double)time(NULL));
  if (ttl > 0) cJSON_AddNumberToObject(cache, "ttlMs", ttl);
  cJSON_AddItemToObject(cache, "tools", tools);
  char* path = XAsprintf(".arx/mcp/%s.json", s->name);
  char* text = cJSON_PrintUnformatted(cache);
  MakeDirs(".arx/mcp");
  WriteFileAtomic(path, text, strlen(text));
  free(text);
  free(path);
  UseCache(s, cache);
  s->fresh = 1;
  if (g_agent) McpTools(g_agent);
}

// Frees a server that left the spec.
static void FreeServer(McpServer* s) {
  McpServerDrop(s);
  FreeTools(s);
  cJSON_Delete(s->cache);
  cJSON_Delete(s->entry);
  free(s->name);
  free(s);
}

// Makes the servers match the spec; see mcp.h.
void McpSync(struct Agent* a) {
  g_agent = a;
  cJSON* entries = JsonGet(a->spec.root, "mcp_servers");
  int n = cJSON_GetArraySize(entries), kept = 0;
  McpServer** next = XMalloc((size_t)(n + 1) * sizeof(*next));
  cJSON* e;
  cJSON_ArrayForEach(e, entries) {
    if (!McpEnabled(e)) continue;
    uint64_t hash = McpHash(e);
    McpServer* s = NULL;
    for (int i = 0; i < g_count && !s; i++) {
      if (g_servers[i] && !strcmp(g_servers[i]->name, e->string)) {
        s = g_servers[i];
        g_servers[i] = NULL;
      }
    }
    if (s && s->hash != hash) {  // a changed entry is a new server
      FreeServer(s);
      s = NULL;
    }
    if (!s) {
      s = XMalloc(sizeof(*s));
      memset(s, 0, sizeof(*s));
      s->name = XStrdup(e->string);
      s->entry = cJSON_Duplicate(e, 1);
      s->hash = hash;
      UseCache(s, ReadCache(s->name, hash));
    } else {
      BuildTools(s);  // the spec's tools.<name>.enabled may have changed
    }
    next[kept++] = s;
  }
  for (int i = 0; i < g_count; i++) {
    if (g_servers[i]) FreeServer(g_servers[i]);
  }
  free(g_servers);
  g_servers = next;
  g_count = kept;
  if (!McpSelectionLoad(a)) McpTools(a);
}

// Finds a catalog tool by the model's name; see mcp.h.
McpTool* McpFindTool(const char* name, McpServer** server) {
  for (int i = 0; i < g_count; i++) {
    for (int t = 0; t < g_servers[i]->tool_count; t++) {
      if (strcmp(g_servers[i]->tools[t].name, name)) continue;
      if (server) *server = g_servers[i];
      return &g_servers[i]->tools[t];
    }
  }
  return NULL;
}

// The server that owns the model's name `name`; see mcp.h.
McpServer* McpOwnerOf(const char* name) {
  for (int i = 0; i < g_count; i++) {
    size_t n = strlen(g_servers[i]->name);
    if (!strncmp(name, g_servers[i]->name, n) && !strncmp(name + n, "__", 2) &&
        name[n + 2]) {
      return g_servers[i];
    }
  }
  return NULL;
}
