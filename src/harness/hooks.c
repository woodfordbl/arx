// hooks.c: runs hook executables, one per layer for each point, by band
// (policy, normal, final) and then in layer order: the spec folder's first,
// then each plugin's in the order of the active list. This file runs one
// hook (HookRunOne), reads hook options and bands, and runs the decision
// points session_start and stop; chain.c runs the points around the model
// and tool calls. A hook that fails is reported and then ignored
// (fail-open), unless its options mark it fail: closed, so a broken hook
// the agent wrote cannot stop the harness.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

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

// Runs one hook with `text` on stdin; see harness.h.
int HookRunOne(struct Agent* a, const Layer* layer, const char* point,
               const char* path, const char* text, cJSON** output,
               cJSON** event) {
  Buffer out = {0}, err = {0};
  char** env = PluginEnv(a, layer);
  char* argv[] = {(char*)path, NULL};
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
  if (layer->policy) cJSON_AddTrueToObject(*event, "policy");
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

// The path of a layer's hook; see harness.h.
char* HookPath(const Layer* layer, const char* point) {
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
  if (!strcmp(point, "harness_edit")) {  // only the gate runs this point
    cJSON_Delete(input);
    return 0;
  }
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
    int rc = HookRunOne(a, layer, point, path, text, &answer, &event);
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
