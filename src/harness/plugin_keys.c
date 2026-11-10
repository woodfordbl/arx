// plugin_keys.c: a plugin's `instructions` and `model_settings`, as Adopt
// takes them in. Settings from the active list change them first, the text
// moves into the plugin's layer with absolute paths, and each model setting
// that the plugin adds is recorded with its source, so `arx check` can show
// it and warn when two plugins set one field to different values.

#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// Makes the {file:} paths of a text node absolute, relative to `dir`.
static void AbsoluteText(cJSON* node, const char* dir) {
  if (cJSON_IsArray(node)) {
    cJSON* c;
    cJSON_ArrayForEach(c, node) AbsoluteText(c, dir);
  }
  cJSON* file = JsonGet(node, "file");
  if (!cJSON_IsString(file)) return;
  char* path = PathJoin(dir, file->valuestring);
  cJSON_SetValuestring(file, path);
  free(path);
}

// Records `plugin` as the source of every leaf of `value` at `path`. A
// scalar, an array, null or an empty mapping is a leaf; a mapping recurses.
static void RecordLeaves(Spec* spec, cJSON* value, const char* path,
                         const char* plugin) {
  if (!cJSON_IsObject(value) || !value->child) {
    if (!spec->setting_from) spec->setting_from = cJSON_CreateObject();
    cJSON_AddStringToObject(spec->setting_from, path, plugin);
    return;
  }
  cJSON* c;
  cJSON_ArrayForEach(c, value) {
    char* p = XAsprintf("%s.%s", path, c->string);
    RecordLeaves(spec, c, p, plugin);
    free(p);
  }
}

// The plugin that set the setting at `path`, or one below it, or NULL when
// the spec, the kit, config.yaml or --set did.
static const char* SettingFrom(const Spec* spec, const char* path) {
  size_t n = strlen(path);
  cJSON* c;
  cJSON_ArrayForEach(c, spec->setting_from) {
    const char* key = c->string;
    if (!strncmp(key, path, n) && (!key[n] || key[n] == '.')) {
      return c->valuestring;
    }
  }
  return NULL;
}

// Walks a plugin's model settings (`mine`) against the spec's (`have`)
// before they merge. A field the spec lacks will come from this plugin. A
// field that a plugin set first keeps its value; when this one differs,
// that is a warning. Maps merge field by field, as SpecMergeUnder does.
static void TrackSettings(Spec* spec, cJSON* have, cJSON* mine,
                          const char* path, const char* plugin) {
  cJSON* m;
  cJSON_ArrayForEach(m, mine) {
    char* p = XAsprintf("%s.%s", path, m->string);
    cJSON* h = cJSON_IsObject(have)
                   ? cJSON_GetObjectItemCaseSensitive(have, m->string)
                   : NULL;
    const char* first = h ? SettingFrom(spec, p) : NULL;
    if (!h) {
      RecordLeaves(spec, m, p, plugin);
    } else if (cJSON_IsObject(h) && cJSON_IsObject(m)) {
      TrackSettings(spec, h, m, p, plugin);
    } else if (first && !cJSON_Compare(h, m, 1)) {
      char* kept = cJSON_PrintUnformatted(h);
      char* lost = cJSON_PrintUnformatted(m);
      BufferPrintf(&spec->warnings,
                   "- %s: plugins %s (%s) and %s (%s) both set it; %s wins, "
                   "as it loads first\n",
                   p, first, kept, plugin, lost, first);
      free(kept);
      free(lost);
    }
    free(p);
  }
}

// Takes in a plugin's instructions and model_settings; see harness.h.
void PluginKeysAdopt(Spec* spec, cJSON* root, Layer* layer, cJSON* over) {
  // A value in the settings replaces the text, and null drops it. Settings
  // for model_settings merge over the plugin's own, in Adopt. No setting
  // changes or drops a policy's text.
  cJSON* text = over ? NULL : JsonGet(layer->settings, "instructions");
  if (text) {
    cJSON_DeleteItemFromObjectCaseSensitive(root, "instructions");
    if (!cJSON_IsNull(text)) {
      cJSON_AddItemToObject(root, "instructions", cJSON_Duplicate(text, 1));
    }
  }
  // The text stays with the layer: it is added to the prompt, not merged
  // into the spec's instructions. A policy's model settings win over the
  // spec's, so they are tracked against the policies before it only.
  layer->instructions =
      cJSON_DetachItemFromObjectCaseSensitive(root, "instructions");
  AbsoluteText(layer->instructions, layer->dir);
  TrackSettings(spec, JsonGet(over ? over : spec->root, "model_settings"),
                JsonGet(root, "model_settings"), "model_settings",
                layer->plugin);
}
