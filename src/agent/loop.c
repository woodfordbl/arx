// loop.c: the turn loop. Before each model call it hot-reloads the harness
// if any of its files changed, reads the inbox, hands harness notes to the
// agent and compacts the context. After the call it runs the tool calls
// through the before_tool and after_tool hooks, and asks the stop hook
// whether to go on when the agent stops calling tools.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/model/model.h"

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

// Reloads the spec, tools and prompt when any harness file changed. A bad
// edit keeps the previous version and tells the agent why.
static void MaybeReload(Agent* a) {
  uint64_t sig = SpecSignature(&a->spec);
  if (sig == a->spec.sig) return;
  double start = Now();
  Spec fresh;
  Buffer err = {0};
  cJSON* e = EventNew("harness.reload");
  if (SpecLoad(a->spec_path, a->sets, &fresh, &err)) {
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
  cJSON_AddNumberToObject(e, "ms", (Now() - start) * 1000);
  EventSend(e);
  BufferFree(&err);
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

// A one-line summary of a tool call for the terminal view: the command,
// path or task when there is one, else the raw arguments.
static char* Preview(const char* args) {
  cJSON* parsed = cJSON_Parse(args);
  const char* s = JsonStr(parsed, "command", NULL);
  if (!s) s = JsonStr(parsed, "path", NULL);
  if (!s) s = JsonStr(parsed, "task", NULL);
  char* text = Truncate(s ? s : args, 120);
  for (char* c = text; *c; c++) {
    if (*c == '\n') *c = ' ';
  }
  cJSON_Delete(parsed);
  return text;
}

// Runs the before_tool hook. Returns a denial message, or NULL to go on.
static char* BeforeTool(Agent* a, const char* name, const char* args) {
  cJSON* in = cJSON_CreateObject();
  cJSON* tool = cJSON_AddObjectToObject(in, "tool");
  cJSON_AddStringToObject(tool, "name", name);
  cJSON* parsed = cJSON_Parse(args);
  cJSON_AddItemToObject(tool, "args",
                        parsed ? parsed : cJSON_CreateString(args));
  cJSON* out = NULL;
  int rc = HookRun(a, "before_tool", in, &out);
  char* denial = NULL;
  if (rc < 0 && HookFailsClosed(a, "before_tool")) {
    denial = XStrdup("denied: the before_tool hook failed (fail: closed)");
  } else if (!strcmp(JsonStr(out, "decision", ""), "deny")) {
    denial = XAsprintf("denied by the before_tool hook: %s",
                       JsonStr(out, "reason", "no reason given"));
  }
  cJSON_Delete(out);
  return denial;
}

// Runs the after_tool hook. Returns a note to append, or NULL.
static char* AfterTool(Agent* a, const char* name, const char* result,
                       int is_error) {
  cJSON* in = cJSON_CreateObject();
  cJSON_AddStringToObject(cJSON_AddObjectToObject(in, "tool"), "name", name);
  cJSON* res = cJSON_AddObjectToObject(in, "result");
  JsonAddTruncated(res, "text", result, 8192);
  cJSON_AddBoolToObject(res, "error", is_error);
  cJSON* out = NULL;
  HookRun(a, "after_tool", in, &out);
  const char* note = JsonStr(out, "note", NULL);
  char* copy = note ? XStrdup(note) : NULL;
  cJSON_Delete(out);
  return copy;
}

// Runs one tool call with its hooks and sends `end` (consumed) as soon as
// the tool finishes, before the after_tool hook. Returns the result.
static char* RunOne(Agent* a, const char* id, const char* name,
                    const char* args, char** out_path, cJSON* end) {
  int is_error = 1;
  char* preview = Preview(args);
  cJSON* start = EventNew("tool.start");
  cJSON_AddStringToObject(start, "id", id);
  cJSON_AddStringToObject(start, "name", name);
  cJSON_AddStringToObject(start, "preview", preview);
  EventSend(start);
  free(preview);
  char* text = BeforeTool(a, name, args);
  if (!text) text = ToolCall(a, name, args, &is_error, out_path, end);
  cJSON_AddBoolToObject(end, "error", is_error);
  char* first_line = XStrndup(text, strcspn(text, "\n"));
  JsonAddTruncated(end, "preview", first_line, 100);
  free(first_line);
  EventSend(end);
  char* note = AfterTool(a, name, text, is_error);
  if (note) {
    char* joined = XAsprintf("%s\n[after_tool] %s", text, note);
    free(text);
    text = joined;
    free(note);
  }
  return text;
}

// Runs every tool call of an assistant message and records the results.
// Calls after a Ctrl-C still get a result, so the history stays valid.
static void RunToolCalls(Agent* a, cJSON* calls) {
  cJSON* call;
  cJSON_ArrayForEach(call, calls) {
    const char* id = JsonStr(call, "id", "");
    const char* name = JsonStr(call, "function.name", "");
    const char* args = JsonStr(call, "function.arguments", "{}");
    char* out_path = NULL;
    cJSON* end = EventNew("tool.end");
    cJSON_AddStringToObject(end, "id", id);
    cJSON_AddStringToObject(end, "name", name);
    char* text;
    if (g_interrupted) {
      text = XStrdup("[interrupted before this tool ran]");
      EventSend(end);
    } else {
      text = RunOne(a, id, name, args, &out_path, end);
    }
    cJSON* m = cJSON_CreateObject();
    cJSON_AddStringToObject(m, "role", "tool");
    cJSON_AddStringToObject(m, "tool_call_id", id);
    cJSON_AddStringToObject(m, "content", text);
    if (out_path) cJSON_AddStringToObject(m, "_out", out_path);
    cJSON_AddItemToArray(a->messages, m);
    SessionAppend(&a->session, m);
    free(text);
    free(out_path);
  }
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

// Calls the model; if the prompt is too long, compacts once and retries.
// Returns -1 on success, else an exit code.
static int CallModel(Agent* a, Reply* reply) {
  cJSON* tools = ToolsJson(&a->tools);
  Buffer err = {0};
  a->estimate_at_call = EstimateTokens(a->messages);
  LlmStatus status = LlmChat(a, a->messages, tools, 1, reply, &err);
  if (status == kLlmContext) {
    const char* s = JsonStr(a->spec.root, "compaction.strategy", "mask");
    if (Compact(a, strcmp(s, "mask") ? s : "hybrid", NULL) == 0) {
      err.len = 0;
      a->estimate_at_call = EstimateTokens(a->messages);
      status = LlmChat(a, a->messages, tools, 1, reply, &err);
    }
  }
  cJSON_Delete(tools);
  int code = -1;
  if (status == kLlmInterrupted) {
    code = kExitInterrupted;
  } else if (status != kLlmOk) {
    cJSON* e = EventNew("error");
    JsonAddTruncated(e, "error", err.len ? err.data : "the model call failed",
                     1000);
    EventSend(e);
    if (!g_events.render) fprintf(stderr, "arx: %s\n", err.data);
    code = status == kLlmAuth ? kExitAuth : kExitError;
  }
  BufferFree(&err);
  return code;
}

// Adds a reply's usage to the session and reports it.
static void Account(Agent* a, const Reply* r) {
  a->session.tokens_in += r->tokens_in;
  a->session.tokens_out += r->tokens_out;
  a->session.cost += r->cost;
  a->tokens_at_call = r->tokens_in;
  cJSON* e = EventNew("model.message");
  cJSON_AddNumberToObject(e, "tokens_in", (double)r->tokens_in);
  cJSON_AddNumberToObject(e, "tokens_out", (double)r->tokens_out);
  cJSON_AddNumberToObject(e, "cost", r->cost);
  cJSON_AddNumberToObject(
      e, "tool_calls",
      cJSON_GetArraySize(cJSON_GetObjectItem(r->message, "tool_calls")));
  EventSend(e);
}

// The loop; see agent.h.
int RunTurns(Agent* a) {
  for (;;) {
    if (g_interrupted) return kExitInterrupted;
    int code = CheckCaps(a);
    if (code >= 0) return code;
    MaybeReload(a);
    ReadInbox(a);
    if (a->stop_requested) return kExitDone;
    FlushNotes(a);
    MaybeCompact(a);
    g_events.turn = ++a->session.turns;
    EventSend(EventNew("turn.start"));
    Reply reply;
    code = CallModel(a, &reply);
    if (code >= 0) return code;
    Account(a, &reply);
    cJSON_AddItemToArray(a->messages, reply.message);
    SessionAppend(&a->session, reply.message);
    cJSON* calls = cJSON_GetObjectItem(reply.message, "tool_calls");
    if (cJSON_GetArraySize(calls)) {
      RunToolCalls(a, calls);
    } else {
      free(a->final_output);
      a->final_output = XStrdup(JsonStr(reply.message, "content", ""));
      if (!StopHook(a)) return kExitDone;
    }
    SessionWriteMeta(&a->session, "running");
  }
}
