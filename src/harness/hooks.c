// hooks.c: runs hook executables, one per layer for each point, in layer
// order: the spec folder's first, then each plugin's. A hook that fails is
// reported and then ignored (fail-open), unless its options mark it fail:
// closed, so a broken hook the agent wrote cannot stop the harness.

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

// The options for `point` in this layer: a plugin's come from its
// plugin.yaml, the others from the spec's hooks.<point>.
static cJSON* Options(struct Agent* a, const Layer* layer, const char* point) {
  if (layer->plugin) return JsonGet(layer->hooks, point);
  return cJSON_GetObjectItemCaseSensitive(JsonGet(a->spec.root, "hooks"),
                                          point);
}

// Runs one hook with `text` on stdin. Sets `*output` to its JSON object, or
// NULL. Returns 1 when it ran and -1 when it failed.
static int RunOne(struct Agent* a, const Layer* layer, const char* point,
                  char* path, const char* text, cJSON** output) {
  Buffer out = {0}, err = {0};
  char** env = ToolEnv(a, layer->plugin ? layer->dir : NULL);
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
  cJSON* event = EventNew("hook");
  cJSON_AddStringToObject(event, "point", point);
  if (layer->plugin) cJSON_AddStringToObject(event, "plugin", layer->plugin);
  cJSON_AddNumberToObject(event, "secs", r.secs);
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
    JsonAddTruncated(event, "error", failure, 300);
  } else if (JsonStr(*output, "decision", NULL)) {
    cJSON_AddStringToObject(event, "decision",
                            JsonStr(*output, "decision", ""));
  }
  EventSend(event);
  int result = failure ? -1 : 1;
  free(failure);
  FreeEnv(env);
  BufferFree(&out);
  BufferFree(&err);
  return result;
}

// Adds one hook's answer (consumed) to the combined `*output`. Returns 1
// when the answer decides, so the later hooks do not run.
static int Combine(const char* point, cJSON* answer, cJSON** output) {
  const char* key = !strcmp(point, "session_start") ? "context"
                    : !strcmp(point, "after_tool")  ? "note"
                                                    : NULL;
  const char* decision = JsonStr(answer, "decision", "");
  if (key) {
    const char* text = JsonStr(answer, key, NULL);
    const char* before = JsonStr(*output, key, NULL);
    if (text && before) {
      char* joined = XAsprintf("%s\n\n%s", before, text);
      cJSON_ReplaceItemInObjectCaseSensitive(*output, key,
                                             cJSON_CreateString(joined));
      free(joined);
    } else if (text) {
      cJSON_Delete(*output);
      *output = cJSON_CreateObject();
      cJSON_AddStringToObject(*output, key, text);
    }
  } else if (!strcmp(point, "before_tool") ? !strcmp(decision, "deny")
                                           : *decision != 0) {
    *output = answer;
    return 1;
  }
  cJSON_Delete(answer);
  return 0;
}

// Runs every layer's hook for `point`; see harness.h.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output) {
  *output = NULL;
  cJSON_AddStringToObject(input, "point", point);
  cJSON_AddStringToObject(input, "session", a->session.id);
  cJSON_AddNumberToObject(input, "turn", a->session.turns);
  char* text = cJSON_PrintUnformatted(input);
  cJSON_Delete(input);
  int result = 0;
  for (int l = 0; l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    char* path = XAsprintf("%s/hooks/%s", layer->dir, point);
    cJSON* answer = NULL;
    int rc =
        access(path, X_OK) ? 0 : RunOne(a, layer, point, path, text, &answer);
    free(path);
    if (rc < 0 &&
        !strcmp(JsonStr(Options(a, layer, point), "fail", "open"), "closed")) {
      result = -1;
      break;
    }
    if (rc) result = 1;
    if (answer && Combine(point, answer, output)) break;
  }
  free(text);
  return result;
}
