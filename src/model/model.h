// model.h: the model client.
//   llm.c  one OpenAI-compatible Chat Completions request per call, sent by
//          running curl (so the binary carries no TLS code), retried on
//          transient errors
//   auth.c credentials (env var, then macOS Keychain or a 0600 file, as fx
//          does) and the request plumbing every call shares
//   credential.c  the programs an endpoint names: a credential program
//          that prints headers and a base URL, and an adapter that wraps
//          the curl command to translate the request and the reply
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

// ---- auth.c ----

// Returns the API key for the spec's endpoint, or NULL, in fx's order: for
// Vercel AI Gateway, VERCEL_OIDC_TOKEN first; then the environment variable
// named by endpoint.api_key_env (default OPENAI_API_KEY); then the key saved
// by `arx setup` under that name, in the macOS Keychain (service "arx") or
// ConfigDir()/credentials. Stored keys are looked up once per process.
const char* ApiKey(cJSON* root);

// Describes where the last ApiKey() call found the key, e.g. "the macOS
// Keychain", without revealing it. NULL if it found none.
const char* ApiKeySource(void);

// Returns the base URL (trailing slashes removed) followed by `path`: the
// credential program's base_url when it gave one, else endpoint.base_url.
char* EndpointUrl(cJSON* root, const char* path);

// Returns the curl to run: endpoint.curl, else $ARX_CURL, else "curl".
const char* CurlPath(cJSON* root);

// Writes request headers, including the key, to a new 0600 file in `dir`
// for `curl -H @file`, and returns its path; delete it after the call.
// `streaming` adds "Accept: text/event-stream". With endpoint.credential,
// the key and headers come from the credential program's last value (see
// CredentialEnsure), never from ApiKey(), and its headers replace
// endpoint.headers of the same name.
char* WriteRequestHeaders(cJSON* root, const char* dir, int streaming);

// Reads the last HTTP status and any Retry-After (seconds, else -1) from a
// headers file written by `curl -D`.
void ReadResponseHeaders(const char* path, int* status, double* retry_after);

// ---- credential.c ----

// How a run of the credential program ended.
typedef enum CredentialStatus {
  kCredentialOk,      // the value is fresh, or the spec names no program
  kCredentialRetry,   // try again later: it exited 75 or did not finish
  kCredentialFailed,  // it failed: the model call stops as a 401 would
} CredentialStatus;

// Returns the program that endpoint.<key> names, for the keys "credential"
// and "adapter": an entry of the top-level map <key>s (credentials,
// adapters), else a path. A relative path is relative to `spec_dir`.
// Returns NULL when endpoint.<key> is not set; free the result.
char* EndpointProgram(cJSON* root, const char* spec_dir, const char* key);

// Makes sure the value of endpoint.credential is fresh. Runs the program
// when no value is cached, when the program changed, when the value's
// expires_at is less than a minute away, or when `rejected` (the endpoint
// answered 401 or 403). The program gets {"reason", "model", "base_url"}
// on stdin and prints {"headers", "api_key", "base_url", "expires_at"}.
// Sends a model.credential event for each run. On failure, appends the
// reason to `err`. Returns kCredentialOk at once without the key.
CredentialStatus CredentialEnsure(cJSON* root, const char* spec_dir,
                                  int rejected, Buffer* err);

// Returns the credential program's last output while the spec names one,
// else NULL. The caller does not own it.
cJSON* CredentialValue(cJSON* root);

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
  double cost;      // from the provider, else from the spec's prices
  char finish[32];  // finish_reason: "stop", "tool_calls", "length", ...
} Reply;

// Sends `messages` and `tools` (NULL or empty for none) to the model in the
// spec. Fields whose names start with "_" are stripped from messages first.
// With `show` set, text is streamed to the terminal and event stream as it
// arrives. Retries 429, 5xx, timeouts and network errors with backoff
// (honoring Retry-After), emitting a model.retry event each time. On
// failure, appends the reason to `err`.
LlmStatus LlmChat(struct Agent* a, cJSON* messages, cJSON* tools, int show,
                  Reply* reply, Buffer* err);

// LlmChat with `model` and `settings` (an object of request fields that
// replace the defaults; a null value removes one; may be NULL) in place of
// the spec's model and model_settings, for a before_model hook's changes.
LlmStatus LlmChatWith(struct Agent* a, const char* model, cJSON* settings,
                      cJSON* messages, cJSON* tools, int show, Reply* reply,
                      Buffer* err);

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
