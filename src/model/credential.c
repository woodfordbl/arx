// credential.c: the programs an endpoint can name. A credential program
// (endpoint.credential) prints the headers and base URL for model calls, so
// a key can come from a password manager or a sign-in that expires. arx
// runs it before the first call, again shortly before its value expires,
// and once more when the endpoint rejects the value. The value stays in
// this process's memory and reaches curl only in the 0600 header file. An
// adapter (endpoint.adapter) is a program that arx puts in front of the
// curl command line, to translate the request and the reply.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "src/base/base.h"
#include "src/io/io.h"
#include "src/model/model.h"

// Seconds before expires_at when arx asks for a new value, so that no call
// starts with a value that runs out while it streams.
#define CREDENTIAL_MARGIN 60

// The exit code that asks arx to try again later (EX_TEMPFAIL).
#define CREDENTIAL_TEMPFAIL 75

static char* g_path;      // the program the cached value came from
static cJSON* g_value;    // its last output
static double g_expires;  // its expires_at, or 0 when it gave none

// Unix seconds. expires_at is wall-clock time, unlike Now().
static double WallNow(void) { return (double)time(NULL); }

// Finds the program endpoint.<key> names; see model.h.
char* EndpointProgram(cJSON* root, const char* spec_dir, const char* key) {
  char dotted[32], map[32];
  snprintf(dotted, sizeof(dotted), "endpoint.%s", key);
  snprintf(map, sizeof(map), "%ss", key);  // credentials, adapters
  const char* name = JsonStr(root, dotted, NULL);
  if (!name || !*name) return NULL;
  cJSON* named = cJSON_GetObjectItemCaseSensitive(JsonGet(root, map), name);
  return PathJoin(spec_dir, cJSON_IsString(named) ? named->valuestring : name);
}

// The cached value, while the spec names a credential program.
cJSON* CredentialValue(cJSON* root) {
  return JsonStr(root, "endpoint.credential", NULL) ? g_value : NULL;
}

// True when `s` would break a header line.
static int BadText(const char* s) { return strpbrk(s, "\r\n") != NULL; }

// Returns why a program's output cannot be used, or NULL when it can.
static const char* BadValue(cJSON* v) {
  if (!cJSON_IsObject(v)) return "it did not print a JSON object";
  cJSON* headers = cJSON_GetObjectItemCaseSensitive(v, "headers");
  if (headers && !cJSON_IsObject(headers)) return "headers must be an object";
  cJSON* h;
  cJSON_ArrayForEach(h, headers) {
    if (!cJSON_IsString(h) || BadText(h->valuestring) || !*h->string ||
        strpbrk(h->string, "\r\n: ")) {
      return "each header must be a name and a one-line string";
    }
  }
  const char* strings[] = {"api_key", "base_url"};
  for (int i = 0; i < 2; i++) {
    cJSON* s = cJSON_GetObjectItemCaseSensitive(v, strings[i]);
    if (s && (!cJSON_IsString(s) || BadText(s->valuestring))) {
      return i ? "base_url must be a one-line string"
               : "api_key must be a one-line string";
    }
  }
  cJSON* expires = cJSON_GetObjectItemCaseSensitive(v, "expires_at");
  if (expires && !cJSON_IsNumber(expires)) {
    return "expires_at must be a number (Unix seconds)";
  }
  return NULL;
}

// Why the program needs to run now, or NULL when the cached value will do.
static const char* Reason(const char* path, int rejected) {
  if (rejected) return "rejected";
  if (!g_value || strcmp(g_path, path)) return "start";
  if (g_expires > 0 && WallNow() >= g_expires - CREDENTIAL_MARGIN) {
    return "expired";
  }
  return NULL;
}

// Keeps a program's checked output as the cached value.
static void Keep(const char* path, cJSON* value) {
  free(g_path);
  cJSON_Delete(g_value);
  g_path = XStrdup(path);
  g_value = value;
  g_expires = JsonNum(value, "expires_at", 0);
}

// Sends the model.credential event for one run of the program.
static void Announce(const char* path, const char* reason, double secs,
                     const char* error) {
  const char* slash = strrchr(path, '/');
  cJSON* e = EventNew("model.credential");
  cJSON_AddStringToObject(e, "program", slash ? slash + 1 : path);
  cJSON_AddStringToObject(e, "reason", reason);
  cJSON_AddNumberToObject(e, "secs", secs);
  if (!error && g_expires > 0) {
    cJSON_AddNumberToObject(e, "expires_in", g_expires - WallNow());
  }
  if (error) JsonAddTruncated(e, "error", error, 300);
  EventSend(e);
}

// Runs the program and classifies the run; writes the reason to `why`.
static CredentialStatus RunProgram(cJSON* root, const char* path,
                                   const char* reason, Buffer* why) {
  cJSON* in = cJSON_CreateObject();
  cJSON_AddStringToObject(in, "reason", reason);
  cJSON_AddStringToObject(in, "model", JsonStr(root, "model", ""));
  cJSON_AddStringToObject(in, "base_url",
                          JsonStr(root, "endpoint.base_url", ""));
  char* json = cJSON_PrintUnformatted(in);
  char* text = XAsprintf("%s\n", json);  // one line, for `read` in sh
  free(json);
  cJSON_Delete(in);
  Buffer out = {0}, err = {0};
  char* argv[] = {(char*)path, NULL};
  Proc p = {.argv = argv,
            .in = text,
            .in_len = strlen(text),
            .timeout = 60,
            .on_out = BufferSink,
            .out_ctx = &out,
            .on_err = BufferSink,
            .err_ctx = &err};
  ProcResult r;
  int started = ProcRun(&p, &r) == 0;
  CredentialStatus status = kCredentialFailed;
  char* stderr_text = Truncate(err.data ? err.data : "", 300);
  if (!started) {
    BufferPrintf(why, "cannot run the credential program %s", path);
  } else if (r.interrupted || r.timed_out || r.code == CREDENTIAL_TEMPFAIL) {
    status = kCredentialRetry;
    BufferPrintf(why, "the credential program %s",
                 r.code == CREDENTIAL_TEMPFAIL ? "asked to try again later"
                                               : "did not finish");
    if (*stderr_text) BufferPrintf(why, ": %s", stderr_text);
  } else if (r.code) {
    BufferPrintf(why, "the credential program failed (exit %d)", r.code);
    if (*stderr_text) BufferPrintf(why, ": %s", stderr_text);
  } else {
    cJSON* value = cJSON_Parse(out.data ? out.data : "");
    const char* bad = BadValue(value);
    if (bad) {
      BufferPrintf(why, "the credential program's output is not usable: %s",
                   bad);
      cJSON_Delete(value);
    } else {
      Keep(path, value);
      status = kCredentialOk;
    }
  }
  Announce(path, reason, started ? r.secs : 0,
           status == kCredentialOk ? NULL : why->data);
  free(stderr_text);
  free(text);
  BufferFree(&out);
  BufferFree(&err);
  return status;
}

// Runs endpoint.credential when its value is missing or stale; see model.h.
CredentialStatus CredentialEnsure(cJSON* root, const char* spec_dir,
                                  int rejected, Buffer* err) {
  char* path = EndpointProgram(root, spec_dir, "credential");
  if (!path) return kCredentialOk;
  const char* reason = Reason(path, rejected);
  CredentialStatus status =
      reason ? RunProgram(root, path, reason, err) : kCredentialOk;
  free(path);
  return status;
}
