// commands.c: the built-in commands. One table drives both dispatch and
// `arx help`; everything else is an external `arx-*` command. `arx check`
// and `arx tools` live in check.c.

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

// `arx tool bash|edit [--schema]`: runs a tool of the shell plugin, with
// the arguments as JSON on stdin, or prints its schema.
static int ToolCommand(int argc, char** argv, Agent* a) {
  (void)a;
  const char* schema = argc > 2 ? ShellToolSchema(argv[2]) : NULL;
  if (!schema)
    return UsageError("tool needs bash or edit", argc > 2 ? argv[2] : NULL);
  if (argc > 3 && !strcmp(argv[3], "--schema")) {
    puts(schema);
    return kExitDone;
  }
  if (argc > 3) return UsageError("unknown tool argument", argv[3]);
  char* args = ReadStdin();
  int code = ShellToolRun(argv[2], args);
  free(args);
  return code;
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

// The short id (malloc'd) of the background call `id` (a short id such as
// c7, or the model's id) that meta.json in `dir` lists as in flight. When
// there is none, says which calls are in flight and returns NULL.
static char* CallInFlight(const char* dir, const char* id) {
  char* path = XAsprintf("%s/meta.json", dir);
  char* text = ReadFile(path, NULL);
  cJSON* meta = text ? cJSON_Parse(text) : NULL;
  char* found = NULL;
  Buffer list = {0};
  cJSON* e;
  cJSON_ArrayForEach(e, cJSON_GetObjectItem(meta, "calls")) {
    const char* call = JsonStr(e, "call", "");
    if (!found && (!strcmp(call, id) || !strcmp(JsonStr(e, "id", ""), id))) {
      found = XStrdup(call);
    }
    BufferPrintf(&list, "%s%s", list.len ? ", " : "", call);
  }
  if (!found) {
    fprintf(stderr, "arx: no call %s in flight (in flight: %s)\n", id,
            list.len ? list.data : "none");
  }
  BufferFree(&list);
  cJSON_Delete(meta);
  free(text);
  free(path);
  return found;
}

// `arx ctl ID|last stop | note TEXT | cancel CALL`: appends a command to
// the inbox. cancel first checks that the call is in flight.
static int CtlCommand(int argc, char** argv, Agent* a) {
  (void)a;
  if (argc < 4) return UsageError("ctl needs a session and a command", NULL);
  int note = !strcmp(argv[3], "note"), cancel = !strcmp(argv[3], "cancel");
  if (!note && !cancel && strcmp(argv[3], "stop")) {
    return UsageError("unknown ctl command", argv[3]);
  }
  if (note && argc < 5) return UsageError("ctl note needs text", NULL);
  if (cancel && argc < 5) {
    return UsageError("ctl cancel needs a call id such as c7", NULL);
  }
  char* dir = SessionDir(argv[2]);
  if (!dir) return UsageError("no such session", argv[2]);
  char* call = cancel ? CallInFlight(dir, argv[4]) : NULL;
  if (cancel && !call) {
    free(dir);
    return kExitUsage;
  }
  cJSON* c = cJSON_CreateObject();
  cJSON_AddStringToObject(c, "cmd", argv[3]);
  if (note) cJSON_AddStringToObject(c, "text", argv[4]);
  if (cancel) cJSON_AddStringToObject(c, "call", call);
  free(call);
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

// Runs the credential program, if the spec names one, before a request.
// Returns 0, or kExitAuth after printing why it failed.
static int Credential(const Spec* spec) {
  Buffer err = {0};
  CredentialStatus c = CredentialEnsure(spec->root, spec->dir, 0, &err);
  if (c != kCredentialOk) fprintf(stderr, "arx: %s\n", err.data);
  BufferFree(&err);
  return c == kCredentialOk ? 0 : kExitAuth;
}

// One authenticated call to the endpoint, through its adapter if it has
// one; prints the body.
static int Request(const Spec* spec, const char* method, char* body,
                   const char* path) {
  cJSON* root = spec->root;
  int code = Credential(spec);
  if (code) return code;
  Buffer headers = {0};
  RequestHeaders(root, 0, &headers);
  char* url = EndpointUrl(root, path);
  char* adapter = EndpointProgram(root, spec->dir, "adapter");
  HttpRequest req = {.method = method,
                     .url = url,
                     .headers = headers.data,
                     .body = body,
                     .body_len = body ? strlen(body) : 0,
                     .timeout = 60,
                     .adapter = adapter,
                     .curl = JsonStr(root, "endpoint.curl", NULL),
                     .tmp_dir = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp",
                     .on_body = StdoutSink};
  HttpResult r;
  HttpRun(&req, &r);
  fflush(stdout);
  if (!r.spawn_failed && r.err.len) fputs(r.err.data, stderr);
  if (r.net_error) fprintf(stderr, "arx: curl exited with %d\n", r.net_error);
  int status = r.status;
  BufferFree(&r.err);
  BufferFree(&headers);
  free(adapter);
  free(url);
  if (r.net_error || status < 200 || status >= 300) {
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
  const char* program = JsonStr(a->spec.root, "endpoint.credential", NULL);
  if (auth_source && program) {
    code = Credential(&a->spec);
    if (!code) printf("the credential program %s\n", program);
  } else if (auth_source) {
    const char* key = ApiKey(a->spec.root);
    puts(key ? ApiKeySource() : "no key found");
    code = key ? kExitDone : kExitAuth;
  } else if (!path) {
    code = UsageError("request needs a path such as /models", NULL);
  } else {
    char* body = !data                ? NULL
                 : !strcmp(data, "-") ? ReadStdin()
                                      : XStrdup(data);
    code = Request(&a->spec, method, body, path);
    free(body);
  }
  SpecFree(&a->spec);
  return code;
}

const Command kCommands[] = {
    {"check",
     "[--spec P] [--kit K] [--list | --hosts] | --plugin DIR | --kit-dir DIR "
     "| --climb FILE",
     "validate the harness (or list its plugins or network hosts), one "
     "plugin, one kit or a climb.yaml",
     CheckOrTools},
    {"tools", "[--spec P]", "print the tools as the model sees them",
     CheckOrTools},
    {"schema", "", "print the JSON Schema of agent.yaml", SchemaCommand},
    {"tool", "bash|edit [--schema]",
     "run a tool of the shell plugin (JSON arguments on stdin)", ToolCommand},
    {"watch", "[ID|last] [--json] [--from start|now]",
     "follow a session's events", WatchCommand},
    {"ctl", "ID|last stop | note TEXT | cancel CALL",
     "steer a running session, or cancel a background call (c7)", CtlCommand},
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
