// hooks.c: runs hook executables, one per layer for each point, by band
// (policy, normal, final) and then in layer order: the spec folder's first,
// then each plugin's in the order of the active list. At the points around
// the model and tool calls the hooks form a chain over one raw object: each
// hook gets the object as the hook before it left it, and prints the fields
// it changes. A hook that fails is reported and then ignored (fail-open),
// unless its options mark it fail: closed, so a broken hook the agent wrote
// cannot stop the harness.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// The fields a hook may print at each raw-object point.
typedef struct RawPoint {
  const char* point;
  const char* fields[5];
} RawPoint;

static const RawPoint kRawPoints[] = {
    {"before_model", {"messages", "tools", "model", "settings", NULL}},
    {"after_model", {"reply", NULL}},
    {"before_tool", {"name", "args", "keys", "result", NULL}},
    {"after_tool", {"result", "backoff", NULL}},
};

// Describes why a hook failed, or returns NULL if it did not.
static char* FailureText(int rc, const ProcResult* r, const Buffer* err) {
  if (rc) return XStrdup("could not start the hook");
  if (r->timed_out) return XStrdup("timed out");
  if (r->code) {
    return XAsprintf("exit %d: %s", r->code, err->data ? err->data : "");
  }
  return NULL;
}

// The bands, in the order they run.
static const char* const kBandNames[] = {"policy", "normal", "final"};

// The options of a layer's hook; see harness.h.
cJSON* HookOptions(const Spec* spec, const Layer* layer, const char* point) {
  if (layer->plugin) return JsonGet(layer->hooks, point);
  return cJSON_GetObjectItemCaseSensitive(JsonGet(spec->root, "hooks"), point);
}

// The band of a layer's hook; see harness.h.
int HookBand(const Spec* spec, const Layer* layer, const char* point) {
  const char* band = JsonStr(HookOptions(spec, layer, point), "band", "");
  for (int b = 0; b < 3; b++) {
    if (!strcmp(band, kBandNames[b])) return b;
  }
  return 1;
}

// The options for `point` in this layer.
static cJSON* Options(struct Agent* a, const Layer* layer, const char* point) {
  return HookOptions(&a->spec, layer, point);
}

// True when this layer's failed hook for `point` should stop the chain.
static int FailsClosed(struct Agent* a, const Layer* layer, const char* point) {
  return !strcmp(JsonStr(Options(a, layer, point), "fail", "open"), "closed");
}

// The environment for a hook: ToolEnv, plus ARX_PLUGIN_SETTINGS (the
// plugin's settings from the active list, as JSON) for a plugin's hook.
static char** HookEnv(struct Agent* a, const Layer* layer) {
  char** env = ToolEnv(a, layer->plugin ? layer->dir : NULL, layer->plugin);
  if (!layer->plugin) return env;
  int n = 0;
  while (env[n]) n++;
  env = XRealloc(env, (size_t)(n + 2) * sizeof(*env));
  char* json =
      layer->settings ? cJSON_PrintUnformatted(layer->settings) : XStrdup("{}");
  env[n] = XAsprintf("ARX_PLUGIN_SETTINGS=%s", json);
  env[n + 1] = NULL;
  free(json);
  return env;
}

// Runs one hook with `text` on stdin. Sets `*output` to its JSON object, or
// NULL, and `*event` to its hook event, not yet sent. Returns 1 when it ran
// and -1 when it failed.
static int RunOne(struct Agent* a, const Layer* layer, const char* point,
                  char* path, const char* text, cJSON** output, cJSON** event) {
  Buffer out = {0}, err = {0};
  char** env = HookEnv(a, layer);
  char* argv[] = {path, NULL};
  Proc p = {.argv = argv,
            .in = text,
            .in_len = strlen(text),
            .timeout = JsonDuration(Options(a, layer, point), "timeout", 10),
            .env = env,
            .on_out = BufferSink,
            .out_ctx = &out,
            .on_err = BufferSink,
            .err_ctx = &err};
  ProcResult r;
  int rc = ProcRun(&p, &r);
  *event = EventNew("hook");
  cJSON_AddStringToObject(*event, "point", point);
  if (layer->plugin) cJSON_AddStringToObject(*event, "plugin", layer->plugin);
  if (HookBand(&a->spec, layer, point) != 1) {
    cJSON_AddStringToObject(*event, "band",
                            kBandNames[HookBand(&a->spec, layer, point)]);
  }
  cJSON_AddNumberToObject(*event, "secs", r.secs);
  char* failure = FailureText(rc, &r, &err);
  *output = NULL;
  if (!failure && out.len && strspn(out.data, " \t\r\n") < out.len) {
    *output = cJSON_Parse(out.data);
    if (!cJSON_IsObject(*output)) {
      cJSON_Delete(*output);
      *output = NULL;
      failure = XStrdup("stdout is not a JSON object");
    }
  }
  if (failure) {
    JsonAddTruncated(*event, "error", failure, 300);
  } else if (JsonStr(*output, "decision", NULL)) {
    cJSON_AddStringToObject(*event, "decision",
                            JsonStr(*output, "decision", ""));
  }
  int result = failure ? -1 : 1;
  free(failure);
  FreeEnv(env);
  BufferFree(&out);
  BufferFree(&err);
  return result;
}

// The path of this layer's hook for `point` (malloc'd), or NULL if it has
// none.
static char* HookPath(const Layer* layer, const char* point) {
  char* path = XAsprintf("%s/hooks/%s", layer->dir, point);
  if (IsRunnable(path)) return path;
  free(path);
  return NULL;
}

// True when any layer has a hook for `point`; see harness.h.
int HookExists(struct Agent* a, const char* point) {
  for (int l = 0; l < a->spec.layer_count; l++) {
    char* path = HookPath(&a->spec.layers[l], point);
    int found = path != NULL;
    free(path);
    if (found) return 1;
  }
  return 0;
}

// Adds one hook's answer (consumed) to the combined `*output`. Returns 1
// when the answer decides, so the later hooks do not run.
static int Combine(const char* point, cJSON* answer, cJSON** output) {
  if (strcmp(point, "session_start")) {
    if (!*JsonStr(answer, "decision", "")) {
      cJSON_Delete(answer);
      return 0;
    }
    *output = answer;  // the first decision wins
    return 1;
  }
  const char* text = JsonStr(answer, "context", NULL);
  const char* before = JsonStr(*output, "context", NULL);
  if (text && before) {
    char* joined = XAsprintf("%s\n\n%s", before, text);
    cJSON_ReplaceItemInObjectCaseSensitive(*output, "context",
                                           cJSON_CreateString(joined));
    free(joined);
  } else if (text) {
    cJSON_Delete(*output);
    *output = cJSON_CreateObject();
    cJSON_AddStringToObject(*output, "context", text);
  }
  cJSON_Delete(answer);
  return 0;
}

// Runs every layer's hook for a decision point; see harness.h.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output) {
  *output = NULL;
  cJSON_AddStringToObject(input, "point", point);
  cJSON_AddStringToObject(input, "session", a->session.id);
  cJSON_AddNumberToObject(input, "turn", a->session.turns);
  char* text = cJSON_PrintUnformatted(input);
  cJSON_Delete(input);
  int result = 0;
  for (int k = 0; k < 3 * a->spec.layer_count && result >= 0; k++) {
    const Layer* layer = &a->spec.layers[k % a->spec.layer_count];
    char* path = HookBand(&a->spec, layer, point) == k / a->spec.layer_count
                     ? HookPath(layer, point)
                     : NULL;
    if (!path) continue;
    cJSON *answer = NULL, *event = NULL;
    int rc = RunOne(a, layer, point, path, text, &answer, &event);
    EventSend(event);
    free(path);
    if (rc < 0 && FailsClosed(a, layer, point)) {
      result = -1;
      break;
    }
    result = 1;
    if (answer && Combine(point, answer, output)) break;
  }
  free(text);
  return result;
}

// The fields a hook may print at `point`, or NULL for a decision point.
static const char* const* FieldsOf(const char* point) {
  for (size_t i = 0; i < sizeof(kRawPoints) / sizeof(kRawPoints[0]); i++) {
    if (!strcmp(kRawPoints[i].point, point)) return kRawPoints[i].fields;
  }
  return NULL;
}

// True when `value` has the right type for the field `key`.
static int FieldOk(const char* key, cJSON* value) {
  if (!strcmp(key, "messages")) {
    if (!cJSON_IsArray(value)) return 0;
    cJSON* m;
    cJSON_ArrayForEach(m, value) {
      if (!JsonStr(m, "role", NULL)) return 0;
    }
    return 1;
  }
  if (!strcmp(key, "tools")) return cJSON_IsArray(value);
  if (!strcmp(key, "settings")) return cJSON_IsObject(value);
  if (!strcmp(key, "keys")) return KeysValid(value);
  if (!strcmp(key, "backoff")) return cJSON_IsObject(value);
  if (!strcmp(key, "reply")) return JsonStr(value, "role", NULL) != NULL;
  if (!strcmp(key, "args")) {
    return cJSON_IsObject(value) || cJSON_IsString(value);
  }
  return cJSON_IsString(value) && (strcmp(key, "name") || *value->valuestring);
}

// Turns the outputs hooks printed before the raw objects into fields:
// before_tool's {"decision": "deny", "reason"} becomes the result
// "denied: <reason>", and after_tool's {"note"} is appended to the result.
// Returns 1 for a denial.
static int Legacy(const char* point, cJSON* object, cJSON* answer) {
  if (!strcmp(point, "before_tool") &&
      !strcmp(JsonStr(answer, "decision", ""), "deny") &&
      !cJSON_GetObjectItem(answer, "result")) {
    char* text =
        XAsprintf("denied: %s", JsonStr(answer, "reason", "no reason given"));
    cJSON_AddStringToObject(answer, "result", text);
    free(text);
    return 1;
  }
  const char* note = JsonStr(answer, "note", NULL);
  if (!strcmp(point, "after_tool") && note) {
    const char* base = JsonStr(answer, "result", JsonStr(object, "result", ""));
    char* text = XAsprintf("%s\n[after_tool] %s", base, note);
    cJSON_DeleteItemFromObjectCaseSensitive(answer, "result");
    cJSON_AddStringToObject(answer, "result", text);
    free(text);
  }
  return 0;
}

// Copies the allowed fields of `answer` that differ into `object`, and
// lists their names in `changed`. Returns -1 and the bad field's name in
// `*bad` when a field has the wrong type; then nothing is copied.
static int Merge(const char* const* fields, cJSON* object, cJSON* answer,
                 cJSON* changed, const char** bad) {
  for (const char* const* f = fields; *f; f++) {
    cJSON* value = cJSON_GetObjectItemCaseSensitive(answer, *f);
    if (value && !FieldOk(*f, value)) {
      *bad = *f;
      return -1;
    }
  }
  for (const char* const* f = fields; *f; f++) {
    cJSON* value = cJSON_DetachItemFromObjectCaseSensitive(answer, *f);
    if (!value) continue;
    cJSON* old = cJSON_GetObjectItemCaseSensitive(object, *f);
    if (old && cJSON_Compare(old, value, 1)) {
      cJSON_Delete(value);
      continue;
    }
    if (old) {
      cJSON_ReplaceItemViaPointer(object, old, value);
    } else {
      cJSON_AddItemToObject(object, *f, value);
    }
    cJSON_AddItemToArray(changed, cJSON_CreateString(*f));
  }
  return 0;
}

// Adds the names in `from` that `to` lacks.
static void AddNames(cJSON* to, cJSON* from) {
  cJSON* name;
  cJSON_ArrayForEach(name, from) {
    int found = 0;
    cJSON* have;
    cJSON_ArrayForEach(have, to) {
      if (!strcmp(have->valuestring, name->valuestring)) found = 1;
    }
    if (!found) cJSON_AddItemToArray(to, cJSON_CreateString(name->valuestring));
  }
}

// Applies one hook's answer (consumed) to `object`. Adds what it changed to
// `event` and `changed`. Returns -1 when the answer is bad, 2 when it ends
// the chain (a before_tool result), else 0.
static int Apply(const char* point, cJSON* object, cJSON* answer, cJSON* event,
                 cJSON* changed) {
  int denied = Legacy(point, object, answer);
  cJSON* mine = cJSON_CreateArray();
  const char* bad = NULL;
  int rc = Merge(FieldsOf(point), object, answer, mine, &bad);
  if (rc < 0) {
    char* text = XAsprintf("printed a bad \"%s\"", bad);
    cJSON_AddStringToObject(event, "error", text);
    free(text);
  } else {
    if (denied) cJSON_AddTrueToObject(object, "is_error");
    if (cJSON_GetArraySize(mine)) {
      if (changed) AddNames(changed, mine);
      cJSON_AddItemToObject(event, "changed", mine);
      mine = NULL;
    }
    if (!strcmp(point, "before_tool") && cJSON_GetObjectItem(object, "result"))
      rc = 2;
  }
  cJSON_Delete(mine);
  cJSON_Delete(answer);
  return rc;
}

// True when the hook event lists `field` under "changed".
static int Changed(cJSON* event, const char* field) {
  cJSON* name;
  cJSON_ArrayForEach(name, JsonGet(event, "changed")) {
    if (!strcmp(name->valuestring, field)) return 1;
  }
  return 0;
}

// A result that a policy hook set is final: drops a later hook's change to
// it (a result, a note or a denial), and says so in its event.
static void KeepResult(cJSON* answer, cJSON* event) {
  const char* keys[] = {"result", "note", "decision"};
  int dropped = 0;
  for (int k = 0; k < 3; k++) {
    if (!cJSON_GetObjectItemCaseSensitive(answer, keys[k])) continue;
    cJSON_DeleteItemFromObjectCaseSensitive(answer, keys[k]);
    dropped = 1;
  }
  if (dropped) {
    cJSON_AddStringToObject(event, "ignored",
                            "result: a policy hook set it, so it is final");
  }
}

// Runs every layer's hook for a raw-object point as a chain; see harness.h.
int HookChain(struct Agent* a, const char* point, cJSON* object,
              cJSON* changed) {
  int result = 0, final_result = 0, n = a->spec.layer_count;
  for (int k = 0; k < 3 * n; k++) {
    const Layer* layer = &a->spec.layers[k % n];
    int band = HookBand(&a->spec, layer, point);
    char* path = band == k / n ? HookPath(layer, point) : NULL;
    if (!path) continue;
    cJSON_AddStringToObject(object, "point", point);
    cJSON_AddStringToObject(object, "session", a->session.id);
    cJSON_AddNumberToObject(object, "turn", a->session.turns);
    char* text = cJSON_PrintUnformatted(object);
    cJSON_DeleteItemFromObjectCaseSensitive(object, "point");
    cJSON_DeleteItemFromObjectCaseSensitive(object, "session");
    cJSON_DeleteItemFromObjectCaseSensitive(object, "turn");
    cJSON *answer = NULL, *event = NULL;
    int rc = RunOne(a, layer, point, path, text, &answer, &event);
    if (answer && final_result) KeepResult(answer, event);
    if (answer) rc = Apply(point, object, answer, event, changed);
    if (band == 0 && Changed(event, "result")) final_result = 1;
    EventSend(event);
    free(text);
    free(path);
    if (rc < 0 && FailsClosed(a, layer, point)) return -1;
    result = 1;
    if (rc == 2) break;
  }
  return result;
}
