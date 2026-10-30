// auth.c: the endpoint's credentials, and the request plumbing that every
// call to it shares. The API key is found the way fx finds it: an
// environment variable first, then a key saved by `arx setup` in the macOS
// Keychain (service "arx") or, elsewhere, in ConfigDir()/credentials (0600).
// The key reaches curl in a 0600 header file, never on a command line, so it
// never shows up in process listings.

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/model/model.h"

// The last key looked up, so the Keychain is asked at most once per run.
static char* g_key_name;
static char* g_key_value;
static const char* g_key_source;

// Removes trailing whitespace in place.
static void TrimEnd(char* s) {
  size_t n = strlen(s);
  while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ')) {
    s[--n] = 0;
  }
}

// Reads `name` from the macOS Keychain (service "arx"), or returns NULL.
static char* KeychainKey(const char* name) {
#ifdef __APPLE__
  if (getenv("ARX_DISABLE_KEYCHAIN")) return NULL;
  Buffer out = {0}, err = {0};
  char* argv[] = {
      "security", "find-generic-password", "-s", "arx", "-a", (char*)name, "-w",
      NULL};
  Proc p = {.argv = argv,
            .timeout = 10,
            .on_out = BufferSink,
            .out_ctx = &out,
            .on_err = BufferSink,
            .err_ctx = &err};
  ProcResult r;
  char* key = NULL;
  if (ProcRun(&p, &r) == 0 && r.code == 0 && out.len) {
    TrimEnd(out.data);
    key = BufferTake(&out);
  }
  BufferFree(&out);
  BufferFree(&err);
  return key;
#else
  (void)name;
  return NULL;
#endif
}

// Reads `name` from ConfigDir()/credentials ("NAME=value" lines), or NULL.
static char* FileKey(const char* name) {
  char* dir = ConfigDir();
  char* path = XAsprintf("%s/credentials", dir);
  char* text = ReadFile(path, NULL);
  char* key = NULL;
  size_t n = strlen(name);
  for (char* line = text; line && *line && !key;) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    if (!strncmp(line, name, n) && line[n] == '=') {
      key = XStrdup(line + n + 1);
      TrimEnd(key);
    }
    line = nl ? nl + 1 : NULL;
  }
  free(text);
  free(path);
  free(dir);
  return key;
}

// Finds the key in fx's order; see model.h.
const char* ApiKey(cJSON* root) {
  const char* name = JsonStr(root, "endpoint.api_key_env", "OPENAI_API_KEY");
  const char* oidc = getenv("VERCEL_OIDC_TOKEN");
  if (oidc && *oidc &&
      strstr(JsonStr(root, "endpoint.base_url", ""), "ai-gateway.vercel.sh")) {
    g_key_source = "the VERCEL_OIDC_TOKEN environment variable";
    return oidc;
  }
  const char* env = getenv(name);
  if (env && *env) {
    g_key_source = "an environment variable";
    return env;
  }
  if (!g_key_name || strcmp(g_key_name, name)) {
    free(g_key_name);
    free(g_key_value);
    g_key_name = XStrdup(name);
    g_key_value = KeychainKey(name);
    g_key_source = g_key_value ? "the macOS Keychain" : NULL;
    if (!g_key_value) {
      g_key_value = FileKey(name);
      g_key_source = g_key_value ? "the arx credentials file" : NULL;
    }
  }
  return g_key_value;
}

// Where the last ApiKey() call found its key; see model.h.
const char* ApiKeySource(void) { return g_key_source; }

// The endpoint's base_url (without trailing slashes) followed by `path`.
char* EndpointUrl(cJSON* root, const char* path) {
  const char* base = JsonStr(root, "endpoint.base_url", "");
  size_t len = strlen(base);
  while (len && base[len - 1] == '/') len--;
  return XAsprintf("%.*s%s", (int)len, base, path);
}

// The curl to run: endpoint.curl, else $ARX_CURL, else curl.
const char* CurlPath(cJSON* root) {
  const char* env = getenv("ARX_CURL");
  return JsonStr(root, "endpoint.curl", env && *env ? env : "curl");
}

// Writes the request headers to a private file in `dir`; see model.h.
char* WriteRequestHeaders(cJSON* root, const char* dir, int streaming) {
  Buffer h = {0};
  BufferAppendStr(&h, "Content-Type: application/json\n");
  if (streaming) BufferAppendStr(&h, "Accept: text/event-stream\n");
  const char* key = ApiKey(root);
  if (key && *key) BufferPrintf(&h, "Authorization: Bearer %s\n", key);
  cJSON* header;
  cJSON_ArrayForEach(header, JsonGet(root, "endpoint.headers")) {
    if (cJSON_IsString(header)) {
      BufferPrintf(&h, "%s: %s\n", header->string, header->valuestring);
    }
  }
  char* path = XAsprintf("%s/.arx-request-%d", dir, (int)getpid());
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd >= 0) {
    WriteAll(fd, h.data, h.len);
    close(fd);
  }
  BufferFree(&h);
  return path;
}

// Reads the last HTTP status and any Retry-After; see model.h.
void ReadResponseHeaders(const char* path, int* status, double* retry_after) {
  char* text = ReadFile(path, NULL);
  *status = 0;
  *retry_after = -1;
  for (char* line = text; line && *line;) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    if (!strncmp(line, "HTTP/", 5)) {
      const char* space = strchr(line, ' ');
      *status = space ? atoi(space + 1) : 0;
    } else if (!strncasecmp(line, "retry-after:", 12)) {
      char* end;
      double secs = strtod(line + 12, &end);
      if (end != line + 12) *retry_after = secs;
    }
    line = nl ? nl + 1 : NULL;
  }
  free(text);
}
