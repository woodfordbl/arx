// main.c: the arx command line. Parses options, installs signal handlers and
// dispatches to the agent or to one of the small subcommands.

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

static const char kUsage[] =
    "usage: arx [options]                 interactive (headless if stdin is "
    "not a terminal)\n"
    "       arx -p TASK|- [options]       run one task until the agent stops\n"
    "       arx check [--spec P]          validate the spec, tools and hooks\n"
    "       arx tools [--spec P]          print the tools as the model sees "
    "them\n"
    "       arx schema                    print the JSON Schema of agent.yaml\n"
    "       arx watch [ID|last] [--json] [--from start|now]\n"
    "       arx ctl ID|last stop|note TEXT\n"
    "       arx version\n"
    "options:\n"
    "  --spec PATH        agent spec (default ./agent.yaml)\n"
    "  --set KEY=VALUE    override a spec value, e.g. limits.max_turns=10\n"
    "  --cap KEY=VALUE    hard ceiling: turns, tokens, usd, wall, depth\n"
    "  --resume ID|last   continue a session\n"
    "  --json             print the result as JSON\n"
    "  --events PATH|-|fd:N   also write the event stream there\n"
    "  --quiet            no terminal view\n"
    "exit codes: 0 done, 1 error, 2 usage, 3 cap reached, 4 auth, 130 "
    "interrupted\n";

// The first Ctrl-C stops the current step; a second one exits at once.
static void OnSignal(int sig) {
  if (g_interrupted && sig == SIGINT) _exit(kExitInterrupted);
  g_interrupted = 1;
}

// No SA_RESTART: blocking reads return so the loop can notice the signal.
static void InstallSignals(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = OnSignal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
}

// Prints a usage error and returns kExitUsage.
static int UsageError(const char* what, const char* arg) {
  fprintf(stderr, "arx: %s%s%s\n%s", what, arg ? ": " : "", arg ? arg : "",
          kUsage);
  return kExitUsage;
}

// Parses the options shared by the agent, check and tools. Returns 0 or
// kExitUsage.
static int ParseOptions(int argc, char** argv, int first, Agent* a) {
  for (int i = first; i < argc; i++) {
    const char* arg = argv[i];
    const char* value = i + 1 < argc ? argv[i + 1] : NULL;
    int takes_value = 1;
    if (!strcmp(arg, "--json")) {
      a->json = 1;
      takes_value = 0;
    } else if (!strcmp(arg, "--quiet") || !strcmp(arg, "-q")) {
      a->quiet = 1;
      takes_value = 0;
    } else if (!value) {
      return UsageError("missing value or unknown option", arg);
    } else if (!strcmp(arg, "-p") || !strcmp(arg, "--prompt")) {
      a->prompt = value;
    } else if (!strcmp(arg, "--spec")) {
      a->spec_path = value;
    } else if (!strcmp(arg, "--resume")) {
      a->resume = value;
    } else if (!strcmp(arg, "--events")) {
      a->events = value;
    } else if (!strcmp(arg, "--set")) {
      if (SpecAddSet(a->sets, value)) return UsageError("bad --set", value);
    } else if (!strcmp(arg, "--cap")) {
      if (CapsParse(&a->caps, value)) return UsageError("bad --cap", value);
      a->cap_args[a->cap_count++] = (char*)value;
    } else {
      return UsageError("unknown option", arg);
    }
    i += takes_value;
  }
  return 0;
}

// Reads all of stdin into a new string.
static char* ReadStdin(void) {
  Buffer b = {0};
  char chunk[65536];
  size_t n;
  BufferAppend(&b, NULL, 0);
  while ((n = fread(chunk, 1, sizeof(chunk), stdin)) > 0) {
    BufferAppend(&b, chunk, n);
  }
  return BufferTake(&b);
}

// `arx check` and `arx tools`: load the harness without starting a session.
static int CheckMain(Agent* a, int print_tools) {
  Buffer err = {0};
  if (SpecLoad(a->spec_path, a->sets, &a->spec, &err)) {
    fputs(err.data, stderr);
    BufferFree(&err);
    return kExitUsage;
  }
  ToolsBuild(a);
  if (print_tools) {
    cJSON* tools = ToolsJson(&a->tools);
    char* text = cJSON_Print(tools);
    puts(text);
    free(text);
    cJSON_Delete(tools);
  } else {
    printf("ok: %s (model %s at %s)\ntools:", a->spec.path,
           JsonStr(a->spec.root, "model", ""),
           JsonStr(a->spec.root, "endpoint.base_url", ""));
    for (int i = 0; i < a->tools.count; i++) {
      printf(" %s", a->tools.items[i].name);
    }
    printf("\nhooks:");
    for (const char* const* p = kHookPoints; *p; p++) {
      char* path = XAsprintf("%s/hooks/%s", a->spec.dir, *p);
      if (!access(path, X_OK)) printf(" %s", *p);
      free(path);
    }
    printf("\n%s%s", a->notes.len ? "problems:\n" : "",
           a->notes.len ? a->notes.data : "");
  }
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  return kExitDone;
}

// `arx watch [ID|last] [--json] [--from start|now]`.
static int WatchCommand(int argc, char** argv) {
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
static int CtlCommand(int argc, char** argv) {
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

// Runs a subcommand, or returns -1 if `name` is not one.
static int Subcommand(const char* name, int argc, char** argv, Agent* a) {
  if (!strcmp(name, "version")) {
    puts("arx " ARX_VERSION);
    return kExitDone;
  }
  if (!strcmp(name, "help")) {
    fputs(kUsage, stdout);
    return kExitDone;
  }
  if (!strcmp(name, "schema")) {
    Buffer out = {0};
    SpecSchema(&out);
    fputs(out.data, stdout);
    BufferFree(&out);
    return kExitDone;
  }
  if (!strcmp(name, "watch")) return WatchCommand(argc, argv);
  if (!strcmp(name, "ctl")) return CtlCommand(argc, argv);
  if (!strcmp(name, "check") || !strcmp(name, "tools")) {
    int code = ParseOptions(argc, argv, 2, a);
    return code ? code : CheckMain(a, name[0] == 't');
  }
  return -1;
}

// Runs the agent: headless with -p or piped stdin, else interactive.
static int RunAgent(int argc, char** argv, Agent* a) {
  int code = ParseOptions(argc, argv, 1, a);
  if (code) return code;
  char* stdin_prompt = NULL;
  if ((a->prompt && !strcmp(a->prompt, "-")) || (!a->prompt && !isatty(0))) {
    a->prompt = stdin_prompt = ReadStdin();
  }
  a->interactive = !a->prompt && isatty(0);
  if (!a->interactive && !a->resume && (!a->prompt || !*a->prompt)) {
    code = UsageError("no task: use -p TASK, or pipe one on stdin", NULL);
  } else {
    code = AgentMain(a);
  }
  free(stdin_prompt);
  return code;
}

// Entry point.
int main(int argc, char** argv) {
  g_self = SelfPath(argv[0]);
  InstallSignals();
  Agent a;
  memset(&a, 0, sizeof(a));
  a.spec_path = "agent.yaml";
  a.sets = cJSON_CreateObject();
  a.caps = (Caps){.turns = -1, .tokens = -1, .usd = -1, .wall = -1, .depth = 4};
  a.cap_args = XMalloc((size_t)argc * sizeof(*a.cap_args));
  int code;
  if (argc > 1 && argv[1][0] != '-') {
    code = Subcommand(argv[1], argc, argv, &a);
    if (code < 0) code = UsageError("unknown command", argv[1]);
  } else if (argc > 1 &&
             (!strcmp(argv[1], "--version") || !strcmp(argv[1], "-V"))) {
    puts("arx " ARX_VERSION);
    code = kExitDone;
  } else {
    code = RunAgent(argc, argv, &a);
  }
  free(a.cap_args);
  cJSON_Delete(a.sets);
  free(g_self);
  return code;
}
