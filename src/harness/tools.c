// tools.c: builds the tool set. Executable tools are found by path and
// described by `--schema`; the answers are cached by modification time and
// size, so a reload only re-runs tools that changed.

#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"

static const char kBashParams[] =
    "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\","
    "\"description\":\"Shell command, run with sh -c in the working "
    "directory\"}},\"required\":[\"command\"]}";
static const char kEditParams[] =
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"old\":{\"type\":\"string\",\"description\":\"Exact text to replace; it "
    "must occur exactly once. Empty creates a new file.\"},\"new\":{\"type\":"
    "\"string\",\"description\":\"Replacement text\"}},\"required\":[\"path\","
    "\"old\",\"new\"]}";
static const char kAgentParams[] =
    "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\","
    "\"description\":\"The complete task. The subagent starts with no other "
    "context.\"}},\"required\":[\"task\"]}";

// How long `<tool> --schema` may take.
static const double kSchemaTimeout = 2.0;

// One cached `--schema` answer.
typedef struct SchemaEntry {
  char* path;
  int64_t mtime, size;
  char* description;
  char* error;  // why the tool is skipped, or NULL
  cJSON* params;
} SchemaEntry;

static SchemaEntry g_schemas[128];
static int g_schema_count;

// Runs `--schema` and fills in the entry.
static void LoadSchema(SchemaEntry* e) {
  Buffer out = {0};
  char* argv[] = {e->path, "--schema", NULL};
  Proc p = {.argv = argv,
            .timeout = kSchemaTimeout,
            .on_out = BufferSink,
            .out_ctx = &out};
  ProcResult r;
  cJSON* j = NULL;
  if (ProcRun(&p, &r)) {
    e->error = XAsprintf("cannot run it (%s)", strerror(errno));
  } else if (r.timed_out) {
    e->error = XStrdup("--schema took longer than 2s");
  } else if (r.code) {
    e->error = XAsprintf("--schema exited with %d", r.code);
  } else if (!(j = cJSON_Parse(out.data ? out.data : "")) ||
             !cJSON_IsObject(j)) {
    e->error = XStrdup(
        "--schema must print a JSON object {\"description\": "
        "..., \"parameters\": {...}}");
  } else {
    cJSON* params = cJSON_GetObjectItem(j, "parameters");
    e->description = XStrdup(JsonStr(j, "description", ""));
    e->params = cJSON_IsObject(params)
                    ? cJSON_Duplicate(params, 1)
                    : cJSON_Parse("{\"type\":\"object\",\"properties\":{}}");
  }
  cJSON_Delete(j);
  BufferFree(&out);
}

// Returns the cached schema for `path`, refreshing it if the file changed.
static SchemaEntry* SchemaFor(const char* path) {
  int64_t size, mtime = MtimeNs(path, &size);
  SchemaEntry* e = NULL;
  for (int i = 0; i < g_schema_count && !e; i++) {
    if (!strcmp(g_schemas[i].path, path)) e = &g_schemas[i];
  }
  if (e && e->mtime == mtime && e->size == size) return e;
  if (!e) {
    if (g_schema_count == 128) return NULL;
    e = &g_schemas[g_schema_count++];
    e->path = XStrdup(path);
  } else {
    free(e->description);
    free(e->error);
    cJSON_Delete(e->params);
    e->description = e->error = NULL;
    e->params = NULL;
  }
  e->mtime = mtime;
  e->size = size;
  LoadSchema(e);
  return e;
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
}

// True for the names of built-in tools.
static int IsBuiltin(const char* name) {
  return !strcmp(name, "bash") || !strcmp(name, "edit");
}

// qsort comparator for file names.
static int CompareNames(const void* a, const void* b) {
  return strcmp(*(char* const*)a, *(char* const*)b);
}

// Lists tools/ in sorted order, so the tool list (and the prompt cache)
// stays stable between reloads. Returns the count; free each name.
static int ListDir(const char* dir, char*** names) {
  int n = 0;
  DIR* d = opendir(dir);
  struct dirent* e;
  *names = NULL;
  while (d && (e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    *names = XRealloc(*names, (size_t)(n + 1) * sizeof(**names));
    (*names)[n++] = XStrdup(e->d_name);
  }
  if (d) closedir(d);
  if (n) qsort(*names, (size_t)n, sizeof(**names), CompareNames);
  return n;
}

// Adds the built-in tools unless the spec disables them.
static void AddBuiltins(struct Agent* a) {
  cJSON* root = a->spec.root;
  size_t head = JsonSize(root, "tool_output.head", 2048);
  size_t tail = JsonSize(root, "tool_output.tail", 6144);
  double timeout = JsonDuration(root, "tools.bash.timeout", 120);
  if (JsonBool(root, "tools.bash.enabled", 1)) {
    char* desc = XAsprintf(
        "Run a shell command (sh -c) in the working directory. You see the "
        "first %zu and last %zu bytes of output; the full output is saved to "
        "a file whose path is shown. Timeout %.0fs.",
        head, tail, timeout);
    Add(&a->tools, kToolBash, "bash", desc, kBashParams, NULL, NULL, timeout);
    free(desc);
  }
  if (JsonBool(root, "tools.edit.enabled", 1)) {
    Add(&a->tools, kToolEdit, "edit",
        "Replace an exact, unique string in a file, or create a new file "
        "when `old` is empty.",
        kEditParams, NULL, NULL, 0);
  }
}

// Adds one executable from tools/, or explains in `notes` why it is skipped.
static void AddExecutable(struct Agent* a, const char* dir, const char* name,
                          Buffer* notes) {
  char key[160];
  char* path = XAsprintf("%s/%s", dir, name);
  struct stat st;
  snprintf(key, sizeof(key), "tools.%s.enabled", name);
  if (stat(path, &st) || !S_ISREG(st.st_mode)) {
    // Directories and broken links are not tools.
  } else if (access(path, X_OK)) {
    BufferPrintf(notes, "- tools/%s is not executable (chmod +x it)\n", name);
  } else if (IsBuiltin(name) || strspn(name, kNameChars) != strlen(name)) {
    BufferPrintf(notes,
                 "- tools/%s skipped: use letters, digits, _ and -, "
                 "and not bash or edit\n",
                 name);
  } else if (JsonBool(a->spec.root, key, 1)) {
    SchemaEntry* s = SchemaFor(path);
    snprintf(key, sizeof(key), "tools.%s.timeout", name);
    if (!s) {
      BufferPrintf(notes, "- tools/%s skipped: too many tools\n", name);
    } else if (s->error) {
      BufferPrintf(notes, "- tools/%s skipped: %s\n", name, s->error);
    } else {
      Add(&a->tools, kToolExec, name, s->description, NULL, s->params, path,
          JsonDuration(a->spec.root, key, 120));
    }
  }
  free(path);
}

// Adds subagent tools and flags spec entries that match nothing.
static void AddConfigured(struct Agent* a, char** names, int n, Buffer* notes) {
  cJSON* entry;
  cJSON_ArrayForEach(entry, JsonGet(a->spec.root, "tools")) {
    const char* spec = JsonStr(entry, "agent", NULL);
    int found = IsBuiltin(entry->string);
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
  char* dir = PathJoin(a->spec.dir, "tools");
  ToolsFree(&a->tools);
  AddBuiltins(a);
  int n = ListDir(dir, &names);
  for (int i = 0; i < n; i++) AddExecutable(a, dir, names[i], &notes);
  AddConfigured(a, names, n, &notes);
  for (int i = 0; i < n; i++) free(names[i]);
  free(names);
  free(dir);
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
    cJSON_Delete(tools->items[i].params);
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
