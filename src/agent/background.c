// background.c: calls that do not block. A scheduler plugin moves a call to
// the background with {"detach"}: the model gets the placeholder result
// "started as c7 ..." at once and works on, and the call stays in the
// session's call table. When it ends, arx appends its real result to the
// session inbox as a `result` line, which reaches the agent as a [harness]
// note before its next model call. The inbox is a file, so --resume, a
// driver and a front-end can read the results too. The policy (which calls,
// how many at once) is the plugin's; arx only runs, tracks and delivers.

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// The preview in a result line is cut to this, so a note stays short.
static const size_t kPreviewMax = 60;

// The entry of background call `short_id` in the session's `calls` (the
// calls whose result the agent has not seen), or NULL.
static cJSON* Entry(Agent* a, const char* short_id) {
  cJSON* e;
  cJSON_ArrayForEach(e, a->session.calls) {
    if (!strcmp(JsonStr(e, "call", ""), short_id)) return e;
  }
  return NULL;
}

// Finds a call by either id; see agent.h.
Call* CallFind(Agent* a, const char* id) {
  for (int i = 0; i < a->call_count; i++) {
    Call* c = a->calls[i];
    if (!strcmp(c->id, id) || (c->short_id && !strcmp(c->short_id, id))) {
      return c;
    }
  }
  return NULL;
}

// Queues the result line `r` as one paragraph of the agent's next note,
// and takes the call out of the session's `calls`: the agent has seen it.
static void Note(Agent* a, cJSON* r) {
  const char* status = JsonStr(r, "status", "ok");
  const char* how = !strcmp(status, "ok")          ? "finished"
                    : !strcmp(status, "cancelled") ? "was cancelled"
                    : !strcmp(status, "stopped")   ? "was stopped"
                                                   : "failed";
  const char* call = JsonStr(r, "call", "");
  AgentNote(a, "%s (%s: %s) %s after %.0fs:\n%s", call, JsonStr(r, "name", ""),
            JsonStr(r, "preview", ""), how, JsonNum(r, "secs", 0),
            JsonStr(r, "text", ""));
  cJSON* e = Entry(a, call);
  if (e) cJSON_Delete(cJSON_DetachItemViaPointer(a->session.calls, e));
}

// The result a background call's slot in the reply gets.
static char* Placeholder(Agent* a, const Call* c) {
  Tool* t = ToolFind(a, JsonStr(c->call, "name", ""));
  int shows_output = c->out_path && !(t && t->kind == kToolAgent);
  char* output =
      shows_output ? XAsprintf("\nOutput so far: %s", c->out_path) : NULL;
  char* text = XAsprintf(
      "%s as %s in the background. Its result comes later in a [harness] "
      "note.%s",
      c->state == kQueued ? "queued" : "started", c->short_id,
      output ? output : "");
  free(output);
  return text;
}

// Moves a call to the background; see agent.h.
void CallDetach(Agent* a, Call* c) {
  if (!c || c->short_id || c->state == kDone) return;
  c->short_id = XAsprintf("c%d", ++a->session.call_seq);
  c->detached_at = Now();
  c->placeholder = Placeholder(a, c);
  // "*" would make every later call wait for this one. The model was told
  // that it runs on, so only the named keys still hold.
  cJSON* keys = cJSON_GetObjectItem(c->call, "keys");
  for (int i = cJSON_GetArraySize(keys) - 1; i >= 0; i--) {
    const char* key = cJSON_GetStringValue(cJSON_GetArrayItem(keys, i));
    if (key && !strcmp(key, "*")) cJSON_DeleteItemFromArray(keys, i);
  }
  const char* name = JsonStr(c->call, "name", "");
  char* preview = CallPreview(c->args);
  if (!a->session.calls) a->session.calls = cJSON_CreateArray();
  cJSON* entry = cJSON_CreateObject();
  cJSON_AddStringToObject(entry, "call", c->short_id);
  cJSON_AddStringToObject(entry, "id", c->id);
  cJSON_AddStringToObject(entry, "name", name);
  JsonAddTruncated(entry, "preview", preview, kPreviewMax);
  cJSON_AddNumberToObject(entry, "at", (double)time(NULL));
  cJSON_AddItemToArray(a->session.calls, entry);
  free(preview);
  cJSON_AddStringToObject(c->end, "call", c->short_id);
  cJSON_AddTrueToObject(c->end, "detached");
  cJSON* e = EventNew("tool.detach");
  cJSON_AddStringToObject(e, "id", c->id);
  cJSON_AddStringToObject(e, "name", name);
  cJSON_AddStringToObject(e, "call", c->short_id);
  cJSON_AddBoolToObject(e, "queued", c->state == kQueued);
  EventSend(e);
  CallRuns(a, c);
}

// A background call's process runs: keeps it for the session, so every
// ProcPoll round serves its pipes, and records where its output goes.
void CallRuns(Agent* a, Call* c) {
  if (!c->short_id || !c->run) return;
  ToolQuiet(c->run);
  ProcKeep(ToolChild(c->run));
  cJSON* e = Entry(a, c->short_id);
  if (e && c->out_path && !cJSON_GetObjectItem(e, "out")) {
    cJSON_AddStringToObject(e, "out", c->out_path);
  }
}

// Cancels a call; see agent.h.
void CallCancel(Agent* a, const char* id) {
  Call* c = CallFind(a, id);
  if (!c || c->state == kDone || c->status) return;
  c->status = "cancelled";
  if (c->state == kRunning) {
    c->stop_line = "[cancelled]";
    ProcStop(ToolChild(c->run));
  } else {
    SchedDone(c->id, 0, 1, NULL, 0);
    CallEndWithout(a, c, XStrdup("[cancelled before it started]"), 1);
  }
}

// Delivers a background call that ended; see agent.h.
void CallEnded(Agent* a, Call* c, double secs) {
  if (!c->short_id) return;
  const char* status = c->status                      ? c->status
                       : g_interrupted && c->is_error ? "stopped"
                       : c->is_error                  ? "error"
                                                      : "ok";
  char* preview = CallPreview(c->args);
  cJSON* r = cJSON_CreateObject();
  cJSON_AddStringToObject(r, "cmd", "result");
  cJSON_AddStringToObject(r, "call", c->short_id);
  cJSON_AddStringToObject(r, "id", c->id);
  cJSON_AddStringToObject(r, "name", JsonStr(c->call, "name", ""));
  JsonAddTruncated(r, "preview", preview, kPreviewMax);
  cJSON_AddStringToObject(r, "status", status);
  cJSON_AddNumberToObject(r, "secs", secs < 0 ? Now() - c->detached_at : secs);
  cJSON_AddStringToObject(r, "text", c->text);
  free(preview);
  char* line = cJSON_PrintUnformatted(r);
  char* text = XAsprintf("%s\n", line);
  char* path = XAsprintf("%s/inbox", a->session.dir);
  if (AppendFile(path, text, strlen(text))) {
    // Without the file the result still reaches the agent, from memory.
    cJSON* e = EventNew("error");
    char* why = XAsprintf(
        "cannot append to %s; the result of %s goes to the "
        "agent's notes",
        path, c->short_id);
    cJSON_AddStringToObject(e, "error", why);
    EventSend(e);
    free(why);
    Note(a, r);
  }
  free(path);
  free(text);
  free(line);
  cJSON_Delete(r);
}

// The calls whose result the agent has not seen; see agent.h.
int CallsInFlight(Agent* a) { return cJSON_GetArraySize(a->session.calls); }

// Stops every call in the table; see agent.h.
void CallsShutdown(Agent* a) {
  for (int i = 0; i < a->call_count; i++) {
    Call* c = a->calls[i];
    if (c->state == kDone || c->status) continue;
    c->status = "stopped";
    if (c->state == kRunning) {
      c->stop_line = "[stopped: the session ended]";
      ProcStop(ToolChild(c->run));
    } else {
      SchedDone(c->id, 0, 1, NULL, 0);
      CallEndWithout(
          a, c, XStrdup("[stopped before it started: the session ended]"), 1);
    }
  }
  while (CallsPoll(a, 0.1)) continue;
}

// Frees a call that left the table.
static void Free(Call* c) {
  free(c->id);
  free(c->args);
  free(c->text);
  free(c->out_path);
  free(c->short_id);
  free(c->placeholder);
  cJSON_Delete(c->call);
  cJSON_Delete(c->model_call);
  cJSON_Delete(c->end);
  free(c);
}

// Frees the calls that are done and delivered; see agent.h.
void CallsSweep(Agent* a) {
  int kept = 0;
  for (int i = 0; i < a->call_count; i++) {
    Call* c = a->calls[i];
    if (c->state == kDone && c->placed) {
      Free(c);
    } else {
      a->calls[kept++] = c;
    }
  }
  a->call_count = kept;
}
