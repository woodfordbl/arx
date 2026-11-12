// tools.c: builds the tool set from the tools/ folder of every layer
// (tool_layers.c says which layer's tool wins).
// Executable tools are found by path and described by a <name>.json file
// next to them, or else by `--schema` (description, parameters and keys);
// the answers are cached by modification time and size, so a reload only
// reads tools that changed.

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

static const char kAgentParams[] =
    "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\","
    "\"description\":\"The complete task. The subagent starts with no other "
    "context.\"}},\"required\":[\"task\"]}";

// How long `<tool> --schema` may take.
static const double kSchemaTimeout = 2.0;

// One cached schema, from <path>.json or `--schema`.
typedef struct SchemaEntry {
  char* path;
  int64_t mtime, size, json_mtime, json_size;
  char* description;
  char* error;  // why the tool is skipped, or NULL
  cJSON* params;
  char* core;   // the `arx tool NAME` the file hands over to, or NULL
  cJSON* keys;  // the declared keys, or NULL
} SchemaEntry;

static SchemaEntry g_schemas[128];
static int g_schema_count;

// The NAME when the file at `path` only runs `exec "$ARX_BIN" tool NAME`
// (with an optional "$@", a #! line and comments), else NULL. arx then
// starts `arx tool NAME` itself: the result is the same, without a shell,
// which takes about 3 ms on macOS.
static char* CoreTool(const char* path, int64_t size) {
  static const char kPrefix[] = "exec \"$ARX_BIN\" tool ";
  const size_t prefix_len = sizeof(kPrefix) - 1;
  if (size <= 0 || size > 512) return NULL;
  char* text = ReadFile(path, NULL);
  char *save = NULL, *found = NULL;
  for (char* line = text ? strtok_r(text, "\n", &save) : NULL; line;
       line = strtok_r(NULL, "\n", &save)) {
    line += strspn(line, " \t");
    if (!*line || *line == '#') continue;
    char *name = NULL, *rest = NULL;
    size_t n = 0;
    if (!found && !strncmp(line, kPrefix, prefix_len)) {
      name = line + prefix_len;
      n = strspn(name, kNameChars);
      rest = name + n + strspn(name + n, " \t");
      if (!strncmp(rest, "\"$@\"", 4)) rest += 4 + strspn(rest + 4, " \t");
    }
    if (!n || *rest) {  // anything else: run the file as it is
      free(found);
      found = NULL;
      break;
    }
    found = XStrndup(name, n);
  }
  free(text);
  return found;
}

// Fills in the entry from a parsed schema; `what` names its source in the
// error.
static void ReadSchema(SchemaEntry* e, cJSON* j, const char* what) {
  if (!cJSON_IsObject(j)) {
    e->error = XAsprintf(
        "%s must be a JSON object {\"description\": ..., \"parameters\": "
        "{...}}",
        what);
    return;
  }
  cJSON* params = cJSON_GetObjectItem(j, "parameters");
  cJSON* keys = cJSON_GetObjectItem(j, "keys");
  if (keys && !KeysValid(keys)) {
    e->error = XAsprintf("%s: \"keys\" must be a list of strings", what);
    return;
  }
  e->keys = keys ? cJSON_Duplicate(keys, 1) : NULL;
  e->description = XStrdup(JsonStr(j, "description", ""));
  e->params = cJSON_IsObject(params)
                  ? cJSON_Duplicate(params, 1)
                  : cJSON_Parse("{\"type\":\"object\",\"properties\":{}}");
}

// Reads <path>.json when there is one, else runs `--schema`, and fills in
// the entry.
static void LoadSchema(SchemaEntry* e, const char* json) {
  e->core = CoreTool(e->path, e->size);
  if (e->json_size >= 0) {
    char* text = ReadFile(json, NULL);
    cJSON* j = cJSON_Parse(text ? text : "");
    ReadSchema(e, j, strrchr(json, '/') + 1);
    cJSON_Delete(j);
    free(text);
    return;
  }
  Buffer out = {0};
  char* file_argv[] = {e->path, "--schema", NULL};
  char* core_argv[] = {g_self, "tool", e->core, "--schema", NULL};
  Proc p = {.argv = e->core ? core_argv : file_argv,
            .timeout = kSchemaTimeout,
            .on_out = BufferSink,
            .out_ctx = &out};
  ProcResult r;
  if (ProcRun(&p, &r)) {
    e->error = XAsprintf("cannot run it (%s)", strerror(errno));
  } else if (r.timed_out) {
    e->error = XStrdup("--schema took longer than 2s");
  } else if (r.code) {
    e->error = XAsprintf("--schema exited with %d", r.code);
  } else {
    cJSON* j = cJSON_Parse(out.data ? out.data : "");
    ReadSchema(e, j, "--schema output");
    cJSON_Delete(j);
  }
  BufferFree(&out);
}

// Returns the cached schema for `path`, refreshing it if the file changed.
static SchemaEntry* SchemaFor(const char* path) {
  char* json = XAsprintf("%s.json", path);
  int64_t size, mtime = MtimeNs(path, &size);
  int64_t json_size, json_mtime = MtimeNs(json, &json_size);
  SchemaEntry* e = NULL;
  for (int i = 0; i < g_schema_count && !e; i++) {
    if (!strcmp(g_schemas[i].path, path)) e = &g_schemas[i];
  }
  if (e && e->mtime == mtime && e->size == size &&
      e->json_mtime == json_mtime && e->json_size == json_size) {
    free(json);
    return e;
  }
  if (!e) {
    if (g_schema_count == 128) {
      free(json);
      return NULL;
    }
    e = &g_schemas[g_schema_count++];
    e->path = XStrdup(path);
  } else {
    free(e->description);
    free(e->error);
    free(e->core);
    cJSON_Delete(e->params);
    cJSON_Delete(e->keys);
    e->description = e->error = e->core = NULL;
    e->params = e->keys = NULL;
  }
  e->mtime = mtime;
  e->size = size;
  e->json_mtime = json_mtime;
  e->json_size = json_size;
  LoadSchema(e, json);
  free(json);
  return e;
}

// Fills in {{timeout}}, {{tool_output.head}} and {{tool_output.tail}}, so a
// description can give the limits that the spec sets for the tool.
static char* Describe(const char* text, double timeout, cJSON* root) {
  static const char* const kFields[] = {"{{timeout}}", "{{tool_output.head}}",
                                        "{{tool_output.tail}}"};
  Buffer b = {0};
  BufferAppendStr(&b, "");
  for (const char* p = text; *p;) {
    const char* open = strstr(p, "{{");
    int field = -1;
    for (int i = 0; open && i < 3 && field < 0; i++) {
      if (!strncmp(open, kFields[i], strlen(kFields[i]))) field = i;
    }
    if (!open) {
      BufferAppendStr(&b, p);
      break;
    }
    BufferAppend(&b, p, (size_t)(open - p) + (field < 0 ? 2 : 0));
    p = open + (field < 0 ? 2 : strlen(kFields[field]));
    if (field == 0) BufferPrintf(&b, "%.0f", timeout);
    if (field == 1) {
      BufferPrintf(&b, "%zu", JsonSize(root, "tool_output.head", 2048));
    }
    if (field == 2) {
      BufferPrintf(&b, "%zu", JsonSize(root, "tool_output.tail", 6144));
    }
  }
  return BufferTake(&b);
}

// Appends a tool. `params` is JSON text, or NULL when `params_json` is set.
static void Add(ToolSet* t, ToolKind kind, const char* name, const char* desc,
                const char* params, cJSON* params_json, const char* path,
                double timeout) {
  t->items = XRealloc(t->items, (size_t)(t->count + 1) * sizeof(*t->items));
  Tool* tool = &t->items[t->count++];
  tool->kind = kind;
  tool->name = XStrdup(name);
  tool->description = XStrdup(desc);
  tool->params =
      params_json ? cJSON_Duplicate(params_json, 1) : cJSON_Parse(params);
  tool->path = path ? XStrdup(path) : NULL;
  tool->timeout = timeout;
  tool->plugin_dir = NULL;
  tool->plugin = NULL;
  tool->core = NULL;
  tool->keys = kind == kToolAgent ? cJSON_CreateArray() : NULL;
}

// Adds one executable from a layer's tools/; see trust.h.
void ToolAddExecutable(struct Agent* a, const Layer* layer, const char* where,
                       const char* name, Buffer* notes) {
  char key[160];
  char* path = XAsprintf("%s/tools/%s", layer->dir, name);
  struct stat st;
  snprintf(key, sizeof(key), "tools.%s.enabled", name);
  if (stat(path, &st) || !S_ISREG(st.st_mode)) {
    // Directories and broken links are not tools.
  } else if (!IsRunnable(path)) {
    BufferPrintf(notes, "- %stools/%s is not executable (chmod +x it)\n", where,
                 name);
  } else if (strspn(name, kNameChars) != strlen(name)) {
    BufferPrintf(notes, "- %stools/%s skipped: use letters, digits, _ and -\n",
                 where, name);
  } else if (JsonBool(a->spec.root, key, 1)) {
    SchemaEntry* s = SchemaFor(path);
    snprintf(key, sizeof(key), "tools.%s.timeout", name);
    if (!s) {
      BufferPrintf(notes, "- %stools/%s skipped: too many tools\n", where,
                   name);
    } else if (s->error) {
      BufferPrintf(notes, "- %stools/%s skipped: %s\n", where, name, s->error);
    } else {
      double timeout = JsonDuration(a->spec.root, key, 120);
      char* desc = Describe(s->description, timeout, a->spec.root);
      Add(&a->tools, kToolExec, name, desc, NULL, s->params, path, timeout);
      Tool* t = &a->tools.items[a->tools.count - 1];
      if (layer->plugin) {
        t->plugin_dir = XStrdup(layer->dir);
        t->plugin = XStrdup(layer->plugin);
      }
      if (s->core) t->core = XStrdup(s->core);
      if (s->keys) t->keys = cJSON_Duplicate(s->keys, 1);
      free(desc);
    }
  }
  free(path);
}

// Adds subagent tools and flags spec entries that match nothing.
static void AddConfigured(struct Agent* a, char** names, int n, Buffer* notes) {
  cJSON* entry;
  cJSON_ArrayForEach(entry, JsonGet(a->spec.root, "tools")) {
    const char* spec = JsonStr(entry, "agent", NULL);
    int found = 0;
    for (int i = 0; i < n && !found; i++)
      found = !strcmp(names[i], entry->string);
    if (spec) {
      char* path = PathJoin(a->spec.dir, spec);
      char* desc = XAsprintf(
          "Delegate a task to the %s subagent (spec %s). It starts with no "
          "context, so give it the complete task. Returns its final answer.",
          entry->string, spec);
      if (access(path, R_OK)) {
        BufferPrintf(notes, "- tools.%s: subagent spec %s not found\n",
                     entry->string, path);
      } else {
        Add(&a->tools, kToolAgent, entry->string,
            JsonStr(entry, "description", desc), kAgentParams, NULL, path,
            JsonDuration(entry, "timeout", 1800));
      }
      free(desc);
      free(path);
    } else if (!found && JsonBool(entry, "enabled", 1)) {
      BufferPrintf(notes, "- tools.%s is configured but tools/%s is missing\n",
                   entry->string, entry->string);
    }
  }
}

// Rebuilds the tool set; see harness.h.
void ToolsBuild(struct Agent* a) {
  Buffer notes = {0};
  char** names;
  ToolsFree(&a->tools);
  if (a->spec.problems.len) BufferAppendStr(&notes, a->spec.problems.data);
  int n = ToolsAddLayers(a, &names, &notes);
  AddConfigured(a, names, n, &notes);
  for (int i = 0; i < n; i++) free(names[i]);
  free(names);
  // Tell the agent about problems once, not again on every reload.
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < notes.len; i++) {
    h = (h ^ (unsigned char)notes.data[i]) * 1099511628211ULL;
  }
  if (notes.len && h != a->notes_sig) {
    AgentNote(a, "Tool problems:\n%s", notes.data);
  }
  a->notes_sig = notes.len ? h : 0;
  BufferFree(&notes);
}

// Frees every tool.
void ToolsFree(ToolSet* tools) {
  for (int i = 0; i < tools->count; i++) {
    free(tools->items[i].name);
    free(tools->items[i].description);
    free(tools->items[i].path);
    free(tools->items[i].plugin_dir);
    free(tools->items[i].plugin);
    free(tools->items[i].core);
    cJSON_Delete(tools->items[i].params);
    cJSON_Delete(tools->items[i].keys);
  }
  free(tools->items);
  tools->items = NULL;
  tools->count = 0;
}

// The "tools" array of a Chat Completions request.
cJSON* ToolsJson(const ToolSet* tools) {
  cJSON* array = cJSON_CreateArray();
  for (int i = 0; i < tools->count; i++) {
    cJSON* tool = cJSON_CreateObject();
    cJSON_AddStringToObject(tool, "type", "function");
    cJSON* fn = cJSON_AddObjectToObject(tool, "function");
    cJSON_AddStringToObject(fn, "name", tools->items[i].name);
    cJSON_AddStringToObject(fn, "description", tools->items[i].description);
    cJSON_AddItemToObject(fn, "parameters",
                          cJSON_Duplicate(tools->items[i].params, 1));
    cJSON_AddItemToArray(array, tool);
  }
  return array;
}
