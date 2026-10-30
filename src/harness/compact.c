// compact.c: the compaction strategies. Masking is the default: "The
// Complexity Trap" (JetBrains/TUM, 2025) found it halves cost and matches
// model-written summaries. Masking happens in one batch when the trigger is
// crossed, so the provider's prompt cache is invalidated rarely.

#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/model/model.h"

static const char kMaskedPrefix[] = "[output cleared";
static const char kDefaultSummaryPrompt[] =
    "You are compacting an agent's working memory. Summarize the work below "
    "so the agent can continue without it: the goal, what was tried and the "
    "results (keep the numbers), the current state of files, open problems, "
    "and the next steps. Be specific and brief; keep exact paths, commands "
    "and values.";

// Serialized size / 4, a common rough token estimate.
int64_t EstimateTokens(cJSON* messages) {
  char* text = cJSON_PrintUnformatted(messages);
  int64_t n = (int64_t)strlen(text) / 4;
  free(text);
  return n;
}

// Calibrates the estimate with the provider's count for the last call.
int64_t CurrentTokens(struct Agent* a) {
  int64_t estimate = EstimateTokens(a->messages);
  if (a->estimate_at_call > 0 && a->tokens_at_call > 0) {
    return estimate * a->tokens_at_call / a->estimate_at_call;
  }
  return estimate;
}

// The token count that triggers compaction.
static int64_t Limit(struct Agent* a) {
  double window = JsonNum(a->spec.root, "context_window", 128000);
  return (int64_t)(window * JsonNum(a->spec.root, "compaction.trigger", 0.7));
}

// Finds the assistant tool call with `id`, or NULL.
static cJSON* FindCall(cJSON* messages, const char* id) {
  for (cJSON* m = messages->child; m; m = m->next) {
    cJSON* call;
    cJSON_ArrayForEach(call, cJSON_GetObjectItem(m, "tool_calls")) {
      if (!strcmp(JsonStr(call, "id", ""), id)) return call;
    }
  }
  return NULL;
}

// True when `name` is in the JSON string array `list`.
static int Listed(cJSON* list, const char* name) {
  cJSON* item;
  cJSON_ArrayForEach(item, list) {
    if (cJSON_IsString(item) && !strcmp(item->valuestring, name)) return 1;
  }
  return 0;
}

// Replaces every tool output except the newest `keep` with a pointer to its
// file. Returns how many were masked.
static int Mask(struct Agent* a) {
  cJSON* root = a->spec.root;
  int keep = (int)JsonNum(root, "compaction.keep", 5);
  int clear_inputs = JsonBool(root, "compaction.clear_inputs", 0);
  cJSON* exclude = JsonGet(root, "compaction.exclude_tools");
  int total = 0, seen = 0, masked = 0;
  for (cJSON* m = a->messages->child; m; m = m->next) {
    total += !strcmp(JsonStr(m, "role", ""), "tool");
  }
  for (cJSON* m = a->messages->child; m && seen < total - keep; m = m->next) {
    if (strcmp(JsonStr(m, "role", ""), "tool")) continue;
    seen++;
    const char* content = JsonStr(m, "content", "");
    if (!strncmp(content, kMaskedPrefix, strlen(kMaskedPrefix))) continue;
    cJSON* call = FindCall(a->messages, JsonStr(m, "tool_call_id", ""));
    if (Listed(exclude, JsonStr(call, "function.name", ""))) continue;
    char* note = XAsprintf(
        "%s to save context: %zu bytes; the full output is "
        "in %s]",
        kMaskedPrefix, strlen(content),
        JsonStr(m, "_out", "the session folder"));
    cJSON_ReplaceItemInObjectCaseSensitive(m, "content",
                                           cJSON_CreateString(note));
    free(note);
    if (clear_inputs && call) {
      cJSON_ReplaceItemInObjectCaseSensitive(
          cJSON_GetObjectItem(call, "function"), "arguments",
          cJSON_CreateString("{}"));
    }
    masked++;
  }
  return masked;
}

// The index where the last `keep` turns start (an assistant message), or -1.
static int CutIndex(cJSON* messages, int keep) {
  int count = 0, cut = -1, i = 0;
  for (cJSON* m = messages->child; m; m = m->next, i++) {
    if (!strcmp(JsonStr(m, "role", ""), "assistant")) count++;
  }
  i = 0;
  for (cJSON* m = messages->child; m; m = m->next, i++) {
    if (strcmp(JsonStr(m, "role", ""), "assistant")) continue;
    if (count-- == keep) cut = i;
  }
  return cut;
}

// Renders messages [from, to) as plain text for the summarizer.
static char* PlainHistory(cJSON* messages, int from, int to) {
  Buffer b = {0};
  int i = 0;
  for (cJSON* m = messages->child; m && i < to; m = m->next, i++) {
    if (i < from) continue;
    char* content = Truncate(JsonStr(m, "content", ""), 2000);
    BufferPrintf(&b, "\n## %s\n%s\n", JsonStr(m, "role", "?"), content);
    free(content);
    cJSON* call;
    cJSON_ArrayForEach(call, cJSON_GetObjectItem(m, "tool_calls")) {
      char* args = Truncate(JsonStr(call, "function.arguments", ""), 300);
      BufferPrintf(&b, "-> %s(%s)\n", JsonStr(call, "function.name", "?"),
                   args);
      free(args);
    }
  }
  return BufferTake(&b);
}

// Swaps in a new history.
static void Replace(struct Agent* a, cJSON* messages) {
  cJSON_Delete(a->messages);
  a->messages = messages;
}

// Summarizes everything between the first user message and the last `keep`
// turns with one model call. Returns 1 on success, 0 or -1 otherwise.
static int Summarize(struct Agent* a) {
  int keep = (int)JsonNum(a->spec.root, "compaction.keep", 5);
  int cut = CutIndex(a->messages, keep < 1 ? 1 : keep);
  if (cut <= 2) return 0;
  char* prompt =
      SpecText(&a->spec, JsonGet(a->spec.root, "compaction.prompt"), NULL);
  char* history = PlainHistory(a->messages, 1, cut);
  cJSON* request = cJSON_CreateArray();
  cJSON* system = cJSON_CreateObject();
  cJSON_AddStringToObject(system, "role", "system");
  cJSON_AddStringToObject(system, "content",
                          prompt ? prompt : kDefaultSummaryPrompt);
  cJSON* user = cJSON_CreateObject();
  cJSON_AddStringToObject(user, "role", "user");
  cJSON_AddStringToObject(user, "content", history);
  cJSON_AddItemToArray(request, system);
  cJSON_AddItemToArray(request, user);
  Reply reply;
  Buffer err = {0};
  int ok = LlmChat(a, request, NULL, 0, &reply, &err) == kLlmOk;
  if (ok) {
    a->session.tokens_in += reply.tokens_in;
    a->session.tokens_out += reply.tokens_out;
    a->session.cost += reply.cost;
    char* summary = XAsprintf(
        "[Summary of the work so far, written before the context was "
        "compacted]\n%s",
        JsonStr(reply.message, "content", ""));
    cJSON* fresh = cJSON_CreateArray();
    int i = 0;
    for (cJSON* m = a->messages->child; m; m = m->next, i++) {
      if (i == 2) {
        cJSON* note = cJSON_CreateObject();
        cJSON_AddStringToObject(note, "role", "user");
        cJSON_AddStringToObject(note, "content", summary);
        cJSON_AddItemToArray(fresh, note);
      }
      if (i < 2 || i >= cut) cJSON_AddItemToArray(fresh, cJSON_Duplicate(m, 1));
    }
    Replace(a, fresh);
    free(summary);
    cJSON_Delete(reply.message);
  } else {
    AgentNote(a, "Summarizing the context failed: %s", err.data);
  }
  cJSON_Delete(request);
  BufferFree(&err);
  free(history);
  free(prompt);
  return ok ? 1 : -1;
}

// Starts over from the system prompt and the first message (Ralph-style).
static int Restart(struct Agent* a, const char* message) {
  char* system = SystemPrompt(a);
  char* first = FirstMessage(a, a->prompt ? a->prompt : "");
  Replace(a, cJSON_CreateArray());
  AgentAddMessage(a, "system", system);
  AgentAddMessage(a, "user", first);
  if (message && *message) AgentAddMessage(a, "user", message);
  free(system);
  free(first);
  return 1;
}

// Runs an external compactor: {"messages", "usage", "context_window"} in,
// {"messages": [...]} out. Returns 1, or -1 if it failed.
static int External(struct Agent* a, const char* strategy) {
  cJSON* in = cJSON_CreateObject();
  cJSON_AddItemToObject(in, "messages", cJSON_Duplicate(a->messages, 1));
  cJSON* usage = cJSON_AddObjectToObject(in, "usage");
  cJSON_AddNumberToObject(usage, "prompt_tokens", (double)CurrentTokens(a));
  cJSON_AddNumberToObject(in, "context_window",
                          JsonNum(a->spec.root, "context_window", 128000));
  char* text = cJSON_PrintUnformatted(in);
  char* path = PathJoin(a->spec.dir, strategy);
  char* argv[] = {path, NULL};
  Buffer out = {0};
  Proc p = {.argv = argv,
            .in = text,
            .in_len = strlen(text),
            .timeout = 120,
            .on_out = BufferSink,
            .out_ctx = &out};
  ProcResult r;
  int ok = ProcRun(&p, &r) == 0 && r.code == 0;
  cJSON* result = ok ? cJSON_Parse(out.data ? out.data : "") : NULL;
  cJSON* messages = cJSON_GetObjectItem(result, "messages");
  ok = cJSON_GetArraySize(messages) > 0;
  for (cJSON* m = ok ? messages->child : NULL; m; m = m->next) {
    if (!JsonStr(m, "role", NULL)) ok = 0;
  }
  if (ok) Replace(a, cJSON_DetachItemViaPointer(result, messages));
  cJSON_Delete(result);
  cJSON_Delete(in);
  BufferFree(&out);
  free(text);
  free(path);
  return ok ? 1 : -1;
}

// Runs a strategy; see harness.h.
int Compact(struct Agent* a, const char* strategy, const char* message) {
  int64_t before = CurrentTokens(a);
  int changed;
  if (!strcmp(strategy, "mask")) {
    changed = Mask(a);
  } else if (!strcmp(strategy, "summarize")) {
    changed = Summarize(a);
  } else if (!strcmp(strategy, "hybrid")) {
    changed = Mask(a);
    if (CurrentTokens(a) > Limit(a) && Summarize(a) > 0) changed = 1;
  } else if (!strcmp(strategy, "restart")) {
    changed = Restart(a, message);
  } else if ((changed = External(a, strategy)) < 0) {
    AgentNote(a, "The compactor %s failed; masking was used instead.",
              strategy);
    changed = Mask(a);
  }
  if (changed <= 0) return -1;
  SessionReset(&a->session, a->messages);
  cJSON* e = EventNew("compact");
  cJSON_AddStringToObject(e, "strategy", strategy);
  cJSON_AddNumberToObject(e, "tokens_before", (double)before);
  cJSON_AddNumberToObject(e, "tokens_after", (double)CurrentTokens(a));
  EventSend(e);
  return 0;
}

// Compacts when over the trigger.
void MaybeCompact(struct Agent* a) {
  if (CurrentTokens(a) <= Limit(a)) return;
  Compact(a, JsonStr(a->spec.root, "compaction.strategy", "mask"), NULL);
}
