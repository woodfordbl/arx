// active.c: the active list, the ordered list of plugins that one run uses.
// Four sources build it, each changing the list from the one before:
// config.yaml (a default kit or list), the kit, agent.yaml, and the
// launcher (--kit and --set). The position in the list is the priority.
// In each source, `kit:` replaces the list with the kit's, `plugins:`
// replaces it with its own, `enable:` adds to it and `disable:` takes out.
// Plugin settings merge in the order config.yaml, kit, agent.yaml, --set.
// When no source sets a kit or a list, every installed plugin is on, as
// before kits.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// The keys that build the active list, as one source gave them.
typedef struct ListSource {
  const char* label;  // "config.yaml", "agent.yaml" or "--set"
  cJSON* kit;         // a string, or NULL
  cJSON* plugins;     // a plugin list, or NULL
  cJSON* enable;      // a plugin list, or NULL
  cJSON* disable;     // a list of names, or NULL
} ListSource;

// Fills `source` with copies of the list keys of `root` (may be NULL).
static void ListSourceRead(ListSource* source, const char* label, cJSON* root) {
  const char* keys[] = {"kit", "plugins", "enable", "disable"};
  cJSON** slots[] = {&source->kit, &source->plugins, &source->enable,
                     &source->disable};
  source->label = label;
  for (int i = 0; i < 4; i++) {
    cJSON* v = cJSON_IsObject(root) ? JsonGet(root, keys[i]) : NULL;
    int ok = i == 0 ? cJSON_IsString(v) : cJSON_IsArray(v);
    *slots[i] = ok ? cJSON_Duplicate(v, 1) : NULL;
  }
}

// Frees the copies in `source`.
static void ListSourceFree(ListSource* source) {
  cJSON_Delete(source->kit);
  cJSON_Delete(source->plugins);
  cJSON_Delete(source->enable);
  cJSON_Delete(source->disable);
  memset(source, 0, sizeof(*source));
}

// The plugin name of an entry; see harness.h.
const char* EntryName(const cJSON* entry) {
  static char name[256];
  const char* ref = cJSON_IsString(entry) ? entry->valuestring
                    : cJSON_IsObject(entry) && entry->child
                        ? entry->child->string
                        : "";
  const char* slash = strrchr(ref, '/');
  if (slash) ref = slash + 1;
  size_t len = strcspn(ref, "@");
  if (len >= sizeof(name)) len = sizeof(name) - 1;
  memcpy(name, ref, len);
  name[len] = 0;
  return name;
}

// The settings of an entry ({name: {settings}}), or NULL.
static cJSON* EntrySettings(const cJSON* entry) {
  if (!cJSON_IsObject(entry) || !cJSON_IsObject(entry->child)) return NULL;
  return entry->child;
}

// Merges the settings of each entry of `list` into `settings`.
static void AddSettings(cJSON* settings, const cJSON* list) {
  const cJSON* c;
  cJSON_ArrayForEach(c, list) {
    cJSON* mine = EntrySettings(c);
    if (!mine) continue;
    const char* name = EntryName(c);
    cJSON* have = cJSON_GetObjectItemCaseSensitive(settings, name);
    if (!have) have = cJSON_AddObjectToObject(settings, name);
    JsonMergeOver(have, mine);
  }
}

// The index of `name` in the active list, or -1.
static int IndexOf(const cJSON* list, const char* name) {
  int i = 0;
  const cJSON* c;
  cJSON_ArrayForEach(c, list) {
    if (!strcmp(JsonStr((cJSON*)c, "name", ""), name)) return i;
    i++;
  }
  return -1;
}

// Appends the entries of `entries` that the list lacks, with `why`.
static void Append(cJSON* list, const cJSON* entries, const char* why) {
  const cJSON* c;
  cJSON_ArrayForEach(c, entries) {
    const char* name = EntryName(c);
    if (!*name || IndexOf(list, name) >= 0) continue;
    cJSON* row = cJSON_CreateObject();
    cJSON_AddStringToObject(row, "name", name);
    cJSON_AddStringToObject(row, "why", why);
    cJSON_AddItemToArray(list, row);
  }
}

// Applies one source's enable: and disable: to the list (NULL: every
// installed plugin) and to `off`.
static void EnableDisable(cJSON* list, cJSON* off, const ListSource* s) {
  const cJSON* c;
  char* why = XAsprintf("enable in %s", s->label);
  if (list) Append(list, s->enable, why);
  cJSON_ArrayForEach(c, s->enable) {
    cJSON_DeleteItemFromObjectCaseSensitive(off, EntryName(c));
  }
  free(why);
  why = XAsprintf("disable in %s", s->label);
  cJSON_ArrayForEach(c, s->disable) {
    const char* name = EntryName(c);
    int at = list ? IndexOf(list, name) : -1;
    if (at >= 0) cJSON_DeleteItemFromArray(list, at);
    cJSON_DeleteItemFromObjectCaseSensitive(off, name);
    cJSON_AddStringToObject(off, name, why);
  }
  free(why);
}

// The spec values a kit gives: model_settings, and instructions from its
// prompt.
static cJSON* KitRoot(const Kit* kit) {
  cJSON* root = cJSON_CreateObject();
  if (kit->model_settings) {
    cJSON_AddItemToObject(root, "model_settings",
                          cJSON_Duplicate(kit->model_settings, 1));
  }
  if (kit->prompt) {
    cJSON* file = cJSON_CreateObject();
    cJSON_AddStringToObject(file, "file", kit->prompt);
    cJSON_AddItemToArray(cJSON_AddArrayToObject(root, "instructions"), file);
  }
  return root;
}

// Builds the list from `count` sources, in order.
static int Build(Spec* spec, ListSource* sources, int count, cJSON** kit_root,
                 Buffer* err) {
  *kit_root = NULL;
  int kit_at = -1;
  for (int i = 0; i < count; i++) {
    if (sources[i].kit) kit_at = i;
  }
  Kit kit = {0};
  char name[256] = "";
  if (kit_at >= 0) {
    snprintf(name, sizeof(name), "%s", sources[kit_at].kit->valuestring);
    name[strcspn(name, "@")] = 0;  // --kit coding@v1 uses kit coding
    if (KitLoad(spec->dir, name, &kit, err)) return -1;
    spec->kit = XStrdup(name);
    spec->kit_dir = XStrdup(kit.dir);
    spec->kit_from =
        XStrdup(strcmp(sources[kit_at].label, "--set") ? sources[kit_at].label
                                                       : "--kit");
    spec->kit_pinned = kit.pinned;
    *kit_root = KitRoot(&kit);
  }
  cJSON* list = NULL;  // NULL: every installed plugin
  cJSON* off = cJSON_CreateObject();
  for (int i = 0; i < count; i++) {
    const ListSource* s = &sources[i];
    if (s->kit || s->plugins) {
      // A kit or a list replaces what the sources before it built.
      cJSON_Delete(list);
      cJSON_Delete(off);
      list = cJSON_CreateArray();
      off = cJSON_CreateObject();
    }
    if (i == kit_at) {
      char* why = XAsprintf("kit %s", name);
      Append(list, kit.plugins, why);
      free(why);
    }
    if (s->plugins) {
      char* why = XAsprintf("plugins in %s", s->label);
      Append(list, s->plugins, why);
      free(why);
    }
    EnableDisable(list, off, s);
  }
  // Settings: config.yaml, then the kit, then agent.yaml and --set.
  cJSON* settings = cJSON_CreateObject();
  for (int i = 0; i < count; i++) {
    AddSettings(settings, sources[i].plugins);
    AddSettings(settings, sources[i].enable);
    if (i == 0) AddSettings(settings, kit.plugins);  // sources[0]: config
  }
  KitFree(&kit);
  spec->active = list;
  spec->off = off;
  spec->settings = settings;
  return 0;
}

// Builds the active list; see harness.h.
int ActiveBuild(Spec* spec, cJSON* config, cJSON* agent, cJSON* sets,
                cJSON** kit_root, Buffer* err) {
  ListSource sources[3];
  int n = 0;
  ListSourceRead(&sources[n++], "config.yaml", config);
  if (agent) ListSourceRead(&sources[n++], "agent.yaml", agent);
  ListSourceRead(&sources[n++], "--set", sets);
  int rc = Build(spec, sources, n, kit_root, err);
  for (int i = 0; i < n; i++) ListSourceFree(&sources[i]);
  return rc;
}
