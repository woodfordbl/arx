// model_call.c: one model call through its hooks. before_model gets the
// request and may replace any part of it; messages it returns become the
// history, so the transcript shows exactly what the model got. after_model
// gets the reply and may replace it. When the provider says the prompt is
// too long, before_model runs again with reason context_overflow, or the
// built-in compaction strategy runs when no hook changed anything; then the
// call is retried once.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/model/model.h"

// True when `name` is in the JSON string array `list`.
static int Listed(cJSON* list, const char* name) {
  cJSON* item;
  cJSON_ArrayForEach(item, list) {
    if (cJSON_IsString(item) && !strcmp(item->valuestring, name)) return 1;
  }
  return 0;
}

// The request the spec describes, without the messages: {tools, model,
// settings}.
static cJSON* NewRequest(Agent* a) {
  cJSON* request = cJSON_CreateObject();
  cJSON_AddItemToObject(request, "tools", ToolsJson(&a->tools));
  cJSON_AddStringToObject(request, "model", JsonStr(a->spec.root, "model", ""));
  cJSON* settings = JsonGet(a->spec.root, "model_settings");
  cJSON_AddItemToObject(request, "settings",
                        cJSON_IsObject(settings) ? cJSON_Duplicate(settings, 1)
                                                 : cJSON_CreateObject());
  return request;
}

// Runs the before_model hooks on `request` and the history. Returns 1 when
// a hook changed something.
static int BeforeModel(Agent* a, cJSON* request, const char* reason) {
  if (!HookExists(a, "before_model")) return 0;
  // The history moves into the request for the hooks and back out after,
  // so it is not copied; a hook's messages replace it there.
  cJSON_AddItemToObject(request, "messages", a->messages);
  cJSON_AddStringToObject(request, "reason", reason);
  cJSON* changed = cJSON_CreateArray();
  HookChain(a, "before_model", request, changed);
  a->messages = cJSON_DetachItemFromObjectCaseSensitive(request, "messages");
  cJSON_DeleteItemFromObjectCaseSensitive(request, "reason");
  if (Listed(changed, "messages")) SessionReset(&a->session, a->messages);
  int any = cJSON_GetArraySize(changed) > 0;
  cJSON_Delete(changed);
  return any;
}

// Sends the history with `request`.
static LlmStatus Send(Agent* a, cJSON* request, Reply* reply, Buffer* err) {
  err->len = 0;
  if (err->data) err->data[0] = 0;
  a->estimate_at_call = EstimateTokens(a->messages);
  return LlmChatWith(a, JsonStr(request, "model", ""),
                     cJSON_GetObjectItem(request, "settings"), a->messages,
                     cJSON_GetObjectItem(request, "tools"), 1, reply, err);
}

// Runs the after_model hooks on the reply.
static void AfterModel(Agent* a, Reply* r) {
  if (!HookExists(a, "after_model")) return;
  cJSON* in = cJSON_CreateObject();
  cJSON_AddItemToObject(in, "reply", r->message);
  cJSON* usage = cJSON_AddObjectToObject(in, "usage");
  cJSON_AddNumberToObject(usage, "prompt_tokens", (double)r->tokens_in);
  cJSON_AddNumberToObject(usage, "completion_tokens", (double)r->tokens_out);
  cJSON_AddNumberToObject(usage, "cost", r->cost);
  cJSON_AddStringToObject(in, "finish", r->finish);
  HookChain(a, "after_model", in, NULL);
  r->message = cJSON_DetachItemFromObjectCaseSensitive(in, "reply");
  cJSON_Delete(in);
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
  cJSON_AddNumberToObject(e, "tokens_cached", (double)r->tokens_cached);
  cJSON_AddNumberToObject(e, "cost", r->cost);
  cJSON_AddNumberToObject(
      e, "tool_calls",
      cJSON_GetArraySize(cJSON_GetObjectItem(r->message, "tool_calls")));
  EventSend(e);
}

// Compacts after a context-overflow error: the before_model hooks first,
// then the built-in strategy (hybrid for the default mask, which alone
// rarely frees enough). Returns 1 when something changed.
static int Overflow(Agent* a, cJSON* request) {
  if (BeforeModel(a, request, "context_overflow")) return 1;
  const char* s = JsonStr(a->spec.root, "compaction.strategy", "mask");
  return Compact(a, strcmp(s, "mask") ? s : "hybrid", NULL) == 0;
}

// One model call with its hooks; see agent.h.
int ModelTurn(Agent* a, cJSON** message) {
  *message = NULL;
  cJSON* request = NewRequest(a);
  BeforeModel(a, request, "turn");
  Buffer err = {0};
  Reply reply;
  LlmStatus status = Send(a, request, &reply, &err);
  if (status == kLlmContext && Overflow(a, request)) {
    status = Send(a, request, &reply, &err);
  }
  cJSON_Delete(request);
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
  } else {
    Account(a, &reply);
    AfterModel(a, &reply);
    *message = reply.message;
  }
  BufferFree(&err);
  return code;
}
