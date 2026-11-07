// tool_calls.c: runs the tool calls of one reply, one at a time, through
// their hooks. before_tool gets the raw call {id, name, args} and may change
// the name and arguments, or give the result itself so the tool does not
// run. after_tool gets {call, result, is_error} and may change the result;
// it runs for every call that before_tool let through, also after an error,
// a timeout or Ctrl-C. When a hook changed the call, the result says what
// ran, since the model only knows the call it made.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

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

// The raw call a before_tool hook gets: {id, name, args}, with the
// arguments parsed when they are JSON.
static cJSON* NewCall(const char* id, const char* name, const char* args) {
  cJSON* call = cJSON_CreateObject();
  cJSON_AddStringToObject(call, "id", id);
  cJSON_AddStringToObject(call, "name", name);
  cJSON* parsed = cJSON_Parse(args);
  cJSON_AddItemToObject(call, "args",
                        parsed ? parsed : cJSON_CreateString(args));
  return call;
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

// Runs the after_tool hooks on the result `text` (consumed). Returns the
// result to keep.
static char* AfterTool(Agent* a, cJSON* call, char* text, int is_error) {
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

// Runs one tool call with its hooks and sends `end` (consumed) as soon as
// the tool finishes, before the after_tool hooks. Returns the result.
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
  cJSON* model_call = NewCall(id, name, args);
  cJSON* call = cJSON_Duplicate(model_call, 1);
  char* text = BeforeTool(a, call, &is_error);
  int ran = !text;
  if (ran) {
    // Unchanged arguments go to the tool exactly as the model wrote them.
    char* input = cJSON_Compare(cJSON_GetObjectItem(call, "args"),
                                cJSON_GetObjectItem(model_call, "args"), 1)
                      ? XStrdup(args)
                      : ArgsText(call);
    text =
        ToolCall(a, JsonStr(call, "name", ""), input, &is_error, out_path, end);
    free(input);
  }
  cJSON_AddBoolToObject(end, "error", is_error);
  char* first_line = XStrndup(text, strcspn(text, "\n"));
  JsonAddTruncated(end, "preview", first_line, 100);
  free(first_line);
  EventSend(end);
  if (ran) {
    text = AfterTool(a, call, text, is_error);
    char* line = RanAs(model_call, call);
    if (line) {
      size_t len = strlen(text);
      char* joined = XAsprintf("%s%s%s", text,
                               len && text[len - 1] == '\n' ? "" : "\n", line);
      free(text);
      free(line);
      text = joined;
    }
  }
  cJSON_Delete(call);
  cJSON_Delete(model_call);
  return text;
}

// Runs every tool call of an assistant message; see agent.h.
void RunToolCalls(Agent* a, cJSON* calls) {
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
