// tool_calls.c: the tool runtime, over the session's call table on Agent.
// Hooks decide if a call may run; the runtime decides when. before_tool
// gets the raw call {id, name, args, keys} and may change it, or give the
// result itself so the tool does not run. The allowed calls wait in the
// table and start by their keys, or when a scheduler plugin says so.
// after_tool gets {call, result, is_error} as each call ends and may change
// the result; it runs for every call that ran, also after an error, a
// timeout or Ctrl-C. When a hook changed the call, the result says what
// ran, since the model only knows the call it made. Results go into the
// history in call order.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/mcp/mcp.h"

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

// The arguments as the tool gets them on stdin (malloc'd).
static char* ArgsText(cJSON* call) {
  cJSON* args = cJSON_GetObjectItem(call, "args");
  if (cJSON_IsString(args)) return XStrdup(args->valuestring);
  return args ? cJSON_PrintUnformatted(args) : XStrdup("{}");
}

// The raw call a before_tool hook gets: {id, name, args, keys}, with the
// arguments parsed when they are JSON and the keys from the tool's schema.
static cJSON* NewCall(Agent* a, const char* id, const char* name,
                      const char* args) {
  cJSON* call = cJSON_CreateObject();
  cJSON_AddStringToObject(call, "id", id);
  cJSON_AddStringToObject(call, "name", name);
  cJSON* parsed = cJSON_Parse(args);
  const Tool* tool = ToolFind(a, name);
  cJSON* keys = KeysFor(tool, parsed);
  cJSON_AddItemToObject(call, "args",
                        parsed ? parsed : cJSON_CreateString(args));
  cJSON_AddItemToObject(call, "keys", keys);
  // Input only: a guard can deny the calls of one MCP server by name.
  if (tool && tool->server) {
    cJSON_AddStringToObject(call, "server", tool->server);
  }
  return call;
}

// The keys the call runs with: the ones a hook printed, else the tool's
// keys for the call as it is now (a hook may have changed the name or the
// arguments).
static void FinalKeys(Agent* a, cJSON* model_call, cJSON* call) {
  cJSON* keys = cJSON_GetObjectItem(call, "keys");
  if (KeysValid(keys) &&
      !cJSON_Compare(keys, cJSON_GetObjectItem(model_call, "keys"), 1)) {
    return;
  }
  cJSON* args = cJSON_GetObjectItem(call, "args");
  cJSON* fresh = KeysFor(ToolFind(a, JsonStr(call, "name", "")),
                         cJSON_IsObject(args) ? args : NULL);
  cJSON_DeleteItemFromObjectCaseSensitive(call, "keys");
  cJSON_AddItemToObject(call, "keys", fresh);
}

// Runs the before_tool hooks on `call`. Returns the result that takes the
// place of the run, or NULL to run the tool.
static char* BeforeTool(Agent* a, cJSON* call, int* is_error) {
  if (HookChain(a, "before_tool", call, NULL) < 0) {
    return XStrdup("denied: the before_tool hook failed (fail: closed)");
  }
  const char* result = JsonStr(call, "result", NULL);
  if (!result) return NULL;
  *is_error = JsonBool(call, "is_error", 0);
  return XStrdup(result);
}

// A backoff that an after_tool hook printed ({"key", "secs"}), detached
// from `in`, or NULL. Only a scheduler plugin uses it.
static cJSON* Backoff(cJSON* in) {
  cJSON* b = cJSON_GetObjectItem(in, "backoff");
  if (!JsonStr(b, "key", NULL) || !cJSON_IsNumber(JsonGet(b, "secs"))) {
    return NULL;
  }
  return cJSON_DetachItemViaPointer(in, b);
}

// Runs the after_tool hooks on the result `text` (consumed). Returns the
// result to keep, and the backoff the hooks printed in `*backoff`.
static char* AfterTool(Agent* a, cJSON* call, char* text, int is_error,
                       cJSON** backoff) {
  if (!HookExists(a, "after_tool")) return text;
  cJSON* in = cJSON_CreateObject();
  cJSON* c = cJSON_AddObjectToObject(in, "call");
  cJSON_AddStringToObject(c, "id", JsonStr(call, "id", ""));
  cJSON_AddStringToObject(c, "name", JsonStr(call, "name", ""));
  cJSON_AddItemToObject(c, "args",
                        cJSON_Duplicate(cJSON_GetObjectItem(call, "args"), 1));
  cJSON_AddStringToObject(in, "result", text);
  cJSON_AddBoolToObject(in, "is_error", is_error);
  // After a Ctrl-C the hook must still run, so it is not killed at once.
  int interrupted = g_interrupted;
  g_interrupted = 0;
  HookChain(a, "after_tool", in, NULL);
  if (interrupted) g_interrupted = 1;
  char* result = XStrdup(JsonStr(in, "result", text));
  *backoff = Backoff(in);
  cJSON_Delete(in);
  free(text);
  return result;
}

// The line that says what ran when a hook changed the call, such as
// "[ran as: git push]", or NULL when it did not.
static char* RanAs(cJSON* model_call, cJSON* call) {
  const char* name = JsonStr(call, "name", "");
  int renamed = strcmp(name, JsonStr(model_call, "name", ""));
  if (!renamed && cJSON_Compare(cJSON_GetObjectItem(call, "args"),
                                cJSON_GetObjectItem(model_call, "args"), 1)) {
    return NULL;
  }
  char* args = ArgsText(call);
  char* preview = Preview(args);
  char* line = renamed ? XAsprintf("[ran as: %s %s]", name, preview)
                       : XAsprintf("[ran as: %s]", preview);
  free(preview);
  free(args);
  return line;
}

// Sends the call's tool.end event with its error flag and the first line of
// its result.
static void SendEnd(Call* c) {
  cJSON_AddBoolToObject(c->end, "error", c->is_error);
  char* first_line = XStrndup(c->text, strcspn(c->text, "\n"));
  JsonAddTruncated(c->end, "preview", first_line, 100);
  free(first_line);
  EventSend(c->end);
  c->end = NULL;
}

// Finishes a call whose tool ended (or could not start): sends tool.end
// before the after_tool hooks, so the view shows the end at once, then
// runs them and tells a scheduler plugin.
static void Complete(Agent* a, Call* c, double secs) {
  SendEnd(c);
  cJSON* backoff = NULL;
  c->text = AfterTool(a, c->call, c->text, c->is_error, &backoff);
  char* line = RanAs(c->model_call, c->call);
  if (line) {
    size_t len = strlen(c->text);
    char* joined = XAsprintf("%s%s%s", c->text,
                             len && c->text[len - 1] == '\n' ? "" : "\n", line);
    free(c->text);
    free(line);
    c->text = joined;
  }
  c->state = kDone;
  SchedDone(c->id, secs, c->is_error, backoff);
  cJSON_Delete(backoff);
}

// Ends a call without a run, with the result `text` (consumed).
static void EndWithout(Call* c, char* text, int is_error) {
  c->text = text;
  c->is_error = is_error;
  c->state = kDone;
  SendEnd(c);
}

// Starts a queued call's tool.
static void Launch(Agent* a, Call* c) {
  // Unchanged arguments go to the tool exactly as the model wrote them.
  char* input = cJSON_Compare(cJSON_GetObjectItem(c->call, "args"),
                              cJSON_GetObjectItem(c->model_call, "args"), 1)
                    ? XStrdup(c->args)
                    : ArgsText(c->call);
  c->run = ToolStart(a, JsonStr(c->call, "name", ""), input, &c->text,
                     &c->is_error, &c->out_path, c->end);
  free(input);
  c->state = kRunning;
  if (!c->run) Complete(a, c, 0);
}

// Runs the before_tool hooks of one call and sends tool.start. Leaves the
// call queued, or done when a hook gave the result.
static void Prepare(Agent* a, Call* c, cJSON* raw) {
  const char* name = JsonStr(raw, "function.name", "");
  c->id = XStrdup(JsonStr(raw, "id", ""));
  c->args = XStrdup(JsonStr(raw, "function.arguments", "{}"));
  c->end = EventNew("tool.end");
  cJSON_AddStringToObject(c->end, "id", c->id);
  cJSON_AddStringToObject(c->end, "name", name);
  if (g_interrupted) {
    EndWithout(c, XStrdup("[interrupted before this tool ran]"), 1);
    return;
  }
  char* preview = Preview(c->args);
  cJSON* start = EventNew("tool.start");
  cJSON_AddStringToObject(start, "id", c->id);
  cJSON_AddStringToObject(start, "name", name);
  cJSON_AddStringToObject(start, "preview", preview);
  c->model_call = NewCall(a, c->id, name, c->args);
  const char* server = JsonStr(c->model_call, "server", NULL);
  if (server) cJSON_AddStringToObject(start, "server", server);
  EventSend(start);
  free(preview);
  c->call = cJSON_Duplicate(c->model_call, 1);
  int is_error = 1;
  char* text = BeforeTool(a, c->call, &is_error);
  if (text) {
    EndWithout(c, text, is_error);
    return;
  }
  FinalKeys(a, c->model_call, c->call);
  c->state = kQueued;
}

// The built-in scheduler: starts each queued call, in table order, whose
// keys conflict with no running call and no call queued before it. So
// calls that conflict run in the order the model gave them.
static void StartByKeys(Agent* a) {
  Call** calls = a->calls;
  for (int i = 0; i < a->call_count; i++) {
    if (calls[i]->state != kQueued) continue;
    cJSON* keys = cJSON_GetObjectItem(calls[i]->call, "keys");
    int free_to_run = 1;
    for (int j = 0; j < a->call_count && free_to_run; j++) {
      int before =
          calls[j]->state == kRunning || (calls[j]->state == kQueued && j < i);
      if (j != i && before &&
          KeysConflict(keys, cJSON_GetObjectItem(calls[j]->call, "keys"))) {
        free_to_run = 0;
      }
    }
    if (free_to_run) Launch(a, calls[i]);
  }
}

// Applies what a scheduler plugin said: the calls to start and the
// results that end calls without a run. Unknown ids are ignored.
static void StartByPlugin(Agent* a) {
  cJSON* start = cJSON_CreateArray();
  cJSON* results = cJSON_CreateObject();
  SchedPoll(start, results);
  for (int i = 0; i < a->call_count; i++) {
    Call* c = a->calls[i];
    if (c->state != kQueued) continue;
    const char* text = JsonStr(results, c->id, NULL);
    cJSON* id;
    cJSON_ArrayForEach(id, start) {
      if (c->state == kQueued && !strcmp(id->valuestring, c->id)) Launch(a, c);
    }
    if (text && c->state == kQueued) EndWithout(c, XStrdup(text), 1);
  }
  cJSON_Delete(start);
  cJSON_Delete(results);
}

// One round of the call table; see agent.h.
int CallsPoll(Agent* a, double wait) {
  // After Ctrl-C nothing new starts; running calls are stopped by ProcPoll
  // and still get their after_tool hooks.
  for (int i = 0; i < a->call_count && g_interrupted; i++) {
    if (a->calls[i]->state == kQueued) {
      EndWithout(a->calls[i], XStrdup("[interrupted before this tool ran]"), 1);
    }
  }
  if (SchedActive()) StartByPlugin(a);
  if (!SchedActive()) StartByKeys(a);
  ProcChild** kids = XMalloc((size_t)(a->call_count + 1) * sizeof(*kids));
  int k = 0, queued = 0, running = 0;
  for (int i = 0; i < a->call_count; i++) {
    // An MCP call runs with no process of its own.
    ProcChild* kid =
        a->calls[i]->state == kRunning ? ToolChild(a->calls[i]->run) : NULL;
    if (kid) kids[k++] = kid;
    running += a->calls[i]->state == kRunning;
    queued += a->calls[i]->state == kQueued;
    // A search of the cache has its answer at once: do not wait for it.
    if (a->calls[i]->state == kRunning && !kid) wait = 0.001;
  }
  if (running || queued) ProcPoll(kids, k, SchedWait(wait));
  free(kids);
  McpPump(a);
  for (int i = 0; i < a->call_count; i++) {
    Call* c = a->calls[i];
    if (c->state != kRunning || !ToolDone(c->run)) continue;
    c->text = ToolFinish(c->run, &c->is_error, c->end);
    c->run = NULL;
    Complete(a, c, JsonNum(c->end, "secs", 0));
  }
  return running + queued;
}

// Adds the tool message of a call that is done to the history and the
// transcript, and frees the call.
static void Deliver(Agent* a, Call* c) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "role", "tool");
  cJSON_AddStringToObject(m, "tool_call_id", c->id);
  cJSON_AddStringToObject(m, "content", c->text);
  if (c->out_path) cJSON_AddStringToObject(m, "_out", c->out_path);
  cJSON_AddItemToArray(a->messages, m);
  SessionAppend(&a->session, m);
  free(c->id);
  free(c->args);
  free(c->text);
  free(c->out_path);
  cJSON_Delete(c->call);
  cJSON_Delete(c->model_call);
  free(c);
}

// True while a call of this reply (`mine`, `n` of them) is not done.
static int Pending(Call* const* mine, int n) {
  for (int i = 0; i < n; i++) {
    if (mine[i]->state != kDone) return 1;
  }
  return 0;
}

// Runs every tool call of an assistant message; see agent.h.
void RunToolCalls(Agent* a, cJSON* calls) {
  int n = cJSON_GetArraySize(calls);
  Call** mine = XMalloc((size_t)(n ? n : 1) * sizeof(*mine));
  a->calls =
      XRealloc(a->calls, (size_t)(a->call_count + n + 1) * sizeof(*a->calls));
  int plugin = SchedOpen(a);
  for (int i = 0; i < n; i++) {
    Call* c = XMalloc(sizeof(*c));
    memset(c, 0, sizeof(*c));
    mine[i] = a->calls[a->call_count++] = c;
    Prepare(a, c, cJSON_GetArrayItem(calls, i));
    if (plugin && c->state == kQueued) {
      SchedReady(c->id, JsonStr(c->call, "name", ""),
                 cJSON_GetObjectItem(c->call, "keys"));
    }
  }
  while (Pending(mine, n)) CallsPoll(a, 0.1);
  // One more round reads what a scheduler plugin said about the last calls,
  // as the runtime always did before it returned.
  CallsPoll(a, 0);
  // This reply's calls leave the table, and their results go in call order.
  int kept = 0;
  for (int i = 0; i < a->call_count; i++) {
    int done = 0;
    for (int j = 0; j < n && !done; j++) done = a->calls[i] == mine[j];
    if (!done) a->calls[kept++] = a->calls[i];
  }
  a->call_count = kept;
  for (int i = 0; i < n; i++) Deliver(a, mine[i]);
  free(mine);
}
