// hooks.c: runs hook executables. A hook that fails is reported and then
// ignored (fail-open), unless the spec marks it fail: closed, so a broken
// hook the agent wrote cannot stop the harness.

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

// Runs the hook; see harness.h.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output) {
  *output = NULL;
  char* path = XAsprintf("%s/hooks/%s", a->spec.dir, point);
  if (access(path, X_OK)) {
    free(path);
    cJSON_Delete(input);
    return 0;
  }
  cJSON_AddStringToObject(input, "point", point);
  cJSON_AddStringToObject(input, "session", a->session.id);
  cJSON_AddNumberToObject(input, "turn", a->session.turns);
  char* text = cJSON_PrintUnformatted(input);
  cJSON_Delete(input);
  char key[64];
  snprintf(key, sizeof(key), "hooks.%s.timeout", point);
  Buffer out = {0}, err = {0};
  char** env = ToolEnv(a);
  char* argv[] = {path, NULL};
  Proc p = {.argv = argv,
            .in = text,
            .in_len = strlen(text),
            .timeout = JsonDuration(a->spec.root, key, 10),
            .env = env,
            .on_out = BufferSink,
            .out_ctx = &out,
            .on_err = BufferSink,
            .err_ctx = &err};
  ProcResult r;
  int rc = ProcRun(&p, &r);
  cJSON* event = EventNew("hook");
  cJSON_AddStringToObject(event, "point", point);
  cJSON_AddNumberToObject(event, "secs", r.secs);
  char* failure = FailureText(rc, &r, &err);
  int result = 1;
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
    result = -1;
  } else if (JsonStr(*output, "decision", NULL)) {
    cJSON_AddStringToObject(event, "decision",
                            JsonStr(*output, "decision", ""));
  }
  EventSend(event);
  free(failure);
  free(text);
  free(path);
  FreeEnv(env);
  BufferFree(&out);
  BufferFree(&err);
  return result;
}

// Reads hooks.<point>.fail.
int HookFailsClosed(struct Agent* a, const char* point) {
  char key[64];
  snprintf(key, sizeof(key), "hooks.%s.fail", point);
  return !strcmp(JsonStr(a->spec.root, key, "open"), "closed");
}
