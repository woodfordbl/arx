// cli.h: the arx command line, the top layer.
//   options.c   option parsing, spec lookup and usage errors
//   commands.c  built-in commands: check, tools, schema, tool, watch, ctl,
//               request, version, help
//   external.c  `arx foo` runs `arx-foo` (next to the binary, then on PATH),
//               and `arx help` lists every command

#ifndef SRC_CLI_CLI_H_
#define SRC_CLI_CLI_H_

#include <stdio.h>

#include "src/agent/agent.h"

// ---- options.c ----

// Prints "arx: <what>: <arg>" and a pointer to `arx help` on stderr.
// Returns kExitUsage.
int UsageError(const char* what, const char* arg);

// Parses the options shared by the agent, check and tools, from argv[first].
// Returns 0 or kExitUsage.
int ParseOptions(int argc, char** argv, int first, Agent* a);

// Uses ./agent.yaml when --spec was not given and it exists; otherwise the
// spec stays NULL and SpecLoad uses the user's saved defaults.
void ResolveSpec(Agent* a);

// Reads all of stdin into a new string.
char* ReadStdin(void);

// Prints the run options and exit codes, for `arx help`.
void PrintOptions(FILE* out);

// ---- commands.c ----

// One built-in command, for dispatch and `arx help`.
typedef struct Command {
  const char* name;
  const char* args;
  const char* summary;
  int (*run)(int argc, char** argv, Agent* a);
} Command;

// The built-in commands, ending with a zeroed entry.
extern const Command kCommands[];

// Runs built-in command `name` (argv[1]). Returns its exit code, or -1 if
// `name` is not a built-in.
int RunBuiltin(const char* name, int argc, char** argv, Agent* a);

// ---- external.c ----

// Returns the path of the external command `arx-<name>`, or NULL. It looks
// next to the binary (../libexec/arx/ when installed, commands/ in a source
// checkout), then on PATH.
char* FindCommand(const char* name);

// Runs `arx-<name>` with argv[2..], with ARX_BIN and ARX_LIBEXEC set. Does
// not return on success; returns -1 if there is no such command, or
// kExitError if it could not be started.
int RunExternal(const char* name, int argc, char** argv);

// `arx help [COMMAND]`: everything, or one command (an external command
// prints its own help with --help).
int HelpCommand(int argc, char** argv, Agent* a);

#endif  // SRC_CLI_CLI_H_
