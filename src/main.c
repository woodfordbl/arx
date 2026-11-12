// main.c: the entry point. Installs signal handlers, then runs a built-in
// command, an external `arx-*` command, or the agent.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"

// The `ui:` command of this run (malloc'd), or NULL for the built-in view.
// Only an interactive run on a terminal has one: no -p, --input, --json or
// --events, and both stdin and stdout are terminals. `none` turns it off. A
// spec that does not load gives NULL here, and the run reports the error.
static char* UiCommand(Agent* a) {
  if (a->prompt || a->input_jsonl || a->json || a->events) return NULL;
  if (!isatty(0) || !isatty(1)) return NULL;
  Spec spec;
  Buffer err = {0};
  char* name = NULL;
  // Without the policy folders: the run resolves and checks them later.
  if (!SpecLoad(a->spec_path, a->sets, NULL, &spec, &err)) {
    const char* ui = JsonStr(spec.root, "ui", "");
    if (*ui && strcmp(ui, "none")) name = XStrdup(ui);
    SpecFree(&spec);
  }
  BufferFree(&err);
  return name;
}

// Runs the agent: headless with -p or piped stdin, else interactive. With
// --input jsonl a piped stdin carries the prompts, so the run is interactive.
static int RunAgent(int argc, char** argv, Agent* a) {
  int code = ParseOptions(argc, argv, 1, a);
  if (code) return code;
  if (a->input_jsonl && a->prompt) {
    return UsageError("--input jsonl does not take -p", NULL);
  }
  ResolveSpec(a);
  char* ui = UiCommand(a);
  if (ui) RunUi(ui, argc, argv);  // returns only when the command did not run
  free(ui);
  char* stdin_prompt = NULL;
  int piped = !a->prompt && !a->input_jsonl && !isatty(0);
  if ((a->prompt && !strcmp(a->prompt, "-")) || piped) {
    a->prompt = stdin_prompt = ReadStdin();
  }
  a->interactive = a->input_jsonl || (!a->prompt && isatty(0));
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
  ProcInit();
  Agent a;
  memset(&a, 0, sizeof(a));
  a.sets = cJSON_CreateObject();
  a.caps = (Caps){.turns = -1, .tokens = -1, .usd = -1, .wall = -1, .depth = 4};
  a.cap_args = XMalloc((size_t)argc * sizeof(*a.cap_args));
  const char* first = argc > 1 ? argv[1] : "";
  int code;
  if (!strcmp(first, "--version") || !strcmp(first, "-V")) {
    code = RunBuiltin("version", argc, argv, &a);
  } else if (!strcmp(first, "--help") || !strcmp(first, "-h")) {
    code = HelpCommand(1, argv, &a);
  } else if (first[0] && first[0] != '-') {
    code = RunBuiltin(first, argc, argv, &a);
    if (code < 0) code = RunExternal(first, argc, argv);
    if (code < 0) code = UsageError("unknown command", first);
  } else {
    code = RunAgent(argc, argv, &a);
  }
  free(a.cap_args);
  cJSON_Delete(a.sets);
  cJSON_Delete(a.policy);
  free(g_self);
  return code;
}
