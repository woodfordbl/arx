// main.c: the entry point. Installs signal handlers, then runs a built-in
// command, an external `arx-*` command, or the agent.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"

// Runs the agent: headless with -p or piped stdin, else interactive.
static int RunAgent(int argc, char** argv, Agent* a) {
  int code = ParseOptions(argc, argv, 1, a);
  if (code) return code;
  ResolveSpec(a);
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
