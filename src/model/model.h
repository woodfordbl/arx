// model.h: the model client.
//   llm.c  one OpenAI-compatible Chat Completions request per call, sent by
//          running curl (so the binary carries no TLS code), retried on
//          transient errors
//   sse.c  parses the streamed reply (server-sent events) into one assistant
//          message, tolerating provider differences; also accepts a reply
//          that was not streamed

#ifndef SRC_MODEL_MODEL_H_
#define SRC_MODEL_MODEL_H_

#include <stddef.h>
#include <stdint.h>

#include "vendor/cjson/cJSON.h"

#include "src/base/base.h"

// Defined in agent.h.
struct Agent;

// ---- llm.c ----

// How a model call ended.
typedef enum LlmStatus {
  kLlmOk,
  kLlmFatal,        // a request error that retrying will not fix
  kLlmAuth,         // 401 or 403
  kLlmContext,      // the prompt is too long for the model
  kLlmInterrupted,  // Ctrl-C
} LlmStatus;

// A model reply.
typedef struct Reply {
  cJSON* message;  // the assistant message; the caller owns it
  int64_t tokens_in;
  int64_t tokens_out;
  double cost;  // from the provider, else from the spec's prices
} Reply;

// Sends `messages` and `tools` (NULL or empty for none) to the model in the
// spec. Fields whose names start with "_" are stripped from messages first.
// With `show` set, text is streamed to the terminal and event stream as it
// arrives. Retries 429, 5xx, timeouts and network errors with backoff
// (honoring Retry-After), emitting a model.retry event each time. On
// failure, appends the reason to `err`.
LlmStatus LlmChat(struct Agent* a, cJSON* messages, cJSON* tools, int show,
                  Reply* reply, Buffer* err);

// ---- sse.c (used by llm.c) ----

// The most tool calls one reply can carry.
#define ARX_MAX_TOOL_CALLS 64

// One tool call, assembled from streamed pieces.
typedef struct ToolCallParts {
  Buffer id;
  Buffer name;
  Buffer args;
} ToolCallParts;

// The state of one streamed reply.
typedef struct Stream {
  int show;     // stream the text to the terminal and event stream
  Buffer line;  // a line that has not ended yet
  Buffer text;  // assistant text so far
  ToolCallParts calls[ARX_MAX_TOOL_CALLS];
  int call_count;
  Buffer raw;         // body lines that are not SSE (an error, or JSON)
  int chunks;         // SSE data chunks parsed
  int done;           // saw "data: [DONE]"
  char* finish;       // finish_reason, or NULL
  char* error;        // an error object sent inside the stream, or NULL
  int64_t tokens_in;  // usage.prompt_tokens
  int64_t tokens_out;
  double cost;  // usage.cost, when the provider sends it
  int has_cost;
} Stream;

// A DataFn that feeds curl's stdout into the Stream in `ctx`.
void StreamFeed(void* ctx, const char* data, size_t n);

// Call once the body has ended: handles a last line without a newline and a
// reply that was not streamed.
void StreamFinish(Stream* s);

// True when the reply finished normally (a finish_reason or [DONE]).
int StreamComplete(const Stream* s);

// Returns the assistant message in Chat Completions format. Tool calls with
// no id get "call_<turn>_<index>".
cJSON* StreamMessage(const Stream* s, int turn);

// Returns a short error message from a non-SSE body (malloc'd).
char* StreamErrorText(const Stream* s);

// Frees everything the Stream holds.
void StreamFree(Stream* s);

#endif  // SRC_MODEL_MODEL_H_
