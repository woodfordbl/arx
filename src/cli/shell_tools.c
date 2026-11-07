// shell_tools.c: the bash and edit tools behind `arx tool NAME`. The code
// stays in the binary so the tools are fast and need no other programs, but
// the shell plugin connects them, so another plugin can replace them (for
// example to run them in a sandbox).

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/cli/cli.h"

// The schemas, the same as plugins/shell/tools/<name>.json. The {{...}}
// fields are filled in when the tool loads (see ToolsBuild).
static const char kBashSchema[] =
    "{\"description\":\"Run a shell command (sh -c) in the working "
    "directory. You see the first {{tool_output.head}} and last "
    "{{tool_output.tail}} bytes of output; the full output is saved to a "
    "file whose path is shown. Timeout {{timeout}}s.\",\"parameters\":{"
    "\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\","
    "\"description\":\"Shell command, run with sh -c in the working "
    "directory\"}},\"required\":[\"command\"]}}";
static const char kEditSchema[] =
    "{\"description\":\"Replace an exact, unique string in a file, or create "
    "a new file when `old` is empty.\",\"parameters\":{\"type\":\"object\","
    "\"properties\":{\"path\":{\"type\":\"string\"},\"old\":{\"type\":"
    "\"string\",\"description\":\"Exact text to replace; it must occur "
    "exactly once. Empty creates a new file.\"},\"new\":{\"type\":\"string\","
    "\"description\":\"Replacement text\"}},\"required\":[\"path\",\"old\","
    "\"new\"]},\"keys\":[\"file:{path}\"]}";

// Returns the schema of `arx tool <name>`; see cli.h.
const char* ShellToolSchema(const char* name) {
  if (!strcmp(name, "bash")) return kBashSchema;
  if (!strcmp(name, "edit")) return kEditSchema;
  return NULL;
}

// Creates `path` with `text`, refusing to overwrite.
static char* CreateFile(const char* path, const char* text, int* is_error) {
  char* dir = DirName(path);
  MakeDirs(dir);
  free(dir);
  if (WriteFileAtomic(path, text, strlen(text))) {
    return XAsprintf("cannot create %s: %s", path, strerror(errno));
  }
  *is_error = 0;
  return XAsprintf("created %s (%zu bytes)", path, strlen(text));
}

// The edit tool: replace one exact, unique occurrence, or create a file.
static char* Edit(cJSON* args, int* is_error) {
  const char* path = JsonStr(args, "path", NULL);
  const char* old = JsonStr(args, "old", NULL);
  const char* new_text = JsonStr(args, "new", NULL);
  *is_error = 1;
  if (!path || !old || !new_text) {
    return XStrdup("edit needs string arguments path, old and new");
  }
  size_t n;
  char* text = ReadFile(path, &n);
  if (!*old) {
    if (!text) return CreateFile(path, new_text, is_error);
    free(text);
    return XAsprintf("%s exists; pass the exact text to replace in `old`",
                     path);
  }
  if (!text) return XAsprintf("cannot read %s: %s", path, strerror(errno));
  size_t old_len = strlen(old), count = 0;
  char* hit = NULL;
  for (char* p = text; (p = memmem(p, n - (size_t)(p - text), old, old_len));
       p += old_len) {
    if (!count++) hit = p;
  }
  char* result;
  if (count != 1) {
    result = count ? XAsprintf(
                         "`old` occurs %zu times in %s; include more "
                         "context so it is unique",
                         count, path)
                   : XAsprintf(
                         "`old` was not found in %s (it must match "
                         "exactly, including whitespace)",
                         path);
  } else {
    Buffer b = {0};
    BufferAppend(&b, text, (size_t)(hit - text));
    BufferAppendStr(&b, new_text);
    BufferAppend(&b, hit + old_len, n - (size_t)(hit - text) - old_len);
    if (WriteFileAtomic(path, b.data, b.len)) {
      result = XAsprintf("cannot write %s: %s", path, strerror(errno));
    } else {
      result = XAsprintf("edited %s", path);
      *is_error = 0;
    }
    BufferFree(&b);
  }
  free(text);
  return result;
}

// The bash tool: becomes `sh -c <command>`, so it costs no extra process.
static int Bash(cJSON* args) {
  const char* command = JsonStr(args, "command", NULL);
  if (!command) {
    fputs("bash needs a string argument `command`", stdout);
    return 1;
  }
  // The command gets what a process tool got before: no stdin, and the
  // default SIGPIPE, which arx itself ignores.
  int fd = open("/dev/null", O_RDONLY);
  if (fd > 0) {
    dup2(fd, 0);
    close(fd);
  }
  signal(SIGPIPE, SIG_DFL);
  execlp("sh", "sh", "-c", command, (char*)NULL);
  printf("cannot run sh: %s", strerror(errno));
  return 127;
}

// Runs `arx tool <name>`; see cli.h.
int ShellToolRun(const char* name, const char* args) {
  cJSON* parsed = cJSON_Parse(args ? args : "");
  int code = 1;
  if (!cJSON_IsObject(parsed)) {
    printf("the arguments are not a valid JSON object: %.200s",
           args ? args : "");
  } else if (!strcmp(name, "bash")) {
    code = Bash(parsed);
  } else {
    int is_error;
    char* text = Edit(parsed, &is_error);
    fputs(text, stdout);
    free(text);
    code = is_error;
  }
  cJSON_Delete(parsed);
  return code;
}
