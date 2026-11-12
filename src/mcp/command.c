// command.c: `arx mcp`, a built-in command, since it needs the C client.
//   arx mcp list [--refresh] [--json]   servers, transport, cached tools
//   arx mcp search QUERY [--server S]   mcp_search's ranking, as the model
//                                       sees it
//   arx mcp call SERVER TOOL            one call; JSON arguments on stdin
//   arx mcp http                        the HTTP bridge; arx starts it
// Each takes --spec and --set, as `arx check` does.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

// One server as a JSON object, for `list --json`.
static cJSON* ServerJson(const McpServer* s) {
  cJSON* o = cJSON_CreateObject();
  const char* url = JsonStr(s->entry, "url", NULL);
  Buffer ignored = {0};
  char* expanded = url ? McpExpand(url, &ignored) : NULL;
  cJSON_AddStringToObject(o, "name", s->name);
  cJSON_AddStringToObject(o, "transport", url ? "http" : "stdio");
  if (url) cJSON_AddStringToObject(o, "url", expanded ? expanded : url);
  if (!url) {
    cJSON_AddStringToObject(o, "command", JsonStr(s->entry, "command", ""));
  }
  const char* credential = JsonStr(s->entry, "credential", NULL);
  if (credential) cJSON_AddStringToObject(o, "credential", credential);
  if (s->cache) {
    cJSON_AddNumberToObject(o, "tools", s->tool_count);
    cJSON_AddStringToObject(o, "era", JsonStr(s->cache, "era", ""));
    cJSON_AddStringToObject(o, "version", JsonStr(s->cache, "version", ""));
    cJSON_AddNumberToObject(
        o, "age", (double)time(NULL) - JsonNum(s->cache, "listed_at", 0));
  }
  if (s->error) cJSON_AddStringToObject(o, "error", s->error);
  if (s->error && s->log) cJSON_AddStringToObject(o, "log", s->log);
  free(expanded);
  BufferFree(&ignored);
  return o;
}

// `arx mcp list`: one line per server, or JSON. With `refresh` each server
// starts and lists again. Returns kExitError when one failed.
static int List(Agent* a, int refresh, int json) {
  cJSON* all = cJSON_CreateArray();
  int failed = 0;
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    if (refresh) McpServerWait(a, s);
    failed += s->error != NULL;
    cJSON* o = ServerJson(s);
    cJSON_AddItemToArray(all, o);
    if (json) continue;
    printf("%s\t%s\t", s->name, JsonStr(o, "transport", ""));
    if (s->error) {
      printf("failed: %s (log: %s)\n", s->error, s->log ? s->log : "none");
    } else if (s->cache) {
      printf("%d tools\t%s\tlisted %.0f min ago\n", s->tool_count,
             JsonStr(o, "era", ""), JsonNum(o, "age", 0) / 60);
    } else {
      printf("not listed\n");
    }
  }
  if (json) {
    char* text = cJSON_Print(all);
    puts(text);
    free(text);
  }
  cJSON_Delete(all);
  return failed ? kExitError : kExitDone;
}

// Runs one call to the end and prints its text. Returns an ExitCode.
static int RunCall(Agent* a, const Tool* tool, cJSON* args) {
  MakeDirs(".arx/mcp");
  McpCall* call = McpCallStart(a, tool, args, "cli", ".arx/mcp/call.out");
  while (!McpCallDone(call)) {
    ProcPoll(NULL, 0, 0.05);
    McpPump(a);
  }
  int is_error = 0;
  double secs = 0;
  char* text = McpCallFinish(call, &is_error, &secs);
  size_t n = strlen(text);
  printf("%s%s", text, n && text[n - 1] == '\n' ? "" : "\n");
  free(text);
  return is_error ? kExitError : kExitDone;
}

// `arx mcp call SERVER TOOL`: TOOL is the server's own name for it.
static int CallTool(Agent* a, const char* server, const char* name) {
  McpServer* s = McpServerFind(server);
  if (!s) return UsageError("no such server in mcp_servers", server);
  if (!McpServerWait(a, s)) {
    fprintf(stderr, "arx: the MCP server %s failed: %s\n", server,
            s->error ? s->error : "interrupted");
    return kExitError;
  }
  const char* model_name = NULL;
  for (int t = 0; t < s->tool_count && !model_name; t++) {
    if (!strcmp(JsonStr(s->tools[t].def, "name", ""), name)) {
      model_name = s->tools[t].name;
    }
  }
  if (!model_name) return UsageError("the server has no tool called", name);
  char* text = ReadStdin();
  cJSON* args = cJSON_Parse(*text ? text : "{}");
  free(text);
  if (!cJSON_IsObject(args)) {
    cJSON_Delete(args);
    return UsageError("the arguments on stdin are not a JSON object", NULL);
  }
  const Tool* tool = ToolFind(a, model_name);
  int code = tool ? RunCall(a, tool, args) : kExitError;
  cJSON_Delete(args);
  return code;
}

// `arx mcp`; see mcp.h.
int McpCommand(int argc, char** argv, struct Agent* a) {
  const char* words[3] = {NULL, NULL, NULL};
  const char* server = NULL;
  int refresh = 0, json = 0, n = 0;
  for (int i = 2; i < argc; i++) {
    const char* value = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(argv[i], "--refresh")) {
      refresh = 1;
    } else if (!strcmp(argv[i], "--json")) {
      json = 1;
    } else if (value && !strcmp(argv[i], "--server")) {
      server = argv[++i];
    } else if (value && !strcmp(argv[i], "--spec")) {
      a->spec_path = argv[++i];
    } else if (value && !strcmp(argv[i], "--set")) {
      if (SpecAddSet(a->sets, argv[++i])) return UsageError("bad --set", value);
    } else if (argv[i][0] != '-' && n < 3) {
      words[n++] = argv[i];
    } else {
      return UsageError("unknown mcp argument", argv[i]);
    }
  }
  const char* verb = words[0] ? words[0] : "";
  if (!strcmp(verb, "http")) return McpHttpMain();
  int known = !strcmp(verb, "list") || (!strcmp(verb, "search") && n == 2) ||
              (!strcmp(verb, "call") && n == 3);
  if (!known) {
    return UsageError(
        "usage: arx mcp list [--refresh] [--json] | search "
        "QUERY [--server S] | call SERVER TOOL | http",
        NULL);
  }
  Buffer err = {0};
  ResolveSpec(a);
  if (SpecLoad(a->spec_path, a->sets, &a->spec, &err)) {
    fputs(err.data, stderr);
    BufferFree(&err);
    return kExitUsage;
  }
  ToolsBuild(a);
  McpSync(a);
  int code = kExitDone;
  if (*verb == 'l') {
    code = List(a, refresh, json);
  } else if (*verb == 's') {
    cJSON* args = cJSON_CreateObject();
    cJSON_AddStringToObject(args, "query", words[1]);
    if (server) cJSON_AddStringToObject(args, "server", server);
    const Tool* tool = ToolFind(a, "mcp_search");
    code = tool ? RunCall(a, tool, args) : kExitError;
    if (!tool) fprintf(stderr, "arx: the spec has no mcp_servers\n");
    cJSON_Delete(args);
  } else {
    code = CallTool(a, words[1], words[2]);
  }
  McpShutdown();
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  BufferFree(&err);
  return code;
}
