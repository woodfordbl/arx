// llm.c: builds the request, runs curl, classifies the outcome and retries.
// Credentials and request headers come from auth.c.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/io/io.h"
#include "src/model/model.h"

// What to do after one attempt.
typedef enum Outcome {
  kOutcomeOk,
  kOutcomeRetry,
  kOutcomeAuth,
  kOutcomeContext,
  kOutcomeFatal,
  kOutcomeInterrupted,
} Outcome;

// The request body: messages without "_" fields, tools, streaming options,
// then model_settings on top (a null setting removes the field).
static char* RequestBody(struct Agent* a, cJSON* messages, cJSON* tools) {
  cJSON* body = cJSON_CreateObject();
  cJSON_AddStringToObject(body, "model", JsonStr(a->spec.root, "model", ""));
  cJSON* clean = cJSON_AddArrayToObject(body, "messages");
  for (cJSON* m = messages->child; m; m = m->next) {
    cJSON* copy = cJSON_CreateObject();
    for (cJSON* f = m->child; f; f = f->next) {
      if (f->string[0] != '_') {
        cJSON_AddItemToObject(copy, f->string, cJSON_Duplicate(f, 1));
      }
    }
    cJSON_AddItemToArray(clean, copy);
  }
  if (cJSON_GetArraySize(tools)) {
    cJSON_AddItemToObject(body, "tools", cJSON_Duplicate(tools, 1));
  }
  cJSON_AddTrueToObject(body, "stream");
  cJSON* options = cJSON_AddObjectToObject(body, "stream_options");
  cJSON_AddTrueToObject(options, "include_usage");
  cJSON* setting;
  cJSON_ArrayForEach(setting, JsonGet(a->spec.root, "model_settings")) {
    cJSON_DeleteItemFromObjectCaseSensitive(body, setting->string);
    if (!cJSON_IsNull(setting)) {
      cJSON_AddItemToObject(body, setting->string, cJSON_Duplicate(setting, 1));
    }
  }
  char* text = cJSON_PrintUnformatted(body);
  cJSON_Delete(body);
  return text;
}

// One request: runs curl and parses the streamed reply into `s`.
static void Attempt(struct Agent* a, const char* body, double timeout,
                    Stream* s, ProcResult* r, Buffer* curl_err, int* status,
                    double* retry_after) {
  cJSON* root = a->spec.root;
  char* url = EndpointUrl(root, "/chat/completions");
  char* headers = WriteRequestHeaders(root, a->session.dir, 1);
  char* header_arg = XAsprintf("@%s", headers);
  char* response = XAsprintf("%s/.response-headers", a->session.dir);
  char max_time[32];
  snprintf(max_time, sizeof(max_time), "%.0f", timeout);
  char* argv[] = {(char*)CurlPath(root),
                  "-sS",
                  "-N",
                  "--max-time",
                  max_time,
                  "-D",
                  response,
                  "-H",
                  header_arg,
                  "--data-binary",
                  "@-",
                  url,
                  NULL};
  Proc p = {.argv = argv,
            .in = body,
            .in_len = strlen(body),
            .timeout = timeout + 30,
            .on_out = StreamFeed,
            .out_ctx = s,
            .on_err = BufferSink,
            .err_ctx = curl_err};
  unlink(response);
  ProcRun(&p, r);
  StreamFinish(s);
  ReadResponseHeaders(response, status, retry_after);
  unlink(headers);
  unlink(response);
  free(url);
  free(headers);
  free(header_arg);
  free(response);
}

// curl exit codes worth retrying: DNS, connect, timeouts, dropped
// connections and TLS handshakes.
static int RetryableCurl(int code) {
  static const int kCodes[] = {5, 6, 7, 16, 18, 28, 35, 52, 55, 56, 92};
  for (size_t i = 0; i < sizeof(kCodes) / sizeof(kCodes[0]); i++) {
    if (code == kCodes[i]) return 1;
  }
  return 0;
}

// True when an error message is about the prompt being too long.
static int LooksLikeContext(const char* message) {
  return strcasestr(message, "context") || strcasestr(message, "too long") ||
         strcasestr(message, "maximum") || strcasestr(message, "too many");
}

// Decides what to do with an attempt; writes the reason to `why`.
static Outcome Classify(const ProcResult* r, const Stream* s, int status,
                        const Buffer* curl_err, Buffer* why) {
  if (r->interrupted) return kOutcomeInterrupted;
  if (r->spawn_failed) {
    BufferPrintf(why, "cannot run curl: %s", strerror(errno));
    return kOutcomeFatal;
  }
  if (r->code) {
    BufferPrintf(why, "curl exit %d: %s", r->code,
                 curl_err->data ? curl_err->data : "");
    return RetryableCurl(r->code) ? kOutcomeRetry : kOutcomeFatal;
  }
  if (status == 200 || (status == 0 && s->chunks)) {
    if (s->error) {
      BufferPrintf(why, "error in the stream: %s", s->error);
      return kOutcomeRetry;
    }
    if (StreamComplete(s)) return kOutcomeOk;
    BufferAppendStr(why, "the stream ended before the reply finished");
    return kOutcomeRetry;
  }
  char* message = StreamErrorText(s);
  BufferPrintf(why, "HTTP %d: %s", status, message);
  Outcome o = kOutcomeFatal;
  if (status == 401 || status == 403) {
    o = kOutcomeAuth;
  } else if (status == 429 || status == 408 || status == 409 || status == 425 ||
             status >= 500) {
    o = kOutcomeRetry;
  } else if ((status == 400 || status == 413 || status == 422) &&
             LooksLikeContext(message)) {
    o = kOutcomeContext;
  }
  free(message);
  return o;
}

// Cost from the spec's per-million-token prices.
static double PriceCost(cJSON* root, int64_t in, int64_t out) {
  return JsonNum(root, "prices.input", 0) * (double)in / 1e6 +
         JsonNum(root, "prices.output", 0) * (double)out / 1e6;
}

// Exponential backoff, or Retry-After when the server sent one.
static double RetryWait(cJSON* root, int attempt, double retry_after) {
  double max_wait = JsonDuration(root, "endpoint.retry_max", 300);
  double wait = JsonDuration(root, "endpoint.retry_base", 2);
  if (retry_after >= 0) {
    wait = retry_after;
  } else {
    for (int i = 1; i < attempt && wait < max_wait; i++) wait *= 2;
  }
  return wait < max_wait ? wait : max_wait;
}

// Emits model.retry and waits.
static void AnnounceRetry(int attempt, int status, const ProcResult* r,
                          double wait, const char* why) {
  cJSON* e = EventNew("model.retry");
  cJSON_AddNumberToObject(e, "attempt", attempt);
  cJSON_AddNumberToObject(e, "status", status);
  cJSON_AddNumberToObject(e, "curl_exit", r->code);
  cJSON_AddNumberToObject(e, "wait_s", wait);
  JsonAddTruncated(e, "error", why, 300);
  EventSend(e);
  SleepSeconds(wait);
}

// Maps a final outcome to the caller's status.
static LlmStatus StatusOf(Outcome o) {
  switch (o) {
    case kOutcomeOk:
      return kLlmOk;
    case kOutcomeAuth:
      return kLlmAuth;
    case kOutcomeContext:
      return kLlmContext;
    case kOutcomeInterrupted:
      return kLlmInterrupted;
    default:
      return kLlmFatal;
  }
}

// Sends one model call with retries; see model.h.
LlmStatus LlmChat(struct Agent* a, cJSON* messages, cJSON* tools, int show,
                  Reply* reply, Buffer* err) {
  cJSON* root = a->spec.root;
  int64_t max_attempts = (int64_t)JsonNum(root, "endpoint.retry_attempts", 0);
  double timeout = JsonDuration(root, "limits.turn_timeout", 600);
  if (a->caps.wall > 0) {
    double left = a->caps.wall - (Now() - a->start);
    if (left < timeout) timeout = left > 1 ? left : 1;
  }
  char* body = RequestBody(a, messages, tools);
  memset(reply, 0, sizeof(*reply));
  Outcome o;
  for (int attempt = 1;; attempt++) {
    Stream s = {.show = show};
    ProcResult r;
    Buffer curl_err = {0}, why = {0};
    int status;
    double retry_after;
    Attempt(a, body, timeout, &s, &r, &curl_err, &status, &retry_after);
    o = Classify(&r, &s, status, &curl_err, &why);
    if (o == kOutcomeOk) {
      reply->message = StreamMessage(&s, a->session.turns);
      reply->tokens_in = s.tokens_in;
      reply->tokens_out = s.tokens_out;
      reply->cost =
          s.has_cost ? s.cost : PriceCost(root, s.tokens_in, s.tokens_out);
    } else if (o == kOutcomeRetry && max_attempts && attempt >= max_attempts) {
      BufferPrintf(err, "gave up after %d attempts: %s", attempt, why.data);
      o = kOutcomeFatal;
    } else if (o == kOutcomeRetry) {
      AnnounceRetry(attempt, status, &r, RetryWait(root, attempt, retry_after),
                    why.data);
      if (g_interrupted) o = kOutcomeInterrupted;
    } else {
      BufferAppendStr(err, why.data ? why.data : "");
    }
    StreamFree(&s);
    BufferFree(&curl_err);
    BufferFree(&why);
    if (o != kOutcomeRetry) break;
  }
  free(body);
  return StatusOf(o);
}
