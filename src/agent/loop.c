// loop.c: the turn loop. Before each model call it hot-reloads the harness
// if any of its files changed, reads the inbox, hands harness notes to the
// agent and compacts the context. Then it calls the model (model_call.c),
// runs the tool calls (tool_calls.c), and asks the stop hook whether to go
// on when the agent stops calling tools.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"
#include "src/io/io.h"

// Returns kExitCap when a cap or limit is reached, else -1.
static int CheckCaps(Agent* a) {
  int64_t max_turns = (int64_t)JsonNum(a->spec.root, "limits.max_turns", 200);
  if (a->caps.turns >= 0 && a->caps.turns < max_turns) {
    max_turns = a->caps.turns;
  }
  double tokens = (double)(a->session.tokens_in + a->session.tokens_out);
  const char* which = NULL;
  if (a->session.turns >= max_turns) {
    which = "turns";
  } else if (a->caps.tokens >= 0 && tokens >= a->caps.tokens) {
    which = "tokens";
  } else if (a->caps.usd >= 0 && a->session.cost >= a->caps.usd) {
    which = "usd";
  } else if (a->caps.wall >= 0 && Now() - a->start >= a->caps.wall) {
    which = "wall";
  }
  if (!which) return -1;
  cJSON* e = EventNew("note");
  char* text = XAsprintf("stopped: the %s limit was reached", which);
  cJSON_AddStringToObject(e, "text", text);
  EventSend(e);
  free(text);
  return kExitCap;
}

// Returns kExitPolicy, with a note, when the policy stopped the run; else -1.
static int PolicyStop(Agent* a) {
  if (!GateStopped(a)) return -1;
  cJSON* e = EventNew("note");
  char* text = XAsprintf("stopped by the policy: %s", GateStopped(a));
  cJSON_AddStringToObject(e, "text", text);
  EventSend(e);
  free(text);
  return kExitPolicy;
}

// Reloads the spec, tools and prompt when any harness file changed. A bad
// edit keeps the previous version and tells the agent why. With a policy
// folder, the gate judges the changes first (GateReload) and may revert
// some or stop the run. Returns -1 to go on, or kExitPolicy.
static int MaybeReload(Agent* a) {
  uint64_t sig = a->gate ? 0 : SpecSignature(&a->spec);
  if (a->gate ? !GateDirty(a) : sig == a->spec.sig) return -1;
  double start = Now();
  int rejected = 0;
  if (a->gate && GateReload(a, &rejected) >= 0) return PolicyStop(a);
  Spec fresh;
  Buffer err = {0};
  cJSON* e = EventNew("harness.reload");
  if (SpecLoad(a->spec_path, a->sets, a->policy, &fresh, &err)) {
    a->spec.sig = sig;  // report this version once, not every turn
    AgentNote(a,
              "Your harness edit was rejected; the previous version is "
              "still in use:\n%s",
              err.data);
    cJSON_AddFalseToObject(e, "ok");
    JsonAddTruncated(e, "errors", err.data, 2000);
  } else {
    SpecFree(&a->spec);
    a->spec = fresh;
    KitLockWrite(&a->spec);
    ToolsBuild(a);
    char* system = SystemPrompt(a);
    cJSON* first = cJSON_GetArrayItem(a->messages, 0);
    if (first && strcmp(JsonStr(first, "content", ""), system)) {
      cJSON_ReplaceItemInObjectCaseSensitive(first, "content",
                                             cJSON_CreateString(system));
      SessionReset(&a->session, a->messages);
    }
    free(system);
    cJSON_AddTrueToObject(e, "ok");
    cJSON_AddNumberToObject(e, "tools", a->tools.count);
  }
  if (a->gate) GateAccept(a);
  if (rejected) cJSON_AddNumberToObject(e, "rejected", rejected);
  cJSON_AddNumberToObject(e, "ms", (Now() - start) * 1000);
  EventSend(e);
  BufferFree(&err);
  return -1;
}

// Applies `arx ctl` commands: notes for the agent, and stop.
static void ReadInbox(Agent* a) {
  cJSON* commands = SessionReadInbox(&a->session);
  cJSON* c;
  cJSON_ArrayForEach(c, commands) {
    const char* cmd = JsonStr(c, "cmd", "");
    if (!strcmp(cmd, "stop")) {
      a->stop_requested = 1;
    } else if (!strcmp(cmd, "note")) {
      AgentNote(a, "Note from your operator: %s", JsonStr(c, "text", ""));
    }
  }
  cJSON_Delete(commands);
}

// Gives queued harness notes to the agent as one user message.
static void FlushNotes(Agent* a) {
  if (!a->notes.len) return;
  char* text = XAsprintf("[harness]\n%s", a->notes.data);
  AgentAddMessage(a, "user", text);
  cJSON* e = EventNew("note");
  JsonAddTruncated(e, "text", a->notes.data, 1000);
  EventSend(e);
  free(text);
  a->notes.len = 0;
  a->notes.data[0] = 0;
}

// Asks the stop hook whether to go on. Returns 1 to keep going.
static int StopHook(Agent* a) {
  cJSON* in = cJSON_CreateObject();
  JsonAddTruncated(in, "last_message", a->final_output, 8192);
  cJSON* out = NULL;
  HookRun(a, "stop", in, &out);
  const char* decision = JsonStr(out, "decision", "");
  int keep_going = 1;
  if (!strcmp(decision, "continue")) {
    AgentAddMessage(a, "user", JsonStr(out, "message", "Continue."));
  } else if (!strcmp(decision, "restart")) {
    Compact(a, "restart", JsonStr(out, "message", NULL));
  } else {
    keep_going = 0;
  }
  cJSON_Delete(out);
  return keep_going;
}

// The loop; see agent.h.
int RunTurns(Agent* a) {
  KitLockWrite(&a->spec);  // a kit that pins versions: record the parts
  for (;;) {
    if (g_interrupted) return kExitInterrupted;
    int code = PolicyStop(a);  // a policy file changed and was about to run
    if (code < 0) code = CheckCaps(a);
    if (code >= 0) return code;
    code = MaybeReload(a);
    if (code >= 0) return code;
    ReadInbox(a);
    if (a->stop_requested) return kExitDone;
    FlushNotes(a);
    MaybeCompact(a);
    g_events.turn = ++a->session.turns;
    EventSend(EventNew("turn.start"));
    cJSON* message;
    code = ModelTurn(a, &message);
    if (code >= 0) return code;
    if (GateStopped(a)) cJSON_Delete(message);
    if ((code = PolicyStop(a)) >= 0) return code;
    cJSON_AddItemToArray(a->messages, message);
    SessionAppend(&a->session, message);
    cJSON* calls = cJSON_GetObjectItem(message, "tool_calls");
    if (cJSON_GetArraySize(calls)) {
      RunToolCalls(a, calls);
    } else {
      free(a->final_output);
      a->final_output = XStrdup(JsonStr(message, "content", ""));
      int go_on = StopHook(a);
      if ((code = PolicyStop(a)) >= 0) return code;
      if (!go_on) return kExitDone;
    }
    SessionWriteMeta(&a->session, "running");
  }
}
