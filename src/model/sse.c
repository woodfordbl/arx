// sse.c: turns "data: {...}" chunks into text and tool calls. Providers
// differ: some resend the whole tool name in every chunk, some omit tool
// call ids or indexes, some send a final non-delta "message". All of those
// are handled here so the loop sees one clean message.

#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/io/io.h"
#include "src/model/model.h"

// Non-SSE body text kept for error messages.
static const size_t kMaxRawBytes = 65536;

// Reads usage numbers, wherever in the stream they arrive.
static void ReadUsage(Stream* s, cJSON* usage) {
  if (!cJSON_IsObject(usage)) return;
  s->tokens_in = (int64_t)JsonNum(usage, "prompt_tokens", (double)s->tokens_in);
  s->tokens_out =
      (int64_t)JsonNum(usage, "completion_tokens", (double)s->tokens_out);
  cJSON* cost = cJSON_GetObjectItem(usage, "cost");
  if (cJSON_IsNumber(cost)) {
    s->cost = cost->valuedouble;
    s->has_cost = 1;
  }
}

// Adds one streamed piece of a tool call.
static void ReadToolCall(Stream* s, cJSON* call, int position) {
  int i = (int)JsonNum(call, "index", position);
  if (i < 0 || i >= ARX_MAX_TOOL_CALLS) return;
  if (i >= s->call_count) s->call_count = i + 1;
  ToolCallParts* p = &s->calls[i];
  const char* id = JsonStr(call, "id", NULL);
  if (id && *id && !p->id.len) BufferAppendStr(&p->id, id);
  // A name equal to what we have is a resend; anything else is a fragment.
  const char* name = JsonStr(call, "function.name", NULL);
  if (name && *name && (!p->name.len || strcmp(p->name.data, name))) {
    BufferAppendStr(&p->name, name);
  }
  const char* args = JsonStr(call, "function.arguments", NULL);
  if (args) BufferAppendStr(&p->args, args);
}

// Reads a delta (or a whole message) from a choice.
static void ReadDelta(Stream* s, cJSON* delta) {
  const char* content = JsonStr(delta, "content", NULL);
  if (content && *content) {
    BufferAppendStr(&s->text, content);
    if (s->show) EventDelta(content, strlen(content));
  }
  cJSON* call;
  int position = 0;
  cJSON_ArrayForEach(call, cJSON_GetObjectItem(delta, "tool_calls")) {
    ReadToolCall(s, call, position++);
  }
}

// Handles one parsed chunk (or a whole non-streamed reply).
static void ReadChunk(Stream* s, cJSON* chunk) {
  cJSON* error = cJSON_GetObjectItem(chunk, "error");
  if (error) {
    free(s->error);
    s->error = XStrdup(JsonStr(error, "message", "error in the stream"));
  }
  ReadUsage(s, cJSON_GetObjectItem(chunk, "usage"));
  cJSON* choice = cJSON_GetArrayItem(cJSON_GetObjectItem(chunk, "choices"), 0);
  if (!choice) return;
  cJSON* delta = cJSON_GetObjectItem(choice, "delta");
  ReadDelta(s, delta ? delta : cJSON_GetObjectItem(choice, "message"));
  const char* finish = JsonStr(choice, "finish_reason", NULL);
  if (finish) {
    free(s->finish);
    s->finish = XStrdup(finish);
  }
}

// Handles one complete line of the body.
static void ReadLine(Stream* s, const char* line) {
  if (!*line || line[0] == ':') return;  // event boundary or comment
  if (!strncmp(line, "data:", 5)) {
    const char* data = line + 5 + (line[5] == ' ');
    if (!strcmp(data, "[DONE]")) {
      s->done = 1;
      return;
    }
    cJSON* chunk = cJSON_Parse(data);
    if (!chunk) return;
    s->chunks++;
    ReadChunk(s, chunk);
    cJSON_Delete(chunk);
  } else if (strncmp(line, "event:", 6) && strncmp(line, "id:", 3) &&
             strncmp(line, "retry:", 6) && s->raw.len < kMaxRawBytes) {
    BufferAppendStr(&s->raw, line);
    BufferAppendStr(&s->raw, "\n");
  }
}

// Splits the incoming bytes into lines.
void StreamFeed(void* ctx, const char* data, size_t n) {
  Stream* s = ctx;
  BufferAppend(&s->line, data, n);
  char* nl;
  while (s->line.len && (nl = memchr(s->line.data, '\n', s->line.len))) {
    size_t len = (size_t)(nl - s->line.data);
    *nl = 0;
    if (len && s->line.data[len - 1] == '\r') s->line.data[len - 1] = 0;
    ReadLine(s, s->line.data);
    memmove(s->line.data, nl + 1, s->line.len - len - 1);
    s->line.len -= len + 1;
    s->line.data[s->line.len] = 0;
  }
}

// A non-streamed reply arrives as one JSON body with "choices".
void StreamFinish(Stream* s) {
  if (s->line.len) {
    char* last = XStrdup(s->line.data);
    s->line.len = 0;
    ReadLine(s, last);
    free(last);
  }
  if (s->chunks || !s->raw.len) return;
  cJSON* body = cJSON_Parse(s->raw.data);
  if (cJSON_GetObjectItem(body, "choices")) {
    ReadChunk(s, body);
    s->done = 1;
  }
  cJSON_Delete(body);
}

// Finished normally.
int StreamComplete(const Stream* s) { return s->done || s->finish; }

// Builds the assistant message; content is null when only tools are called.
cJSON* StreamMessage(const Stream* s, int turn) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "role", "assistant");
  cJSON* calls = cJSON_CreateArray();
  for (int i = 0; i < s->call_count; i++) {
    const ToolCallParts* p = &s->calls[i];
    if (!p->name.len) continue;
    char* id =
        p->id.len ? XStrdup(p->id.data) : XAsprintf("call_%d_%d", turn, i);
    cJSON* call = cJSON_CreateObject();
    cJSON_AddStringToObject(call, "id", id);
    cJSON_AddStringToObject(call, "type", "function");
    cJSON* fn = cJSON_AddObjectToObject(call, "function");
    cJSON_AddStringToObject(fn, "name", p->name.data);
    cJSON_AddStringToObject(fn, "arguments", p->args.len ? p->args.data : "{}");
    cJSON_AddItemToArray(calls, call);
    free(id);
  }
  int has_calls = cJSON_GetArraySize(calls) > 0;
  if (has_calls && !s->text.len) {
    cJSON_AddNullToObject(m, "content");
  } else {
    cJSON_AddStringToObject(m, "content", s->text.len ? s->text.data : "");
  }
  if (has_calls) {
    cJSON_AddItemToObject(m, "tool_calls", calls);
  } else {
    cJSON_Delete(calls);
  }
  return m;
}

// Pulls "error.message" (or "message") out of a JSON error body.
char* StreamErrorText(const Stream* s) {
  if (s->error) return XStrdup(s->error);
  if (!s->raw.len) return XStrdup("(empty response)");
  cJSON* body = cJSON_Parse(s->raw.data);
  const char* message = JsonStr(body, "error.message", NULL);
  if (!message) message = JsonStr(body, "message", NULL);
  if (!message) message = JsonStr(body, "error", NULL);
  char* text = Truncate(message ? message : s->raw.data, 500);
  cJSON_Delete(body);
  return text;
}

// Frees every buffer.
void StreamFree(Stream* s) {
  BufferFree(&s->line);
  BufferFree(&s->text);
  BufferFree(&s->raw);
  for (int i = 0; i < ARX_MAX_TOOL_CALLS; i++) {
    BufferFree(&s->calls[i].id);
    BufferFree(&s->calls[i].name);
    BufferFree(&s->calls[i].args);
  }
  free(s->finish);
  free(s->error);
  s->finish = s->error = NULL;
}
