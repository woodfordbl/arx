// launch.c: starts the process of one MCP server. A stdio server is its
// `command`; a `url` server is `arx mcp http`, the bridge, which gets its
// entry in ARX_MCP_SERVER, never on the command line, because headers can
// hold a token and `ps` shows arguments. ${NAME} expands here, at the
// start, so tokens stay out of the spec.

#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"
#include "src/model/model.h"

// Appends a log line; see mcp.h.
void McpLog(const McpServer* s, const char* fmt, ...) {
  if (!s->log) return;
  Buffer b = {0};
  BufferAppendStr(&b, "[arx] ");
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(&b, fmt, ap);
  va_end(ap);
  BufferAppendStr(&b, "\n");
  AppendFile(s->log, b.data, b.len);
  BufferFree(&b);
}

// DataFn: the server's stderr goes to its log.
static void LogSink(void* ctx, const char* data, size_t n) {
  const McpServer* s = ctx;
  if (s->log) AppendFile(s->log, data, n);
}

// Adds "KEY=value" (consumed) to a NULL-terminated array.
static void EnvAdd(char*** env, char* entry) {
  int n = 0;
  while ((*env)[n]) n++;
  *env = XRealloc(*env, (size_t)(n + 2) * sizeof(**env));
  (*env)[n] = entry;
  (*env)[n + 1] = NULL;
}

// The program `credential` names: an entry of `credentials:` or a path.
static char* CredentialPath(const Spec* spec, const char* credential) {
  cJSON* named = cJSON_GetObjectItemCaseSensitive(
      JsonGet(spec->root, "credentials"), credential);
  return PathJoin(spec->dir,
                  cJSON_IsString(named) ? named->valuestring : credential);
}

// Runs a stdio server's credential program and puts its api_key in the
// `api_key_env` variable. Returns 0, or -1 with the reason in `err`.
static int AddCredential(struct Agent* a, McpServer* s, char*** env,
                         Buffer* err) {
  const char* credential = JsonStr(s->entry, "credential", NULL);
  const char* variable = JsonStr(s->entry, "api_key_env", NULL);
  if (!credential) return 0;
  char* path = CredentialPath(&a->spec, credential);
  cJSON* in = cJSON_CreateObject();
  cJSON_AddStringToObject(in, "reason", "start");
  cJSON_AddStringToObject(in, "server", s->name);
  cJSON* value = NULL;
  CredentialStatus status = CredentialRun(path, in, &value, err);
  free(path);
  if (status != kCredentialOk) return -1;
  s->expires = JsonNum(value, "expires_at", 0);
  const char* key = JsonStr(value, "api_key", NULL);
  if (variable && key) EnvAdd(env, XAsprintf("%s=%s", variable, key));
  cJSON_Delete(value);
  return 0;
}

// Expands the string `node` in place. Returns 0, or -1 with `err`.
static int ExpandNode(cJSON* node, Buffer* err) {
  if (!cJSON_IsString(node)) return 0;
  char* text = McpExpand(node->valuestring, err);
  if (!text) return -1;
  cJSON_SetValuestring(node, text);
  free(text);
  return 0;
}

// Returns a copy of the entry with ${NAME} expanded in args, env, url and
// headers, or NULL with the unset variable in `err`.
static cJSON* Expanded(const McpServer* s, Buffer* err) {
  cJSON* e = cJSON_Duplicate(s->entry, 1);
  const char* lists[] = {"args", "env", "headers"};
  int bad = ExpandNode(cJSON_GetObjectItemCaseSensitive(e, "url"), err);
  for (int i = 0; i < 3 && !bad; i++) {
    cJSON* v;
    cJSON_ArrayForEach(v, cJSON_GetObjectItemCaseSensitive(e, lists[i])) {
      if (!bad) bad = ExpandNode(v, err);
    }
  }
  if (!bad) return e;
  cJSON_Delete(e);
  return NULL;
}

// The bridge's ARX_MCP_SERVER entry for a `url` server: its name, URL,
// headers, call timeout and the path of its credential program.
static char* BridgeEntry(struct Agent* a, const McpServer* s, cJSON* e) {
  const char* credential = JsonStr(e, "credential", NULL);
  cJSON* o = cJSON_CreateObject();
  cJSON_AddStringToObject(o, "name", s->name);
  cJSON_AddStringToObject(o, "url", JsonStr(e, "url", ""));
  cJSON* headers = cJSON_GetObjectItemCaseSensitive(e, "headers");
  if (headers) cJSON_AddItemToObject(o, "headers", cJSON_Duplicate(headers, 1));
  cJSON_AddNumberToObject(o, "timeout", JsonDuration(e, "timeout", 120));
  if (credential) {
    char* path = CredentialPath(&a->spec, credential);
    cJSON_AddStringToObject(o, "credential", path);
    free(path);
  }
  if (s->log) cJSON_AddStringToObject(o, "log", s->log);
  char* json = cJSON_PrintUnformatted(o);
  char* entry = XAsprintf("ARX_MCP_SERVER=%s", json);
  free(json);
  cJSON_Delete(o);
  return entry;
}

// Starts the server's process; see mcp.h.
ProcChild* McpLaunch(struct Agent* a, McpServer* s, Buffer* err) {
  cJSON* e = Expanded(s, err);
  if (!e) return NULL;
  free(s->log);
  s->log = a->session.dir ? XAsprintf("%s/mcp/%s.log", a->session.dir, s->name)
                          : XAsprintf(".arx/mcp/%s.log", s->name);
  char* log_dir = DirName(s->log);
  MakeDirs(log_dir);
  free(log_dir);
  const char* command = JsonStr(e, "command", NULL);
  cJSON* args = cJSON_GetObjectItemCaseSensitive(e, "args");
  char** env = ToolEnv(a, NULL, NULL);
  char** argv = XMalloc((size_t)(cJSON_GetArraySize(args) + 4) * sizeof(*argv));
  char* program = command && strchr(command, '/')
                      ? PathJoin(a->spec.dir, command)
                      : XStrdup(command ? command : g_self);
  const char* cwd = JsonStr(e, "cwd", NULL);
  char* dir = cwd ? PathJoin(a->spec.dir, cwd) : NULL;
  int k = 0;
  argv[k++] = program;
  cJSON* v;
  if (command) {
    cJSON_ArrayForEach(v, args) argv[k++] = v->valuestring;
    cJSON_ArrayForEach(v, cJSON_GetObjectItemCaseSensitive(e, "env")) {
      EnvAdd(&env, XAsprintf("%s=%s", v->string, v->valuestring));
    }
  } else {
    argv[k++] = "mcp";
    argv[k++] = "http";
    EnvAdd(&env, BridgeEntry(a, s, e));
  }
  argv[k] = NULL;
  ProcChild* child = NULL;
  s->expires = 0;
  if (!command || AddCredential(a, s, &env, err) == 0) {
    Proc p = {.argv = argv,
              .env = env,
              .open_in = 1,
              .keep_on_interrupt = 1,
              .dir = dir,
              .on_out = LineSink,
              .out_ctx = &s->out,
              .on_err = LogSink,
              .err_ctx = s};
    child = ProcStart(&p);
    if (!child)
      BufferPrintf(err, "cannot start %s: %s", program, strerror(errno));
  }
  free(dir);
  free(program);
  free(argv);
  FreeEnv(env);
  cJSON_Delete(e);
  return child;
}
