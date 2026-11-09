// check.c: `arx check` and `arx tools`. They load the harness the way a run
// does, without a session, and report it: the kit, tools, hooks, the prompt
// and model settings, and plugins in order, the problems, and warnings about
// plugins that change the same field, hide a tool without saying so, set a
// model setting apart, or add long text to the prompt.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"

static const char* const kBandNames[] = {"policy", "normal", "final"};
// Bytes of text above which one plugin's instructions get a warning.
static const size_t kLongText = 4096;

// Loads the spec for a command; prints problems. Returns 0 or kExitUsage.
static int LoadSpec(Agent* a) {
  Buffer err = {0};
  ResolveSpec(a);
  int failed = SpecLoad(a->spec_path, a->sets, &a->spec, &err);
  if (failed) fputs(err.data, stderr);
  BufferFree(&err);
  return failed ? kExitUsage : 0;
}

// The executable at `layer`/<sub>/<name>, or NULL (malloc'd).
static char* LayerFile(const Layer* layer, const char* sub, const char* name) {
  char* path = XAsprintf("%s/%s/%s", layer->dir, sub, name);
  if (IsRunnable(path)) return path;
  free(path);
  return NULL;
}

// How warnings name a layer.
static char* LayerLabel(const Spec* spec, const Layer* layer) {
  if (layer->plugin) return XAsprintf("plugin %s", layer->plugin);
  if (layer == &spec->layers[0]) return XStrdup("the spec folder");
  return XStrdup("the config folder");
}

// Prints the hooks of every layer, with the plugins that add them.
static void PrintHooks(Agent* a) {
  printf("\nhooks:");
  for (const char* const* p = kHookPoints; *p; p++) {
    Buffer from = {0};
    int found = 0;
    for (int l = 0; l < a->spec.layer_count; l++) {
      const Layer* layer = &a->spec.layers[l];
      char* path = LayerFile(layer, "hooks", *p);
      if (path) {
        found = 1;
        if (layer->plugin) {
          BufferPrintf(&from, "%s%s", from.len ? "," : "", layer->plugin);
        }
      }
      free(path);
    }
    if (found) printf(" %s", *p);
    if (from.len) printf("(%s)", from.data);
    BufferFree(&from);
  }
  printf("\n");
}

// The size of a text node's raw text, before it renders.
static size_t TextBytes(const Spec* spec, cJSON* node) {
  char* text = SpecText(spec, node, NULL);
  size_t n = text ? strlen(text) : 0;
  free(text);
  return n;
}

// Prints where the base prompt comes from, and the plugins that add text:
// "prompt: kit coding; plugins add reviewer (212 bytes), ...".
static void PrintPrompt(const Spec* spec) {
  printf("prompt: %s", spec->prompt_from ? spec->prompt_from : "default");
  int any = 0;
  for (int l = 0; l < spec->layer_count; l++) {
    const Layer* layer = &spec->layers[l];
    if (!layer->plugin || !layer->instructions) continue;
    printf("%s%s (%zu bytes)", any ? ", " : "; plugins add ", layer->plugin,
           TextBytes(spec, layer->instructions));
    any = 1;
  }
  printf("\n");
}

// Prints each model setting under `node` (at `path`) as compact JSON, with
// the plugin that set it, or "spec" for the spec, kit, config.yaml and
// --set: "model_settings: top_p=0.9 (spec), seed=1 (plugin p)".
static void PrintSettings(const Spec* spec, cJSON* node, const char* path,
                          int* any) {
  cJSON* c;
  cJSON_ArrayForEach(c, node) {
    char* p = *path ? XAsprintf("%s.%s", path, c->string) : XStrdup(c->string);
    if (cJSON_IsObject(c) && c->child) {
      PrintSettings(spec, c, p, any);
    } else {
      char* key = XAsprintf("model_settings.%s", p);
      cJSON* from = cJSON_GetObjectItemCaseSensitive(spec->setting_from, key);
      char* value = cJSON_PrintUnformatted(c);
      printf("%s%s=%s (%s%s)", *any ? ", " : "model_settings: ", p, value,
             from ? "plugin " : "spec", from ? from->valuestring : "");
      *any = 1;
      free(value);
      free(key);
    }
    free(p);
  }
}

// Warns about each plugin that adds more than kLongText bytes to the prompt.
static void LongTextWarnings(const Spec* spec, Buffer* out) {
  for (int l = 0; l < spec->layer_count; l++) {
    const Layer* layer = &spec->layers[l];
    size_t n = layer->plugin ? TextBytes(spec, layer->instructions) : 0;
    if (n <= kLongText) continue;
    BufferPrintf(out,
                 "- plugin %s adds %zu bytes to the prompt; keep instructions "
                 "short and put long guides in a skill\n",
                 layer->plugin, n);
  }
}

// Prints the plugins in use, in order, if there are any.
static void PrintPlugins(Agent* a) {
  int any = 0;
  for (int l = 0; l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    if (!layer->plugin) continue;
    printf("%s%s", any ? " " : "plugins: ", layer->plugin);
    any = 1;
  }
  if (any) printf("\n");
}

// Warns when two layers' hooks at one point change the same field, and
// shows the order they run in (band, then list order).
static void OverlapWarnings(const Spec* spec, Buffer* out) {
  for (const char* const* p = kHookPoints; *p; p++) {
    cJSON* fields = cJSON_CreateObject();  // field -> ["a (band)", ...]
    for (int k = 0; k < 3 * spec->layer_count; k++) {
      const Layer* layer = &spec->layers[k % spec->layer_count];
      int band = HookBand(spec, layer, *p);
      char* path =
          band == k / spec->layer_count ? LayerFile(layer, "hooks", *p) : NULL;
      cJSON* changes =
          path ? JsonGet(HookOptions(spec, layer, *p), "changes") : NULL;
      cJSON* field;
      cJSON_ArrayForEach(field, changes) {
        if (!cJSON_IsString(field)) continue;
        cJSON* who =
            cJSON_GetObjectItemCaseSensitive(fields, field->valuestring);
        if (!who) who = cJSON_AddArrayToObject(fields, field->valuestring);
        char* label = LayerLabel(spec, layer);
        char* entry = XAsprintf("%s (%s)", label, kBandNames[band]);
        cJSON_AddItemToArray(who, cJSON_CreateString(entry));
        free(entry);
        free(label);
      }
      free(path);
    }
    cJSON* who;
    cJSON_ArrayForEach(who, fields) {
      if (cJSON_GetArraySize(who) < 2) continue;
      BufferPrintf(out, "- %s: %d hooks change %s; they run in this order:", *p,
                   cJSON_GetArraySize(who), who->string);
      cJSON* name;
      cJSON_ArrayForEach(name, who) {
        BufferPrintf(out, "%s %s", name == who->child ? "" : ",",
                     name->valuestring);
      }
      BufferAppendStr(out, "\n");
    }
    cJSON_Delete(fields);
  }
}

// True when `list` (an array of strings) has `name`.
static int Lists(cJSON* list, const char* name) {
  cJSON* c;
  cJSON_ArrayForEach(c, list) {
    if (cJSON_IsString(c) && !strcmp(c->valuestring, name)) return 1;
  }
  return 0;
}

// Warns when a plugin's tool hides a tool of a layer below it, unless the
// plugin declares it in `replaces:`.
static void HiddenWarnings(const Spec* spec, Buffer* out) {
  for (int i = 0; i < spec->layer_count; i++) {
    const Layer* layer = &spec->layers[i];
    if (!layer->plugin) continue;
    char* dir = PathJoin(layer->dir, "tools");
    char** names;
    int n = ListNames(dir, &names);
    for (int t = 0; t < n; t++) {
      char* mine = LayerFile(layer, "tools", names[t]);
      for (int j = i + 1; mine && j < spec->layer_count; j++) {
        char* other = LayerFile(&spec->layers[j], "tools", names[t]);
        if (other && !Lists(layer->replaces, names[t])) {
          char* label = LayerLabel(spec, &spec->layers[j]);
          BufferPrintf(out,
                       "- plugin %s hides the tool %s of %s; if that is on "
                       "purpose, add `replaces: [%s]` to its plugin.yaml\n",
                       layer->plugin, names[t], label, names[t]);
          free(label);
        }
        free(other);
      }
      free(mine);
      free(names[t]);
    }
    free(names);
    free(dir);
  }
}

// Prints the active list for `arx plugin list`: a "kit" line, then one
// tab-separated row per plugin: position (or -), name, state, why, folder.
static void PrintList(const Spec* spec) {
  if (spec->kit) printf("kit\t%s\t%s\n", spec->kit, spec->kit_from);
  int position = 0;
  cJSON* row;
  cJSON_ArrayForEach(row, spec->rows) {
    const char* state = JsonStr(row, "state", "");
    char at[16] = "-";
    if (!strcmp(state, "on")) snprintf(at, sizeof(at), "%d", ++position);
    printf("%s\t%s\t%s\t%s\t%s\n", at, JsonStr(row, "name", ""), state,
           JsonStr(row, "why", ""), JsonStr(row, "dir", ""));
  }
}

// The network hosts a run needs, each once: the endpoint's, then `hosts`
// from the spec and its plugins. A credential program may send calls
// elsewhere; its plugin lists those hosts.
static cJSON* Hosts(const Spec* spec) {
  cJSON* list = cJSON_CreateArray();
  Buffer endpoint = {0};
  AppendHost(&endpoint, JsonStr(spec->root, "endpoint.base_url", ""));
  if (endpoint.len) {
    cJSON_AddItemToArray(list, cJSON_CreateString(endpoint.data));
  }
  BufferFree(&endpoint);
  cJSON* h;
  cJSON_ArrayForEach(h, JsonGet(spec->root, "hosts")) {
    int have = !cJSON_IsString(h);
    cJSON* c;
    cJSON_ArrayForEach(c, list) have |= cJSON_Compare(c, h, 1);
    if (!have) cJSON_AddItemToArray(list, cJSON_Duplicate(h, 1));
  }
  return list;
}

// Prints the hosts, `separator` after each.
static void PrintHosts(const Spec* spec, const char* separator) {
  cJSON* hosts = Hosts(spec);
  cJSON* h;
  cJSON_ArrayForEach(h, hosts) printf("%s%s", h->valuestring, separator);
  cJSON_Delete(hosts);
}

// Prints the whole check report.
static void PrintCheck(Agent* a) {
  const Spec* spec = &a->spec;
  int merged = spec->config && strcmp(spec->config, spec->path);
  printf("ok: %s%s%s (model %s at %s)\n", spec->path, merged ? " + " : "",
         merged ? spec->config : "", JsonStr(spec->root, "model", ""),
         JsonStr(spec->root, "endpoint.base_url", ""));
  if (spec->kit) printf("kit: %s (from %s)\n", spec->kit, spec->kit_from);
  const char* programs[] = {"credential", "adapter"};
  for (int i = 0; i < 2; i++) {
    char* key = XAsprintf("endpoint.%s", programs[i]);
    const char* name = JsonStr(spec->root, key, NULL);
    if (name) printf("%s: %s\n", programs[i], name);
    free(key);
  }
  printf("hosts: ");
  PrintHosts(spec, " ");
  printf("\ntools:");
  for (int i = 0; i < a->tools.count; i++) {
    printf(" %s", a->tools.items[i].name);
  }
  PrintHooks(a);
  PrintPrompt(spec);
  int any = 0;
  PrintSettings(spec, JsonGet(spec->root, "model_settings"), "", &any);
  if (any) printf("\n");
  PrintPlugins(a);
  if (a->notes.len) printf("problems:\n%s", a->notes.data);
  Buffer warnings = {0};
  OverlapWarnings(spec, &warnings);
  HiddenWarnings(spec, &warnings);
  if (spec->warnings.len) BufferAppendStr(&warnings, spec->warnings.data);
  LongTextWarnings(spec, &warnings);
  if (warnings.len) printf("warnings:\n%s", warnings.data);
  BufferFree(&warnings);
}

// `arx check --plugin DIR`, `--kit-dir DIR` and `--climb FILE`: checks one
// folder or file without loading it, and prints it for scripts.
static int CheckFolder(const char* flag, const char* dir) {
  Buffer out = {0}, err = {0};
  int rc = !strcmp(flag, "--plugin")    ? PluginDescribe(dir, &out, &err)
           : !strcmp(flag, "--kit-dir") ? KitDescribe(dir, &out, &err)
                                        : ClimbDescribe(dir, &out, &err);
  fputs(rc ? err.data : out.data, rc ? stderr : stdout);
  BufferFree(&out);
  BufferFree(&err);
  return rc ? kExitUsage : kExitDone;
}

// Checks or lists the harness; see cli.h.
int CheckOrTools(int argc, char** argv, Agent* a) {
  int check = argv[1][0] == 'c', list = 0, hosts = 0;
  if (check && argc == 4 &&
      (!strcmp(argv[2], "--plugin") || !strcmp(argv[2], "--kit-dir") ||
       !strcmp(argv[2], "--climb"))) {
    return CheckFolder(argv[2], argv[3]);
  }
  if (check && argc > 2 && !strcmp(argv[argc - 1], "--list")) {
    list = 1;
    argc--;
  } else if (check && argc > 2 && !strcmp(argv[argc - 1], "--hosts")) {
    hosts = 1;
    argc--;
  }
  int code = ParseOptions(argc, argv, 2, a);
  if (code || (code = LoadSpec(a))) return code;
  ToolsBuild(a);
  if (!check) {
    cJSON* tools = ToolsJson(&a->tools);
    char* text = cJSON_Print(tools);
    puts(text);
    free(text);
    cJSON_Delete(tools);
  } else if (list) {
    PrintList(&a->spec);
  } else if (hosts) {
    PrintHosts(&a->spec, "\n");
  } else {
    PrintCheck(a);
  }
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  return kExitDone;
}
