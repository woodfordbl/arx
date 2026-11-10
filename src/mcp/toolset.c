// toolset.c: the MCP tools of the tool set. Only mcp_search, mcp_select,
// the preloaded tools and the tools the agent selected are in it, so a run
// with hundreds of MCP tools pays for two schemas until the agent picks.
// The selection lives in the session folder, so --resume keeps it.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

static const char kSearchParams[] =
    "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\","
    "\"description\":\"Words for the action, such as \\\"create issue\\\".\"},"
    "\"server\":{\"type\":\"string\",\"description\":\"Search only this "
    "server.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Most "
    "results: default 8, at most 25.\"}},\"required\":[\"query\"]}";
static const char kSelectParams[] =
    "{\"type\":\"object\",\"properties\":{\"names\":{\"type\":\"array\","
    "\"items\":{\"type\":\"string\"}},\"drop\":{\"type\":\"array\",\"items\":"
    "{\"type\":\"string\"}}}}";
static const char kSelectAbout[] =
    "Add MCP tools by the names mcp_search prints. Their full schemas are in "
    "your tools from your next turn, and you call them like any tool. drop "
    "removes tools you no longer need.";

static cJSON* g_selected;         // names, in selection order
static int64_t g_selected_mtime;  // of selected.json when it was read

// The selection; see mcp.h.
cJSON* McpSelection(void) {
  if (!g_selected) g_selected = cJSON_CreateArray();
  return g_selected;
}

// The path of selected.json (malloc'd), or NULL without a session.
static char* SelectionPath(const struct Agent* a) {
  if (!a->session.dir) return NULL;
  return XAsprintf("%s/mcp/selected.json", a->session.dir);
}

// Replaces and saves the selection; see mcp.h.
void McpSelectionSet(struct Agent* a, cJSON* names) {
  cJSON_Delete(g_selected);
  g_selected = names;
  char* path = SelectionPath(a);
  if (path) {
    char* dir = DirName(path);
    char* text = cJSON_PrintUnformatted(names);
    MakeDirs(dir);
    WriteFileAtomic(path, text, strlen(text));
    g_selected_mtime = MtimeNs(path, NULL);
    free(text);
    free(dir);
  }
  free(path);
  McpTools(a);
}

// Reads the selection when its file changed; see mcp.h.
int McpSelectionLoad(struct Agent* a) {
  char* path = SelectionPath(a);
  int64_t mtime = path ? MtimeNs(path, NULL) : -1;
  if (mtime == g_selected_mtime || mtime < 0) {
    free(path);
    return 0;
  }
  char* text = ReadFile(path, NULL);
  cJSON* names = text ? cJSON_Parse(text) : NULL;
  free(text);
  free(path);
  g_selected_mtime = mtime;
  if (!KeysValid(names)) {  // not a list of strings: keep what we have
    cJSON_Delete(names);
    return 0;
  }
  cJSON_Delete(g_selected);
  g_selected = names;
  McpTools(a);
  return 1;
}

// A server's line for mcp_search; see mcp.h.
char* McpServerAbout(const McpServer* s) {
  const char* text = JsonStr(s->entry, "description", NULL);
  if (text) return XStrdup(text);
  text = JsonStr(s->cache, "instructions", "");
  size_t n = strcspn(text, "\n");
  const char* stop = strstr(text, ". ");
  if (stop && (size_t)(stop - text) < n) n = (size_t)(stop - text);
  if (n > 160) n = 160;
  while (n && (text[n - 1] == '.' || text[n - 1] == ' ')) n--;
  return XStrndup(text, n);
}

// Appends one MCP tool to the set, unless a tool has that name. `params`
// is consumed.
static void AddTool(struct Agent* a, const char* name, const char* about,
                    cJSON* params, const McpServer* s, const char* remote) {
  ToolSet* set = &a->tools;
  for (int i = 0; i < set->count; i++) {
    if (!strcmp(set->items[i].name, name)) {
      cJSON_Delete(params);
      return;
    }
  }
  char key[160];
  snprintf(key, sizeof(key), "tools.%s.timeout", name);
  set->items = XRealloc(set->items, (size_t)(set->count + 1) * sizeof(Tool));
  Tool* t = &set->items[set->count++];
  memset(t, 0, sizeof(*t));
  t->kind = kToolMcp;
  t->name = XStrdup(name);
  t->description = XStrdup(about);
  t->params = params;
  cJSON* keys = s ? JsonGet(s->entry, "keys") : NULL;
  t->keys = s ? (keys ? cJSON_Duplicate(keys, 1) : NULL) : cJSON_CreateArray();
  t->server = s ? XStrdup(s->name) : NULL;
  t->remote = remote ? XStrdup(remote) : NULL;
  t->timeout = JsonDuration(a->spec.root, key,
                            s ? JsonDuration(s->entry, "timeout", 120) : 120);
}

// Removes `$schema` and the `x-` keys from a schema, but never a property
// that has such a name.
static void CleanSchema(cJSON* node, int properties) {
  for (cJSON* c = node ? node->child : NULL; c;) {
    cJSON* next = c->next;
    int named = cJSON_IsObject(node) && c->string && !properties;
    if (named &&
        (!strcmp(c->string, "$schema") || !strncmp(c->string, "x-", 2))) {
      cJSON_DetachItemViaPointer(node, c);
      cJSON_Delete(c);
    } else {
      CleanSchema(c, named && !strcmp(c->string, "properties"));
    }
    c = next;
  }
}

// Adds the tool the model calls `name`, from the catalog; a name that is
// not there yet, for a server that has not listed, gets an empty schema.
static void AddNamed(struct Agent* a, const char* name) {
  McpServer* s = NULL;
  McpTool* tool = McpFindTool(name, &s);
  cJSON* params =
      cJSON_Duplicate(JsonGet(tool ? tool->def : NULL, "inputSchema"), 1);
  if (!cJSON_IsObject(params)) {
    cJSON_Delete(params);
    params = cJSON_Parse("{\"type\":\"object\",\"properties\":{}}");
  }
  CleanSchema(params, 0);
  if (tool) {
    AddTool(a, name, JsonStr(tool->def, "description", ""), params, s,
            JsonStr(tool->def, "name", ""));
    return;
  }
  s = McpOwnerOf(name);
  if (s) {
    AddTool(a, name, "", params, s, name + strlen(s->name) + 2);
  } else {
    cJSON_Delete(params);
  }
}

// Rebuilds the MCP tools of the set; see mcp.h.
void McpTools(struct Agent* a) {
  ToolSet* set = &a->tools;
  while (set->count && set->items[set->count - 1].kind == kToolMcp) {
    Tool* t = &set->items[--set->count];
    free(t->name);
    free(t->description);
    free(t->server);
    free(t->remote);
    cJSON_Delete(t->params);
    cJSON_Delete(t->keys);
  }
  if (!McpServerCount()) return;
  Buffer about = {0};
  BufferAppendStr(&about, "Search the tools of these MCP servers: ");
  for (int i = 0; i < McpServerCount(); i++) {
    char* line = McpServerAbout(McpServerAt(i));
    BufferPrintf(&about, *line ? "%s%s (%s)" : "%s%s", i ? ", " : "",
                 McpServerAt(i)->name, line);
    free(line);
  }
  BufferAppendStr(&about,
                  ". Then call mcp_select with the names you need; their full "
                  "schemas are in your tools from the next turn. An empty "
                  "query lists the servers.");
  AddTool(a, "mcp_search", about.data, cJSON_Parse(kSearchParams), NULL, NULL);
  AddTool(a, "mcp_select", kSelectAbout, cJSON_Parse(kSelectParams), NULL,
          NULL);
  BufferFree(&about);
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    cJSON* preload = JsonGet(s->entry, "preload");
    for (int t = 0; t < s->tool_count; t++) {
      cJSON* p;
      int on = cJSON_IsTrue(preload);
      cJSON_ArrayForEach(p, preload) {
        on |= !strcmp(p->valuestring, JsonStr(s->tools[t].def, "name", ""));
      }
      if (on) AddNamed(a, s->tools[t].name);
    }
  }
  cJSON* name;
  cJSON_ArrayForEach(name, McpSelection()) AddNamed(a, name->valuestring);
}

// Selects a tool the model called without selecting it; see mcp.h.
Tool* McpToolFor(struct Agent* a, const char* name) {
  if (!McpServerCount()) return NULL;
  McpServer* s = NULL;
  if (!McpFindTool(name, &s)) {
    s = McpOwnerOf(name);
    if (!s || s->fresh) return NULL;  // it has listed, and has no such tool
  }
  cJSON* names = cJSON_Duplicate(McpSelection(), 1);
  cJSON_AddItemToArray(names, cJSON_CreateString(name));
  McpSelectionSet(a, names);
  for (int i = a->tools.count - 1; i >= 0; i--) {
    Tool* t = &a->tools.items[i];
    if (t->kind == kToolMcp && !strcmp(t->name, name)) return t;
  }
  return NULL;
}
