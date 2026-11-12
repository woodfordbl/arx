// cli.h: the arx command line, the top layer.
//   options.c   option parsing, spec lookup and usage errors
//   commands.c  built-in commands: schema, tool, watch, ctl, request,
//               version, help
//   check.c     `arx check` and `arx tools`: load the harness and report
//   climb.c     `arx check --climb`: climb.yaml as JSON, for `arx climb`
//   shell_tools.c  bash and edit, for `arx tool` (the shell plugin)
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

// ---- check.c ----

// `arx check` and `arx tools`: load the harness without starting a
// session, and print it (check: the spec, kit, tools, hooks, plugins,
// problems and warnings; --list: the active list; --hosts: the network
// hosts, one per line; tools: the tools as the model sees them). `arx check
// --plugin DIR` and `--kit-dir DIR` check one plugin or kit folder and print
// key=value lines; `--climb FILE` prints climb.yaml as JSON (see climb.c).
// Returns an ExitCode.
int CheckOrTools(int argc, char** argv, Agent* a);

// ---- climb.c ----

// Checks the climb.yaml at `path` against its field table and appends it to
// `out` as one line of JSON, with every default filled in and durations in
// seconds. Returns 0, or -1 with one "file:line: key: message" line per
// problem in `err`.
int ClimbDescribe(const char* path, Buffer* out, Buffer* err);

// ---- external.c ----

// Returns the path of the external command `arx-<name>`, or NULL. It looks
// next to the binary (../libexec/arx/ when installed, commands/ in a source
// checkout), then on PATH.
char* FindCommand(const char* name);

// Runs `arx-<name>` with argv[2..], with ARX_BIN and ARX_LIBEXEC set. Does
// not return on success; returns -1 if there is no such command, or
// kExitError if it could not be started.
int RunExternal(const char* name, int argc, char** argv);

// Runs `arx-<name>`, the `ui:` command, in place of an interactive run, with
// every argument arx got (argv[1..]) and the variables RunExternal sets.
// Does not return on success. When there is no such command or it does not
// start, says so on stderr and returns, and the built-in view draws the run.
void RunUi(const char* name, int argc, char** argv);

// `arx help [COMMAND]`: everything, or one command (an external command
// prints its own help with --help).
int HelpCommand(int argc, char** argv, Agent* a);

// ---- shell_tools.c ----

// Returns the schema of `arx tool <name>` as JSON text ({"description",
// "parameters"}, as plugins/shell/tools/<name>.json has it), or NULL when
// `name` is not bash or edit.
const char* ShellToolSchema(const char* name);

// Runs `arx tool <name>` with the JSON arguments `args` as a process tool:
// the result goes to stdout, exit code 0, or 1 for an error. bash execs
// `sh -c <command>` and returns only if that fails.
int ShellToolRun(const char* name, const char* args);

#endif  // SRC_CLI_CLI_H_
