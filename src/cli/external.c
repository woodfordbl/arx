// external.c: `arx foo` runs `arx-foo`, the way git runs git-foo. Commands
// like setup and update are small scripts, so the binary stays small and
// anyone can add a command: in ~/.config/arx/commands/, in a plugin's
// commands/, or on PATH. The first match wins, and arx's own commands come
// first, so a plugin can add a command but not replace one.

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
#include "src/harness/harness.h"

// The most external commands `arx help` lists.
#define ARX_MAX_LISTED 64

// Returns the directories to search, in order, NULL-terminated: arx's own
// commands, the user's, each user plugin's, then PATH. Free each entry and
// the array.
static char** SearchDirs(void) {
  const char* path = getenv("PATH") ? getenv("PATH") : "";
  char* config = ConfigDir();
  char* plugins = XAsprintf("%s/plugins", config);
  char** names;
  int n_plugins = ListNames(plugins, &names);
  size_t n = 4 + (size_t)n_plugins;
  for (const char* p = path; *p; p++) n += *p == ':';
  char** dirs = XMalloc((n + 1) * sizeof(*dirs));
  char* bin = DirName(g_self);
  size_t k = 0;
  dirs[k++] = XAsprintf("%s/../libexec/arx", bin);  // installed
  dirs[k++] = XAsprintf("%s/commands", bin);        // source checkout
  dirs[k++] = XAsprintf("%s/commands", config);
  for (int i = 0; i < n_plugins; i++) {
    dirs[k++] = XAsprintf("%s/%s/commands", plugins, names[i]);
    free(names[i]);
  }
  for (const char* p = path; *p;) {
    size_t len = strcspn(p, ":");
    if (len) dirs[k++] = XStrndup(p, len);
    p += len + (p[len] == ':');
  }
  dirs[k] = NULL;
  free(names);
  free(plugins);
  free(config);
  free(bin);
  return dirs;
}

// Sets ARX_PLUGIN_DIR when the command in `dir` belongs to a user plugin
// (~/.config/arx/plugins/<name>/commands).
static void SetPluginDir(const char* dir) {
  char* plugin = DirName(dir);
  char* parent = DirName(plugin);
  char* config = ConfigDir();
  char* plugins = XAsprintf("%s/plugins", config);
  if (!strcmp(parent, plugins)) setenv("ARX_PLUGIN_DIR", plugin, 1);
  free(plugins);
  free(config);
  free(parent);
  free(plugin);
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
  SetPluginDir(dir);
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
