// commands.c: the built-in commands. One table drives both dispatch and
// `arx help`; everything else is an external `arx-*` command.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/model/model.h"

// Loads the spec for a command; prints problems. Returns 0 or kExitUsage.
static int LoadSpec(Agent* a) {
  Buffer err = {0};
  ResolveSpec(a);
  int failed = SpecLoad(a->spec_path, a->sets, &a->spec, &err);
  if (failed) fputs(err.data, stderr);
  BufferFree(&err);
  return failed ? kExitUsage : 0;
}

// Prints the hooks found next to the spec.
static void PrintHooks(Agent* a) {
  printf("\nhooks:");
  for (const char* const* p = kHookPoints; *p; p++) {
    Buffer from = {0};
    int found = 0;
    for (int l = 0; l < a->spec.layer_count; l++) {
      const Layer* layer = &a->spec.layers[l];
      char* path = XAsprintf("%s/hooks/%s", layer->dir, *p);
      if (!access(path, X_OK)) {
        found = 1;
        if (layer->plugin) {
          BufferPrintf(&from, "%s%s", from.len ? "," : "", layer->plugin);
        }
      }
      free(path);
    }
    if (found) printf(" %s", *p);
    if (from.len) printf("(%s)", from.data);
    BufferFree(&from);
  }
  printf("\n");
}

// Prints the plugins in use, if there are any.
static void PrintPlugins(Agent* a) {
  int any = 0;
  for (int l = 0; l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    if (!layer->plugin) continue;
    printf("%s%s", any ? " " : "plugins: ", layer->plugin);
    any = 1;
  }
  if (any) printf("\n");
}

// `arx check --plugin DIR`: checks a plugin without loading it, and prints
// key=value lines for scripts such as `arx plugin`.
static int CheckPlugin(const char* dir) {
  Buffer out = {0}, err = {0};
  int rc = PluginDescribe(dir, &out, &err);
  fputs(rc ? err.data : out.data, rc ? stderr : stdout);
  BufferFree(&out);
  BufferFree(&err);
  return rc ? kExitUsage : kExitDone;
}

// `arx check` and `arx tools`: load the harness without starting a session.
static int CheckOrTools(int argc, char** argv, Agent* a) {
  if (argc == 4 && argv[1][0] == 'c' && !strcmp(argv[2], "--plugin")) {
    return CheckPlugin(argv[3]);
  }
  int code = ParseOptions(argc, argv, 2, a);
  if (code || (code = LoadSpec(a))) return code;
  ToolsBuild(a);
  if (argv[1][0] == 't') {
    cJSON* tools = ToolsJson(&a->tools);
    char* text = cJSON_Print(tools);
    puts(text);
    free(text);
    cJSON_Delete(tools);
  } else {
    printf("ok: %s%s%s (model %s at %s)\ntools:", a->spec.path,
           a->spec.config && strcmp(a->spec.config, a->spec.path) ? " + " : "",
           a->spec.config && strcmp(a->spec.config, a->spec.path)
               ? a->spec.config
               : "",
           JsonStr(a->spec.root, "model", ""),
           JsonStr(a->spec.root, "endpoint.base_url", ""));
    for (int i = 0; i < a->tools.count; i++) {
      printf(" %s", a->tools.items[i].name);
    }
    PrintHooks(a);
    PrintPlugins(a);
    if (a->notes.len) printf("problems:\n%s", a->notes.data);
  }
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  return kExitDone;
}

// `arx schema`.
static int SchemaCommand(int argc, char** argv, Agent* a) {
  (void)argc;
  (void)argv;
  (void)a;
  Buffer out = {0};
  SpecSchema(&out);
  fputs(out.data, stdout);
  BufferFree(&out);
  return kExitDone;
}

// `arx version`.
static int VersionCommand(int argc, char** argv, Agent* a) {
  (void)argc;
  (void)argv;
  (void)a;
  puts("arx " ARX_VERSION);
  return kExitDone;
}

// `arx watch [ID|last] [--json] [--from start|now]`.
static int WatchCommand(int argc, char** argv, Agent* a) {
  (void)a;
  const char* ref = "last";
  int json = 0, from_start = 1;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--json")) {
      json = 1;
    } else if (!strcmp(argv[i], "--from") && i + 1 < argc) {
      from_start = strcmp(argv[++i], "now") != 0;
    } else {
      ref = argv[i];
    }
  }
  return WatchMain(ref, json, from_start);
}

// `arx ctl ID|last stop|note TEXT`: appends a command to the inbox.
static int CtlCommand(int argc, char** argv, Agent* a) {
  (void)a;
  if (argc < 4) return UsageError("ctl needs a session and a command", NULL);
  int note = !strcmp(argv[3], "note");
  if (!note && strcmp(argv[3], "stop")) {
    return UsageError("unknown ctl command", argv[3]);
  }
  if (note && argc < 5) return UsageError("ctl note needs text", NULL);
  char* dir = SessionDir(argv[2]);
  if (!dir) return UsageError("no such session", argv[2]);
  cJSON* c = cJSON_CreateObject();
  cJSON_AddStringToObject(c, "cmd", argv[3]);
  if (note) cJSON_AddStringToObject(c, "text", argv[4]);
  char* line = cJSON_PrintUnformatted(c);
  char* path = XAsprintf("%s/inbox", dir);
  char* text = XAsprintf("%s\n", line);
  int failed = AppendFile(path, text, strlen(text));
  free(text);
  free(path);
  free(line);
  free(dir);
  cJSON_Delete(c);
  return failed ? kExitError : kExitDone;
}

// DataFn that copies a response body to stdout.
static void StdoutSink(void* ctx, const char* data, size_t n) {
  (void)ctx;
  fwrite(data, 1, n, stdout);
}

// One authenticated call to the endpoint; prints the body.
static int Request(cJSON* root, const char* method, char* body,
                   const char* path) {
  const char* tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
  char* headers = WriteRequestHeaders(root, tmp, 0);
  char* header_arg = XAsprintf("@%s", headers);
  char* response = XAsprintf("%s/.arx-response-%d", tmp, (int)getpid());
  char* url = EndpointUrl(root, path);
  char* argv[16] = {(char*)CurlPath(root),
                    "-sS",
                    "--max-time",
                    "60",
                    "-D",
                    response,
                    "-H",
                    header_arg};
  int k = 8;
  if (method) {
    argv[k++] = "-X";
    argv[k++] = (char*)method;
  }
  if (body) {
    argv[k++] = "--data-binary";
    argv[k++] = "4597";
  }
  argv[k++] = url;
  Proc p = {.argv = argv,
            .in = body,
            .in_len = body ? strlen(body) : 0,
            .timeout = 90,
            .on_out = StdoutSink};
  ProcResult r;
  ProcRun(&p, &r);
  fflush(stdout);
  int status;
  double retry_after;
  ReadResponseHeaders(response, &status, &retry_after);
  unlink(headers);
  unlink(response);
  free(headers);
  free(header_arg);
  free(response);
  free(url);
  if (r.code) fprintf(stderr, "arx: curl exited with %d\n", r.code);
  if (r.code || status < 200 || status >= 300) {
    return status == 401 || status == 403 ? kExitAuth : kExitError;
  }
  return kExitDone;
}

// `arx request [-X METHOD] [--data JSON|-] [--auth-source] PATH`.
static int RequestCommand(int argc, char** argv, Agent* a) {
  const char *method = NULL, *data = NULL, *path = NULL;
  int auth_source = 0;
  for (int i = 2; i < argc; i++) {
    const char* value = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(argv[i], "--auth-source")) {
      auth_source = 1;
    } else if (value && !strcmp(argv[i], "-X")) {
      method = argv[++i];
    } else if (value && !strcmp(argv[i], "--data")) {
      data = argv[++i];
    } else if (value && !strcmp(argv[i], "--spec")) {
      a->spec_path = argv[++i];
    } else if (value && !strcmp(argv[i], "--set")) {
      if (SpecAddSet(a->sets, argv[++i])) return UsageError("bad --set", value);
    } else if (argv[i][0] != '-' && !path) {
      path = argv[i];
    } else {
      return UsageError("unknown request argument", argv[i]);
    }
  }
  int code = LoadSpec(a);
  if (code) return code;
  if (auth_source) {
    const char* key = ApiKey(a->spec.root);
    puts(key ? ApiKeySource() : "no key found");
    code = key ? kExitDone : kExitAuth;
  } else if (!path) {
    code = UsageError("request needs a path such as /models", NULL);
  } else {
    char* body = !data                ? NULL
                 : !strcmp(data, "-") ? ReadStdin()
                                      : XStrdup(data);
    code = Request(a->spec.root, method, body, path);
    free(body);
  }
  SpecFree(&a->spec);
  return code;
}

const Command kCommands[] = {
    {"check", "[--spec P] | --plugin DIR",
     "validate the spec, tools and hooks, or one plugin", CheckOrTools},
    {"tools", "[--spec P]", "print the tools as the model sees them",
     CheckOrTools},
    {"schema", "", "print the JSON Schema of agent.yaml", SchemaCommand},
    {"watch", "[ID|last] [--json] [--from start|now]",
     "follow a session's events", WatchCommand},
    {"ctl", "ID|last stop|note TEXT", "steer a running session", CtlCommand},
    {"request", "[-X METHOD] [--data JSON|-] [--auth-source] PATH",
     "call your endpoint with your key, e.g. /models", RequestCommand},
    {"version", "", "print the version", VersionCommand},
    {"help", "[COMMAND]", "everything, or one command", HelpCommand},
    {NULL, NULL, NULL, NULL}};

// Finds and runs a built-in; see cli.h.
int RunBuiltin(const char* name, int argc, char** argv, Agent* a) {
  for (const Command* c = kCommands; c->name; c++) {
    if (strcmp(c->name, name)) continue;
    if (argc > 2 && (!strcmp(argv[2], "--help") || !strcmp(argv[2], "-h"))) {
      printf("usage: arx %s %s\n  %s\n", c->name, c->args, c->summary);
      return kExitDone;
    }
    return c->run(argc, argv, a);
  }
  return -1;
}
