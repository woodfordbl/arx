// validate.c: validation against the field tables in fields.c, with line
// numbers and "did you mean" hints, so an agent editing its own spec can fix
// it from the message alone. agent.yaml, plugin.yaml and kit.yaml all go
// through the same checks.

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

static const char* const kStrategies[] = {"mask", "summarize", "hybrid",
                                          "restart", NULL};
static const char* const kTemplateVars[] = {
    "prompt", "harness", "skills", "date", "cwd", "session", "turn", NULL};
static const char* const kBands[] = {"policy", "normal", "final", NULL};

// Edit distance between two short strings, for "did you mean" hints.
static int EditDistance(const char* a, const char* b) {
  size_t n = strlen(a), m = strlen(b);
  int d[33][33];
  if (n > 32 || m > 32) return 99;
  for (size_t i = 0; i <= n; i++) d[i][0] = (int)i;
  for (size_t j = 0; j <= m; j++) d[0][j] = (int)j;
  for (size_t i = 1; i <= n; i++) {
    for (size_t j = 1; j <= m; j++) {
      int best = d[i - 1][j - 1] + (a[i - 1] != b[j - 1]);
      if (d[i - 1][j] + 1 < best) best = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < best) best = d[i][j - 1] + 1;
      d[i][j] = best;
    }
  }
  return d[n][m];
}

// Appends "file:line: path: message" for the key at `path`.
static void Problem(const Spec* spec, Buffer* err, const char* path,
                    const char* fmt, ...) {
  cJSON* line = cJSON_GetObjectItemCaseSensitive(spec->lines, path);
  if (cJSON_IsNumber(line)) {
    BufferPrintf(err, "%s:%d: %s: ", spec->path, line->valueint, path);
  } else if (cJSON_IsString(line)) {  // from the user's defaults
    BufferPrintf(err, "%s: %s: ", line->valuestring, path);
  } else {
    BufferPrintf(err, "%s: %s: ", spec->path, path);
  }
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(err, fmt, ap);
  va_end(ap);
  BufferAppendStr(err, "\n");
}

// True for a string or {file: path}.
static int IsText(const cJSON* v) {
  return cJSON_IsString(v) ||
         (cJSON_IsObject(v) && cJSON_GetArraySize(v) == 1 &&
          cJSON_IsString(cJSON_GetObjectItemCaseSensitive(v, "file")));
}

// True when `v` is an array whose items all pass `check`.
static int AllItems(const cJSON* v, int (*check)(const cJSON*)) {
  if (!cJSON_IsArray(v)) return 0;
  for (cJSON* c = v->child; c; c = c->next) {
    if (!check(c)) return 0;
  }
  return 1;
}

// True for one entry of a plugin list: a name, or {name: {settings}}.
static int IsPluginEntry(const cJSON* v) {
  if (cJSON_IsString(v)) return *v->valuestring != 0;
  return cJSON_IsObject(v) && cJSON_GetArraySize(v) == 1 &&
         (cJSON_IsObject(v->child) || cJSON_IsNull(v->child));
}

// True when `v` has the shape that `type` needs.
static int TypeOk(FieldType type, const cJSON* v) {
  double secs;
  size_t bytes;
  switch (type) {
    case kString:
      return cJSON_IsString(v);
    case kNumber:
      return cJSON_IsNumber(v);
    case kInteger:
      return cJSON_IsNumber(v) &&
             v->valuedouble == (double)(int64_t)v->valuedouble;
    case kBoolean:
      return cJSON_IsBool(v);
    case kDuration:
      return cJSON_IsNumber(v) ||
             (cJSON_IsString(v) && ParseDuration(v->valuestring, &secs) == 0);
    case kSize:
      return cJSON_IsNumber(v) ||
             (cJSON_IsString(v) && ParseSize(v->valuestring, &bytes) == 0);
    case kText:
      return IsText(v);
    case kTextList:
      return IsText(v) || AllItems(v, IsText);
    case kStringList:
      return AllItems(v, cJSON_IsString);
    case kPluginList:
      return AllItems(v, IsPluginEntry);
    default:
      return cJSON_IsObject(v);
  }
}

// Describes a type for error messages.
static const char* TypeName(FieldType type) {
  switch (type) {
    case kString:
      return "a string";
    case kNumber:
      return "a number";
    case kInteger:
      return "a whole number";
    case kBoolean:
      return "true or false";
    case kDuration:
      return "a duration (30, 10s, 5m, 1h)";
    case kSize:
      return "a size (2048, 2kb, 1mb)";
    case kText:
      return "text or {file: path}";
    case kTextList:
      return "text, {file: path} or a list of them";
    case kStringList:
      return "a list of strings";
    case kPluginList:
      return "a list of plugin names or {name: {settings}}";
    default:
      return "a mapping";
  }
}

// Reports an unknown key, suggesting the closest known one.
static void UnknownKey(const Spec* spec, Buffer* err, const char* path,
                       const char* key, const Field* fields) {
  const Field* best = NULL;
  int best_distance = 3;
  Buffer known = {0};
  for (const Field* f = fields; f->key; f++) {
    int d = EditDistance(key, f->key);
    if (d < best_distance) {
      best_distance = d;
      best = f;
    }
    BufferPrintf(&known, "%s%s", f == fields ? "" : ", ", f->key);
  }
  if (best) {
    Problem(spec, err, path, "unknown key (did you mean \"%s\"?)", best->key);
  } else {
    Problem(spec, err, path, "unknown key (known: %s)", known.data);
  }
  BufferFree(&known);
}

// Checks the entries of a kDict: each value is a mapping of `fields`.
static void ValidateDict(const Spec* spec, cJSON* dict, const Field* fields,
                         const char* path, Buffer* err);

// Checks every key of `node` against `fields`, recursing into mappings.
static void ValidateNode(const Spec* spec, cJSON* node, const Field* fields,
                         const char* path, Buffer* err) {
  for (cJSON* c = node->child; c; c = c->next) {
    char* child_path =
        *path ? XAsprintf("%s.%s", path, c->string) : XStrdup(c->string);
    const Field* f = fields;
    while (f->key && strcmp(f->key, c->string)) f++;
    if (!f->key) {
      UnknownKey(spec, err, child_path, c->string, fields);
    } else if (!TypeOk(f->type, c)) {
      Problem(spec, err, child_path, "must be %s", TypeName(f->type));
    } else if (f->type == kMap) {
      ValidateNode(spec, c, f->sub, child_path, err);
    } else if (f->type == kDict) {
      ValidateDict(spec, c, f->sub, child_path, err);
    }
    free(child_path);
  }
}

// Each entry is a mapping of options, or empty.
static void ValidateDict(const Spec* spec, cJSON* dict, const Field* fields,
                         const char* path, Buffer* err) {
  for (cJSON* e = dict->child; e; e = e->next) {
    char* entry = XAsprintf("%s.%s", path, e->string);
    if (cJSON_IsObject(e)) {
      ValidateNode(spec, e, fields, entry, err);
    } else if (!cJSON_IsNull(e)) {
      Problem(spec, err, entry, "must be a mapping of options (or empty)");
    }
    free(entry);
  }
}

// True when `s` is in the NULL-terminated list.
static int InList(const char* const* list, const char* s) {
  for (; *list; list++) {
    if (!strcmp(*list, s)) return 1;
  }
  return 0;
}

// Reports {{names}} in `text` that are not template variables.
static void CheckTemplate(const Spec* spec, const char* where, const char* text,
                          Buffer* err) {
  for (const char* p = text; (p = strstr(p, "{{"));) {
    const char* close = strstr(p + 2, "}}");
    if (!close) break;
    char* name = XStrndup(p + 2, (size_t)(close - p - 2));
    char* start = name + strspn(name, " ");
    char* end = start + strlen(start);
    while (end > start && end[-1] == ' ') *--end = 0;
    if (!InList(kTemplateVars, start) && strncmp(start, "file:", 5)) {
      Problem(spec, err, where,
              "unknown template variable {{%s}} (known: prompt, harness, "
              "skills, date, cwd, session, turn, file:PATH)",
              start);
    }
    free(name);
    p = close + 2;
  }
}

// Checks the names of hook points and tools.
static void ValidateNames(const Spec* spec, Buffer* err) {
  cJSON* c;
  cJSON_ArrayForEach(c, JsonGet(spec->root, "hooks")) {
    const char* band = JsonStr(c, "band", "normal");
    if (!InList(kBands, band)) {
      char* path = XAsprintf("hooks.%s.band", c->string);
      Problem(spec, err, path, "must be policy, normal or final");
      free(path);
    }
    if (InList(kHookPoints, c->string)) continue;
    char* path = XAsprintf("hooks.%s", c->string);
    Problem(spec, err, path,
            "unknown hook point (known: session_start, before_model, "
            "after_model, before_tool, after_tool, stop)");
    free(path);
  }
  cJSON_ArrayForEach(c, JsonGet(spec->root, "tools")) {
    size_t len = strlen(c->string);
    if (len && len <= 64 && strspn(c->string, kNameChars) == len) continue;
    char* path = XAsprintf("tools.%s", c->string);
    Problem(spec, err, path,
            "tool names use letters, digits, _ and - (64 max)");
    free(path);
  }
}

// Each entry of the map `key` (compactors, credentials, adapters) names an
// executable, relative to the spec.
static void ValidatePrograms(const Spec* spec, const char* key, Buffer* err) {
  cJSON* c;
  cJSON_ArrayForEach(c, JsonGet(spec->root, key)) {
    char* where = XAsprintf("%s.%s", key, c->string);
    char* path = cJSON_IsString(c) ? PathJoin(spec->dir, c->valuestring) : NULL;
    if (!path) {
      Problem(spec, err, where, "must be the path of an executable");
    } else if (!IsRunnable(path)) {
      Problem(spec, err, where, "%s is not executable", path);
    }
    free(path);
    free(where);
  }
}

// The program checks every spec and plugin.yaml gets.
static void ValidateAllPrograms(const Spec* spec, Buffer* err) {
  const char* maps[] = {"compactors", "credentials", "adapters"};
  for (int i = 0; i < 3; i++) ValidatePrograms(spec, maps[i], err);
}

// endpoint.<key> names an entry of <key>s, or an executable.
static void ValidateEndpointProgram(const Spec* spec, const char* key,
                                    Buffer* err) {
  char* where = XAsprintf("endpoint.%s", key);
  char* map = XAsprintf("%ss", key);
  const char* name = JsonStr(spec->root, where, NULL);
  cJSON* named = cJSON_GetObjectItemCaseSensitive(JsonGet(spec->root, map),
                                                  name ? name : "");
  char* path = name && !named ? PathJoin(spec->dir, name) : NULL;
  if (path && !IsRunnable(path)) {
    Problem(spec, err, where, "not a name in %s, and %s is not executable", map,
            path);
  }
  free(path);
  free(map);
  free(where);
}

// Host names are bare: no scheme, port or path.
static void ValidateHosts(const Spec* spec, Buffer* err) {
  cJSON* c;
  cJSON_ArrayForEach(c, JsonGet(spec->root, "hosts")) {
    const char* host = c->valuestring;
    size_t len = strlen(host);
    if (len && strspn(host, "abcdefghijklmnopqrstuvwxyz0123456789.-*") == len) {
      continue;
    }
    Problem(spec, err, "hosts",
            "\"%s\" is not a host name such as api.openai.com (lower case, "
            "no scheme, port or path)",
            host);
  }
}

// Rules the table cannot express: required keys, ranges and templates.
static void ValidateRules(const Spec* spec, Buffer* err) {
  cJSON* root = spec->root;
  if (!JsonStr(root, "model", NULL)) Problem(spec, err, "model", "required");
  if (!JsonStr(root, "endpoint.base_url", NULL) &&
      !JsonStr(root, "endpoint.credential", NULL)) {
    Problem(spec, err, "endpoint.base_url", "required");
  }
  ValidateAllPrograms(spec, err);
  ValidateEndpointProgram(spec, "credential", err);
  ValidateEndpointProgram(spec, "adapter", err);
  ValidateHosts(spec, err);
  const char* strategy = JsonStr(root, "compaction.strategy", NULL);
  cJSON* named = cJSON_GetObjectItemCaseSensitive(JsonGet(root, "compactors"),
                                                  strategy ? strategy : "");
  if (strategy && !named && !InList(kStrategies, strategy)) {
    char* path = PathJoin(spec->dir, strategy);
    if (!IsRunnable(path)) {
      Problem(spec, err, "compaction.strategy",
              "not a built-in strategy, and %s is not executable", path);
    }
    free(path);
  }
  double trigger = JsonNum(root, "compaction.trigger", 0.7);
  if (trigger <= 0 || trigger > 1) {
    Problem(spec, err, "compaction.trigger", "must be between 0 and 1");
  }
  const char* texts[] = {"instructions", "first_message", "compaction.prompt"};
  for (size_t i = 0; i < sizeof(texts) / sizeof(texts[0]); i++) {
    char* text = SpecText(spec, JsonGet(root, texts[i]), err);
    if (text) CheckTemplate(spec, texts[i], text, err);
    free(text);
  }
}

// Validates the whole spec; see harness.h.
void SpecValidate(const Spec* spec, Buffer* err) {
  if (!cJSON_IsObject(spec->root)) {
    BufferPrintf(err, "%s: the spec must be a YAML mapping\n", spec->path);
    return;
  }
  ValidateNode(spec, spec->root, kTopFields, "", err);
  ValidateNames(spec, err);
  ValidateRules(spec, err);
}

// Checks that a plugin or kit names itself with letters, digits, _ and -.
static void ValidateOwnName(const Spec* spec, Buffer* err) {
  const char* name = JsonStr(spec->root, "name", "x");
  if (!*name || strspn(name, kNameChars) != strlen(name)) {
    Problem(spec, err, "name", "use letters, digits, _ and -");
  }
}

// Validates a plugin.yaml; see harness.h.
void PluginValidate(const Spec* plugin, Buffer* err) {
  if (!cJSON_IsObject(plugin->root)) {
    BufferPrintf(err, "%s: plugin.yaml must be a YAML mapping\n", plugin->path);
    return;
  }
  ValidateNode(plugin, plugin->root, kPluginFields, "", err);
  ValidateNames(plugin, err);
  ValidateAllPrograms(plugin, err);
  ValidateHosts(plugin, err);
  ValidateOwnName(plugin, err);
}

// Validates a kit.yaml; see harness.h.
void KitValidate(const Spec* kit, Buffer* err) {
  if (!cJSON_IsObject(kit->root)) {
    BufferPrintf(err, "%s: kit.yaml must be a YAML mapping\n", kit->path);
    return;
  }
  ValidateNode(kit, kit->root, kKitFields, "", err);
  ValidateOwnName(kit, err);
  if (!JsonStr(kit->root, "extends", NULL) &&
      !cJSON_IsArray(JsonGet(kit->root, "plugins"))) {
    Problem(kit, err, "plugins", "required (or extends)");
  }
}
