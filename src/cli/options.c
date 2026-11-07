// options.c: option parsing, spec lookup and usage errors, shared by the
// agent and the built-in commands.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"

// Prints a usage error.
int UsageError(const char* what, const char* arg) {
  fprintf(stderr, "arx: %s%s%s\nRun `arx help` for usage.\n", what,
          arg ? ": " : "", arg ? arg : "");
  return kExitUsage;
}

// Handles the options that take no value. Returns 1 if `arg` was one.
static int Flag(const char* arg, Agent* a) {
  if (!strcmp(arg, "--json")) {
    a->json = 1;
  } else if (!strcmp(arg, "--quiet") || !strcmp(arg, "-q")) {
    a->quiet = 1;
  } else {
    return 0;
  }
  return 1;
}

// Parses the shared options; see cli.h.
int ParseOptions(int argc, char** argv, int first, Agent* a) {
  for (int i = first; i < argc; i++) {
    const char* arg = argv[i];
    const char* value = i + 1 < argc ? argv[i + 1] : NULL;
    if (Flag(arg, a)) continue;
    if (!value) return UsageError("missing value or unknown option", arg);
    if (!strcmp(arg, "-p") || !strcmp(arg, "--prompt")) {
      a->prompt = value;
    } else if (!strcmp(arg, "--spec")) {
      a->spec_path = value;
    } else if (!strcmp(arg, "--resume")) {
      a->resume = value;
    } else if (!strcmp(arg, "--events")) {
      a->events = value;
    } else if (!strcmp(arg, "--kit")) {
      // The same as --set kit=NAME, so it stays in force after a reload.
      cJSON_DeleteItemFromObjectCaseSensitive(a->sets, "kit");
      cJSON_AddStringToObject(a->sets, "kit", value);
    } else if (!strcmp(arg, "--set")) {
      if (SpecAddSet(a->sets, value)) return UsageError("bad --set", value);
    } else if (!strcmp(arg, "--cap")) {
      if (CapsParse(&a->caps, value)) return UsageError("bad --cap", value);
      a->cap_args[a->cap_count++] = (char*)value;
    } else {
      return UsageError("unknown option", arg);
    }
    i++;
  }
  return 0;
}

// ./agent.yaml if present, else the user's defaults.
void ResolveSpec(Agent* a) {
  if (!a->spec_path && access("agent.yaml", R_OK) == 0) {
    a->spec_path = "agent.yaml";
  }
}

// Reads stdin to the end.
char* ReadStdin(void) {
  Buffer b = {0};
  char chunk[65536];
  size_t n;
  BufferAppend(&b, NULL, 0);
  while ((n = fread(chunk, 1, sizeof(chunk), stdin)) > 0) {
    BufferAppend(&b, chunk, n);
  }
  return BufferTake(&b);
}

// The options section of `arx help`.
void PrintOptions(FILE* out) {
  fputs(
      "options:\n"
      "  -p TASK|-             run one task (- reads it from stdin)\n"
      "  --spec PATH           agent spec (default ./agent.yaml, else your\n"
      "                        defaults from `arx setup`)\n"
      "  --kit NAME            use an installed kit (its plugins, in order,\n"
      "                        and its prompt); the agent cannot change it\n"
      "  --set KEY=VALUE       override a spec value, e.g. model=...\n"
      "  --cap KEY=VALUE       hard limit: turns, tokens, usd, wall, depth\n"
      "  --resume ID|last      continue a session\n"
      "  --json                print the result as JSON\n"
      "  --events PATH|-|fd:N  also write the event stream there\n"
      "  --quiet               no terminal view\n"
      "\nexit codes: 0 done, 1 error, 2 usage, 3 cap reached, 4 auth, "
      "130 interrupted\n",
      out);
}
