// external.c: `arx foo` runs `arx-foo`, the way git runs git-foo. Commands
// like setup and update are small scripts, so the binary stays small and
// anyone can add a command by putting an executable on PATH.

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"

// The most external commands `arx help` lists.
#define ARX_MAX_LISTED 64

// Returns the directories to search, in order, NULL-terminated. Free each
// entry and the array.
static char** SearchDirs(void) {
  const char* path = getenv("PATH") ? getenv("PATH") : "";
  size_t n = 3;
  for (const char* p = path; *p; p++) n += *p == ':';
  char** dirs = XMalloc((n + 1) * sizeof(*dirs));
  char* bin = DirName(g_self);
  size_t k = 0;
  dirs[k++] = XAsprintf("%s/../libexec/arx", bin);  // installed
  dirs[k++] = XAsprintf("%s/commands", bin);        // source checkout
  for (const char* p = path; *p;) {
    size_t len = strcspn(p, ":");
    if (len) dirs[k++] = XStrndup(p, len);
    p += len + (p[len] == ':');
  }
  dirs[k] = NULL;
  free(bin);
  return dirs;
}

// Frees a list from SearchDirs.
static void FreeDirs(char** dirs) {
  for (char** d = dirs; *d; d++) free(*d);
  free(dirs);
}

// True when `path` is an executable regular file.
static int IsCommand(const char* path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode) && !access(path, X_OK);
}

// Finds arx-<name>; see cli.h.
char* FindCommand(const char* name) {
  char** dirs = SearchDirs();
  char* found = NULL;
  for (char** d = dirs; *d && !found; d++) {
    char* path = XAsprintf("%s/arx-%s", *d, name);
    if (IsCommand(path))
      found = path;
    else
      free(path);
  }
  FreeDirs(dirs);
  return found;
}

// Runs arx-<name>; see cli.h.
int RunExternal(const char* name, int argc, char** argv) {
  if (strchr(name, '/')) return -1;
  char* path = FindCommand(name);
  if (!path) return -1;
  char* dir = DirName(path);
  setenv("ARX_BIN", g_self, 1);
  setenv("ARX_LIBEXEC", dir, 1);
  char** args = XMalloc((size_t)argc * sizeof(*args));
  args[0] = path;
  for (int i = 2; i < argc; i++) args[i - 1] = argv[i];
  args[argc - 1] = NULL;
  execv(path, args);
  fprintf(stderr, "arx: cannot run %s: %s\n", path, strerror(errno));
  free(args);
  free(dir);
  free(path);
  return kExitError;
}

// Reads a command's summary from its "# arx-<name>: summary" line.
static char* Summary(const char* path, const char* name) {
  char* text = ReadFile(path, NULL);
  char* marker = XAsprintf("# arx-%s: ", name);
  char* at = text ? strstr(text, marker) : NULL;
  char* summary = NULL;
  if (at && at - text < 512) {
    at += strlen(marker);
    summary = XStrndup(at, strcspn(at, "\n"));
  }
  free(marker);
  free(text);
  return summary ? summary : XStrdup("");
}

// qsort comparator for names.
static int CompareNames(const void* a, const void* b) {
  return strcmp(*(char* const*)a, *(char* const*)b);
}

// Collects external command names (first match wins). Returns the count.
static int ListExternal(char** names) {
  char** dirs = SearchDirs();
  int n = 0;
  for (char** d = dirs; *d; d++) {
    DIR* dir = opendir(*d);
    struct dirent* e;
    while (dir && (e = readdir(dir)) && n < ARX_MAX_LISTED) {
      if (strncmp(e->d_name, "arx-", 4) || !e->d_name[4]) continue;
      int seen = 0;
      for (const Command* c = kCommands; c->name && !seen; c++) {
        seen = !strcmp(c->name, e->d_name + 4);
      }
      for (int i = 0; i < n && !seen; i++)
        seen = !strcmp(names[i], e->d_name + 4);
      char* path = XAsprintf("%s/%s", *d, e->d_name);
      if (!seen && IsCommand(path)) names[n++] = XStrdup(e->d_name + 4);
      free(path);
    }
    if (dir) closedir(dir);
  }
  FreeDirs(dirs);
  qsort(names, (size_t)n, sizeof(*names), CompareNames);
  return n;
}

// Prints every command with its summary.
static void PrintCommands(void) {
  char* names[ARX_MAX_LISTED];
  int n = ListExternal(names);
  printf("commands:\n");
  for (int i = 0; i < n; i++) {
    char* path = FindCommand(names[i]);
    char* summary = Summary(path, names[i]);
    printf("  %-10s %s\n", names[i], summary);
    free(summary);
    free(path);
    free(names[i]);
  }
  for (const Command* c = kCommands; c->name; c++) {
    printf("  %-10s %s\n", c->name, c->summary);
  }
}

// `arx help [COMMAND]`; see cli.h.
int HelpCommand(int argc, char** argv, Agent* a) {
  if (argc > 2) {
    char* help_argv[] = {argv[0], argv[2], "--help", NULL};
    int code = RunBuiltin(argv[2], 3, help_argv, a);
    if (code < 0) code = RunExternal(argv[2], 3, help_argv);
    return code < 0 ? UsageError("no such command", argv[2]) : code;
  }
  printf(
      "arx %s: a minimal, self-improving agent harness\n\n"
      "usage: arx [options]          run the agent (interactive, or headless "
      "if stdin is piped)\n"
      "       arx -p TASK [options]  run one task until the agent stops\n"
      "       arx COMMAND [args]     run a command\n\n",
      ARX_VERSION);
  PrintCommands();
  printf("\n");
  PrintOptions(stdout);
  printf("\nRun `arx help COMMAND` for one command. Docs: docs/plugins.md\n");
  return kExitDone;
}
