// chain.c: the hooks around the model and tool calls. At these points the
// hooks form a chain over one raw object: each hook gets the object as the
// hook before it left it, plus point, session and turn, and prints the
// fields it changes, which replace those of the object before the next:
//   before_model  {messages, tools, model, settings, reason}
//                 prints any of messages, tools, model, settings
//   after_model   {reply, usage, finish}; prints reply
//   before_tool   {id, name, args}; prints name, args or keys, or result to
//                 skip the tool, which ends the chain. {"decision": "deny",
//                 "reason"} becomes the result "denied: <reason>" and adds
//                 "is_error": true to the object.
//   after_tool    {call, result, is_error}; prints result or backoff.
//                 {"note"} is appended to the result.
// A `result` that a policy hook sets is final: later hooks cannot change
// it, and their events say "ignored". A field of the wrong type is a
// failure. Each hook event lists the changed fields under "changed".

#include <stdlib.h>
#include <string.h>

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

// True when this layer's failed hook for `point` should stop the chain.
static int FailsClosed(struct Agent* a, const Layer* layer, const char* point) {
  cJSON* options = HookOptions(&a->spec, layer, point);
  return !strcmp(JsonStr(options, "fail", "open"), "closed");
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
    int rc = HookRunOne(a, layer, point, path, text, &answer, &event);
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
