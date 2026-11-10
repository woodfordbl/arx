// plugins.c: the layers a harness is made of. The spec folder comes first;
// plugins (folders with a plugin.yaml) and the user's config folder add
// tools/, hooks/ and skills below it, so the agent's own files always win.
// With an active list (active.c), only its plugins load, in its order.

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

// plugin.yaml keys that describe the plugin, or that PluginsLoad handles
// itself, so they are not merged into the spec.
static const char* const kOwnKeys[] = {
    "name",  "version",   "description", "arx",   "requires",
    "hooks", "observers", "replaces",    "hosts", NULL};

// qsort comparator for names.
static int CompareNames(const void* a, const void* b) {
  return strcmp(*(char* const*)a, *(char* const*)b);
}

// Lists a folder, sorted; see harness.h.
int ListNames(const char* dir, char*** names) {
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

// True when `a` and `b` are the same folder.
static int SameDir(const char* a, const char* b) {
  char* ra = realpath(a, NULL);
  char* rb = realpath(b, NULL);
  int same = ra && rb ? !strcmp(ra, rb) : !strcmp(a, b);
  free(ra);
  free(rb);
  return same;
}

// Appends a layer and returns it. Takes ownership of `skills`.
static Layer* AddLayer(Spec* spec, const char* dir, const char* plugin,
                       char* skills) {
  spec->layers = XRealloc(
      spec->layers, (size_t)(spec->layer_count + 1) * sizeof(*spec->layers));
  Layer* layer = &spec->layers[spec->layer_count++];
  layer->dir = XStrdup(dir);
  layer->plugin = plugin ? XStrdup(plugin) : NULL;
  layer->skills = skills;
  layer->hooks = NULL;
  layer->settings = NULL;
  layer->replaces = NULL;
  layer->instructions = NULL;
  return layer;
}

// Adds a row for `arx check --list`.
static void AddRow(Spec* spec, const char* name, const char* state,
                   const char* why, const char* dir) {
  if (!spec->rows) spec->rows = cJSON_CreateArray();
  cJSON* row = cJSON_CreateObject();
  cJSON_AddStringToObject(row, "name", name);
  cJSON_AddStringToObject(row, "state", state);
  cJSON_AddStringToObject(row, "why", why);
  cJSON_AddStringToObject(row, "dir", dir ? dir : "");
  cJSON_AddItemToArray(spec->rows, row);
}

// True when the rows already have `name`.
static int HaveRow(const Spec* spec, const char* name) {
  cJSON* row;
  cJSON_ArrayForEach(row, spec->rows) {
    if (!strcmp(JsonStr(row, "name", ""), name)) return 1;
  }
  return 0;
}

// "1.2.3" as one comparable number (missing parts count as 0), or -1 when
// `s` does not start with a digit, as in a build of an untagged commit.
static int64_t VersionNumber(const char* s) {
  int64_t v = 0;
  if (!isdigit((unsigned char)*s)) return -1;
  for (int part = 0; part < 3; part++) {
    int64_t n = 0;
    while (isdigit((unsigned char)*s)) n = n * 10 + (*s++ - '0');
    v = v * 100000 + n;
    if (*s == '.') s++;
  }
  return v;
}

// Why this arx cannot use a plugin whose `arx:` is `constraint` (">=0.2"),
// or NULL when it can. A build that is not a release ("0.1.0-4-gabc1234",
// or no number at all) accepts any plugin.
static char* VersionProblem(const char* constraint) {
  if (!constraint) return NULL;
  int ok = !strncmp(constraint, ">=", 2);
  const char* need = ok ? constraint + 2 + strspn(constraint + 2, " ") : "";
  if (!ok || VersionNumber(need) < 0) {
    return XAsprintf("arx: \"%s\" must look like \">=0.2.0\"", constraint);
  }
  int64_t have = strchr(ARX_VERSION, '-') ? -1 : VersionNumber(ARX_VERSION);
  if (have >= 0 && have < VersionNumber(need)) {
    return XAsprintf("needs arx %s, and this is arx %s", constraint,
                     ARX_VERSION);
  }
  return NULL;
}

// Wraps an observer command so that it runs with ARX_PLUGIN_DIR and the
// plugin's state folders set. The name needs no quoting: it is letters,
// digits, _ and -.
static char* WithPluginEnv(const char* dir, const char* name,
                           const char* command) {
  Buffer b = {0};
  BufferAppendStr(&b, "export ARX_PLUGIN_DIR='");
  for (const char* p = dir; *p; p++) {
    if (*p == '\'') {
      BufferAppendStr(&b, "'\\''");
    } else {
      BufferAppend(&b, p, 1);
    }
  }
  BufferPrintf(&b,
               "' ARX_STATE_DIR=\"$ARX_SESSION_DIR/plugins/%s\" "
               "ARX_DATA_DIR=\"$ARX_CWD/.arx/data/%s\"; %s",
               name, name, command);
  return BufferTake(&b);
}

// Makes a path value absolute, relative to `dir`.
static void Absolute(cJSON* node, const char* dir) {
  if (!cJSON_IsString(node)) return;
  char* path = PathJoin(dir, node->valuestring);
  cJSON_SetValuestring(node, path);
  free(path);
}

// Adds a plugin's hosts to the spec's `hosts`, each once.
static void AppendHosts(Spec* spec, cJSON* hosts) {
  cJSON* all = JsonGet(spec->root, "hosts");
  if (cJSON_GetArraySize(hosts) && !all) {
    all = cJSON_AddArrayToObject(spec->root, "hosts");
  }
  if (!cJSON_IsArray(all)) return;
  cJSON* h;
  cJSON_ArrayForEach(h, hosts) {
    int have = 0;
    cJSON* c;
    cJSON_ArrayForEach(c, all) have |= cJSON_Compare(c, h, 1);
    if (!have) cJSON_AddItemToArray(all, cJSON_Duplicate(h, 1));
  }
}

// Merges a checked plugin.yaml under the spec and adds the plugin's layer.
static void Adopt(Spec* spec, Spec* plugin, const char* dir, const char* name) {
  cJSON* root = plugin->root;
  cJSON* c;
  Layer* layer = AddLayer(spec, dir, name, PathJoin(dir, "skills"));
  cJSON* settings = cJSON_GetObjectItemCaseSensitive(spec->settings, name);
  // Settings may set the plugin's own tool and hook options, model settings
  // and MCP servers; PluginKeysAdopt applies them to its instructions.
  const char* own[] = {"tools", "hooks", "model_settings", "mcp_servers"};
  for (int i = 0; i < 4; i++) {
    cJSON* over = JsonGet(settings, own[i]);
    if (!cJSON_IsObject(over)) continue;
    cJSON* base = JsonGet(root, own[i]);
    if (!cJSON_IsObject(base)) {
      cJSON_DeleteItemFromObjectCaseSensitive(root, own[i]);
      base = cJSON_AddObjectToObject(root, own[i]);
    }
    JsonMergeOver(base, over);
  }
  layer->settings = settings ? cJSON_Duplicate(settings, 1) : NULL;
  layer->hooks = cJSON_DetachItemFromObjectCaseSensitive(root, "hooks");
  layer->replaces = cJSON_DetachItemFromObjectCaseSensitive(root, "replaces");
  PluginKeysAdopt(spec, root, layer);
  cJSON_ArrayForEach(c, JsonGet(root, "tools")) {
    Absolute(JsonGet(c, "agent"), dir);
  }
  const char* programs[] = {"compactors", "credentials", "adapters"};
  for (int i = 0; i < 3; i++) {
    cJSON_ArrayForEach(c, JsonGet(root, programs[i])) Absolute(c, dir);
  }
  McpAdopt(JsonGet(root, "mcp_servers"), dir);
  AppendHosts(spec, JsonGet(root, "hosts"));
  cJSON* mine = JsonGet(root, "observers");
  cJSON* all = JsonGet(spec->root, "observers");
  if (cJSON_GetArraySize(mine) && !all) {
    all = cJSON_AddArrayToObject(spec->root, "observers");
  }
  for (c = cJSON_IsArray(all) && mine ? mine->child : NULL; c; c = c->next) {
    char* wrapped = WithPluginEnv(dir, name, c->valuestring);
    cJSON_AddItemToArray(all, cJSON_CreateString(wrapped));
    free(wrapped);
  }
  for (const char* const* k = kOwnKeys; *k; k++) {
    cJSON_DeleteItemFromObjectCaseSensitive(root, *k);
  }
  SpecMergeUnder(spec, plugin);
}

// Reads and checks a plugin.yaml; see harness.h.
int PluginRead(const char* dir, Spec* plugin, Buffer* err) {
  size_t before = err->len;
  memset(plugin, 0, sizeof(*plugin));
  plugin->path = XAsprintf("%s/plugin.yaml", dir);
  plugin->dir = XStrdup(dir);
  if (access(plugin->path, R_OK)) {
    BufferPrintf(err, "%s: not a plugin (no plugin.yaml)\n", dir);
  } else if (SpecParse(plugin->path, plugin, err) == 0) {
    PluginValidate(plugin, err);
    char* why = VersionProblem(JsonStr(plugin->root, "arx", NULL));
    if (why) BufferPrintf(err, "%s: %s\n", plugin->path, why);
    free(why);
  }
  return err->len == before ? 0 : -1;
}

// Loads the plugin in `dir`, named after its folder; `why` says why it is
// on. A problem skips it.
static void LoadPlugin(Spec* spec, const char* dir, const char* name,
                       const char* why) {
  Spec plugin;
  Buffer err = {0};
  char* real = realpath(dir, NULL);  // so ARX_PLUGIN_DIR is absolute
  const char* where = real ? real : dir;
  if (PluginRead(where, &plugin, &err) == 0) {
    const char* own = JsonStr(plugin.root, "name", name);
    if (strcmp(own, name)) {
      BufferPrintf(&err, "%s: name \"%s\" must match the folder name\n",
                   plugin.path, own);
    }
  }
  if (err.len) {
    BufferPrintf(&spec->problems, "- plugin %s was skipped:\n%s", name,
                 err.data);
    AddRow(spec, name, "broken", "skipped: see arx check", where);
  } else {
    Adopt(spec, &plugin, where, name);
    AddRow(spec, name, "on", why, where);
  }
  SpecFree(&plugin);
  BufferFree(&err);
  free(real);
}

// Why an installed plugin that is not in the active list is off.
static char* OffWhy(const Spec* spec, const char* name) {
  const char* off = JsonStr(spec->off, name, NULL);
  if (off) return XStrdup(off);
  if (spec->kit) return XAsprintf("not in kit %s", spec->kit);
  return XStrdup("not in the plugins list");
}

// Loads every plugin folder in `parent`, in name order, when there is no
// active list (`load`), or else adds a row for each one that is off.
// Folders without a plugin.yaml are not plugins and are passed over.
static void LoadPlugins(Spec* spec, const char* parent, int load) {
  char** names;
  int n = ListNames(parent, &names);
  for (int i = 0; i < n; i++) {
    char* dir = XAsprintf("%s/%s", parent, names[i]);
    char* yaml = XAsprintf("%s/plugin.yaml", dir);
    if (access(yaml, F_OK) || HaveRow(spec, names[i])) {
      // not a plugin, or a project plugin hides it
    } else if (load && !JsonStr(spec->off, names[i], NULL)) {
      LoadPlugin(spec, dir, names[i], "installed");
    } else {
      char* why = OffWhy(spec, names[i]);
      AddRow(spec, names[i], "off", why, dir);
      free(why);
    }
    free(yaml);
    free(dir);
    free(names[i]);
  }
  free(names);
}

// Loads the plugins of the active list, in its order: each from the spec's
// plugins/ folder, else from the config folder's.
static void LoadActive(Spec* spec, const char* config) {
  cJSON* row;
  cJSON_ArrayForEach(row, spec->active) {
    const char* name = JsonStr(row, "name", "");
    const char* why = JsonStr(row, "why", "");
    char* dir = NULL;
    const char* parents[] = {spec->dir, config};
    for (int i = 0; i < 2 && !dir && parents[i]; i++) {
      char* yaml = XAsprintf("%s/plugins/%s/plugin.yaml", parents[i], name);
      if (!access(yaml, F_OK))
        dir = XAsprintf("%s/plugins/%s", parents[i], name);
      free(yaml);
    }
    if (dir) {
      LoadPlugin(spec, dir, name, why);
    } else {
      BufferPrintf(&spec->problems,
                   "- plugin %s (%s) is not installed: run `arx plugin add "
                   "%s`\n",
                   name, why, name);
      AddRow(spec, name, "missing", why, NULL);
    }
    free(dir);
  }
}

// Builds the layers; see harness.h.
void PluginsLoad(Spec* spec) {
  const char* skills = JsonStr(spec->root, "skills", NULL);
  char* config = ConfigDir();
  char* plugins = PathJoin(spec->dir, "plugins");
  int all = spec->active == NULL;
  int other = !SameDir(spec->dir, config);
  AddLayer(spec, spec->dir, NULL, skills ? PathJoin(spec->dir, skills) : NULL);
  if (!all) LoadActive(spec, other ? config : NULL);
  LoadPlugins(spec, plugins, all);
  free(plugins);
  if (other) {
    // A kit or a list makes the harness exact: the spec folder and the
    // plugins it names, without loose files in the config folder.
    if (all) AddLayer(spec, config, NULL, PathJoin(config, "skills"));
    plugins = PathJoin(config, "plugins");
    LoadPlugins(spec, plugins, all);
    free(plugins);
  }
  free(config);
}

// Frees the layers; see harness.h.
void LayersFree(Spec* spec) {
  for (int i = 0; i < spec->layer_count; i++) {
    Layer* layer = &spec->layers[i];
    free(layer->dir);
    free(layer->plugin);
    free(layer->skills);
    cJSON_Delete(layer->hooks);
    cJSON_Delete(layer->settings);
    cJSON_Delete(layer->replaces);
    cJSON_Delete(layer->instructions);
  }
  free(spec->layers);
  spec->layers = NULL;
  spec->layer_count = 0;
}
