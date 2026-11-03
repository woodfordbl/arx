// plugins.c: the layers a harness is made of. The spec folder comes first;
// plugins (folders with a plugin.yaml) and the user's config folder add
// tools/, hooks/ and skills below it, so the agent's own files always win.

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// plugin.yaml keys that describe the plugin, or that PluginsLoad handles
// itself, so they are not merged into the spec.
static const char* const kOwnKeys[] = {"name",      "version",  "description",
                                       "arx",       "requires", "hooks",
                                       "observers", NULL};

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
  return layer;
}

// True when a plugin named `name` is already a layer: a project plugin hides
// a user plugin with the same name.
static int HavePlugin(const Spec* spec, const char* name) {
  for (int i = 0; i < spec->layer_count; i++) {
    const char* plugin = spec->layers[i].plugin;
    if (plugin && !strcmp(plugin, name)) return 1;
  }
  return 0;
}

// True when the spec's `plugins:` list names `name`, or there is no list.
static int Allowed(const Spec* spec, const char* name) {
  cJSON* list = JsonGet(spec->root, "plugins");
  cJSON* c;
  if (!cJSON_IsArray(list)) return 1;
  cJSON_ArrayForEach(c, list) {
    if (cJSON_IsString(c) && !strcmp(c->valuestring, name)) return 1;
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

// Wraps an observer command so that it runs with ARX_PLUGIN_DIR set.
static char* WithPluginDir(const char* dir, const char* command) {
  Buffer b = {0};
  BufferAppendStr(&b, "export ARX_PLUGIN_DIR='");
  for (const char* p = dir; *p; p++) {
    if (*p == '\'') {
      BufferAppendStr(&b, "'\\''");
    } else {
      BufferAppend(&b, p, 1);
    }
  }
  BufferPrintf(&b, "'; %s", command);
  return BufferTake(&b);
}

// Makes a path value absolute, relative to `dir`.
static void Absolute(cJSON* node, const char* dir) {
  if (!cJSON_IsString(node)) return;
  char* path = PathJoin(dir, node->valuestring);
  cJSON_SetValuestring(node, path);
  free(path);
}

// Merges a checked plugin.yaml under the spec and adds the plugin's layer.
static void Adopt(Spec* spec, Spec* plugin, const char* dir, const char* name) {
  cJSON* root = plugin->root;
  cJSON* c;
  Layer* layer = AddLayer(spec, dir, name, PathJoin(dir, "skills"));
  layer->hooks = cJSON_DetachItemFromObjectCaseSensitive(root, "hooks");
  cJSON_ArrayForEach(c, JsonGet(root, "tools")) {
    Absolute(JsonGet(c, "agent"), dir);
  }
  cJSON_ArrayForEach(c, JsonGet(root, "compactors")) Absolute(c, dir);
  cJSON* mine = JsonGet(root, "observers");
  cJSON* all = JsonGet(spec->root, "observers");
  if (cJSON_GetArraySize(mine) && !all) {
    all = cJSON_AddArrayToObject(spec->root, "observers");
  }
  for (c = cJSON_IsArray(all) && mine ? mine->child : NULL; c; c = c->next) {
    char* wrapped = WithPluginDir(dir, c->valuestring);
    cJSON_AddItemToArray(all, cJSON_CreateString(wrapped));
    free(wrapped);
  }
  for (const char* const* k = kOwnKeys; *k; k++) {
    cJSON_DeleteItemFromObjectCaseSensitive(root, *k);
  }
  SpecMergeUnder(spec, plugin);
}

// Parses and checks `dir`/plugin.yaml into `plugin`. Returns 0, or -1 with
// the problems in `err`.
static int ReadPlugin(const char* dir, Spec* plugin, Buffer* err) {
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

// Loads the plugin in `dir`, named after its folder. A problem skips it.
static void LoadPlugin(Spec* spec, const char* dir, const char* name) {
  Spec plugin;
  Buffer err = {0};
  char* real = realpath(dir, NULL);  // so ARX_PLUGIN_DIR is absolute
  const char* where = real ? real : dir;
  if (ReadPlugin(where, &plugin, &err) == 0) {
    const char* own = JsonStr(plugin.root, "name", name);
    if (strcmp(own, name)) {
      BufferPrintf(&err, "%s: name \"%s\" must match the folder name\n",
                   plugin.path, own);
    }
  }
  if (err.len) {
    BufferPrintf(&spec->problems, "- plugin %s was skipped:\n%s", name,
                 err.data);
  } else {
    Adopt(spec, &plugin, where, name);
  }
  SpecFree(&plugin);
  BufferFree(&err);
  free(real);
}

// Loads every plugin folder in `parent`, in name order. Folders without a
// plugin.yaml are not plugins and are passed over.
static void LoadPlugins(Spec* spec, const char* parent) {
  char** names;
  int n = ListNames(parent, &names);
  for (int i = 0; i < n; i++) {
    char* dir = XAsprintf("%s/%s", parent, names[i]);
    char* yaml = XAsprintf("%s/plugin.yaml", dir);
    if (!access(yaml, F_OK) && Allowed(spec, names[i]) &&
        !HavePlugin(spec, names[i])) {
      LoadPlugin(spec, dir, names[i]);
    }
    free(yaml);
    free(dir);
    free(names[i]);
  }
  free(names);
}

// Builds the layers; see harness.h.
void PluginsLoad(Spec* spec) {
  const char* skills = JsonStr(spec->root, "skills", NULL);
  char* config = ConfigDir();
  char* plugins = PathJoin(spec->dir, "plugins");
  AddLayer(spec, spec->dir, NULL, skills ? PathJoin(spec->dir, skills) : NULL);
  LoadPlugins(spec, plugins);
  free(plugins);
  if (!SameDir(spec->dir, config)) {
    // A `plugins:` list makes the harness exact: the spec folder and the
    // plugins it names, without loose files in the config folder.
    if (!cJSON_IsArray(JsonGet(spec->root, "plugins"))) {
      AddLayer(spec, config, NULL, PathJoin(config, "skills"));
    }
    plugins = PathJoin(config, "plugins");
    LoadPlugins(spec, plugins);
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
  }
  free(spec->layers);
  spec->layers = NULL;
  spec->layer_count = 0;
}

// True when `program` is an executable on PATH, or at its path when it
// has a '/'.
static int OnPath(const char* program) {
  if (strchr(program, '/')) return access(program, X_OK) == 0;
  const char* path = getenv("PATH");
  for (const char* p = path ? path : ""; *p;) {
    size_t len = strcspn(p, ":");
    char* full = XAsprintf("%.*s/%s", (int)len, p, program);
    int found = len && access(full, X_OK) == 0;
    free(full);
    if (found) return 1;
    p += len + (p[len] == ':');
  }
  return 0;
}

// Appends "key=value", with line breaks turned into spaces.
static void AppendField(Buffer* out, const char* key, const char* value) {
  BufferPrintf(out, "%s=", key);
  for (const char* p = value ? value : ""; *p; p++) {
    BufferAppend(out, *p == '\n' || *p == '\r' ? " " : p, 1);
  }
  BufferAppendStr(out, "\n");
}

// Appends "key=" and the entries of `dir`, space-separated. With `inner`,
// only entries that have `dir/<entry>/<inner>`.
static void AppendNames(Buffer* out, const char* key, const char* dir,
                        const char* inner) {
  char** names;
  int n = ListNames(dir, &names);
  Buffer list = {0};
  for (int i = 0; i < n; i++) {
    char* path = inner ? XAsprintf("%s/%s/%s", dir, names[i], inner) : NULL;
    if (!path || !access(path, R_OK)) {
      BufferPrintf(&list, "%s%s", list.len ? " " : "", names[i]);
    }
    free(path);
    free(names[i]);
  }
  free(names);
  AppendField(out, key, list.data);
  BufferFree(&list);
}

// Describes a plugin; see harness.h.
int PluginDescribe(const char* dir, Buffer* out, Buffer* err) {
  Spec plugin;
  int rc = ReadPlugin(dir, &plugin, err);
  if (rc == 0) {
    cJSON* root = plugin.root;
    char* real = realpath(dir, NULL);
    const char* base = strrchr(real ? real : dir, '/');
    Buffer
      requires
    = {0}, missing = {0};
    cJSON* c;
    AppendField(out, "name", JsonStr(root, "name", base ? base + 1 : dir));
    AppendField(out, "version", JsonStr(root, "version", ""));
    AppendField(out, "description", JsonStr(root, "description", ""));
    AppendField(out, "arx", JsonStr(root, "arx", ""));
    cJSON_ArrayForEach(c, JsonGet(root, "requires")) {
      BufferPrintf(&requires, "%s%s", requires.len ? " " : "", c->valuestring);
      if (!OnPath(c->valuestring)) {
        BufferPrintf(&missing, "%s%s", missing.len ? " " : "", c->valuestring);
      }
    }
    AppendField(out, "requires", requires.data);
    AppendField(out, "missing", missing.data);
    const char* parts[] = {"tools", "hooks", "skills", "commands"};
    for (int i = 0; i < 4; i++) {
      char* sub = PathJoin(dir, parts[i]);
      AppendNames(out, parts[i], sub, i == 2 ? "SKILL.md" : NULL);
      free(sub);
    }
    BufferFree(&requires);
    BufferFree(&missing);
    free(real);
  }
  SpecFree(&plugin);
  return rc;
}
