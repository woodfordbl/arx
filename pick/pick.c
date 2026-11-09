// pick.c: pick's command line: the verbs, items on stdin, the text boxes,
// `confirm`, `spin` and the exit codes. See pick.h.

#include "pick/pick.h"

#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef ARX_VERSION
#define ARX_VERSION "dev"
#endif

// The most items a list takes, and the longest line (4 KB).
#define PICK_MAX_ITEMS 10000
#define PICK_MAX_LINE 4096

static const char kUsageText[] =
    "usage: pick select  [--title T] [--default VALUE] [--filter] [--custom]\n"
    "                    [--height N] [--quiet]\n"
    "       pick multi   [--title T] [--min N] [--height N] [--quiet]\n"
    "       pick input   [--title T] [--default TEXT] [--placeholder TEXT]\n"
    "                    [--quiet]\n"
    "       pick secret  [--title T] [--quiet]\n"
    "       pick confirm [--title T] [--default yes|no] [--quiet]\n"
    "       pick spin    [--title T] (--pid PID | -- COMMAND [ARG...])\n"
    "Items come on stdin, one per line: VALUE<TAB>LABEL<TAB>NOTE<TAB>FLAGS,\n"
    "where FLAGS is a comma list of checked and off. Keys come from "
    "/dev/tty,\nand only the answer goes to stdout.\n"
    "Exit: 0 answered (confirm: yes), 1 no, 2 usage, 3 no terminal, 4 Esc,\n"
    "130 Ctrl-C; spin -- COMMAND exits with the command's code.\n";

// Each option, whether it takes a value, and the verbs that accept it.
static const struct {
  const char *name, *verbs;
  int value;
} kOptions[] = {
    {"--title", "select multi input secret confirm spin", 1},
    {"--default", "select input confirm", 1},
    {"--placeholder", "input", 1},
    {"--height", "select multi", 1},
    {"--min", "multi", 1},
    {"--pid", "spin", 1},
    {"--filter", "select", 0},
    {"--custom", "select", 0},
    {"--quiet", "select multi input secret confirm", 0},
};

static volatile sig_atomic_t g_interrupted;  // spin: Ctrl-C came

// Prints "pick: <what>" and the usage; returns kUsage.
static int Usage(const char* what, const char* arg) {
  fprintf(stderr, "pick: %s%s%s\n%s", what, arg ? " " : "", arg ? arg : "",
          kUsageText);
  return kUsage;
}

// Stores option `name` with `value` in `o`.
static int SetOption(Opts* o, const char* name, const char* value) {
  if (!strcmp(name, "--title")) o->title = value;
  if (!strcmp(name, "--default")) o->def = value;
  if (!strcmp(name, "--placeholder")) o->placeholder = value;
  if (!strcmp(name, "--filter")) o->filter = 1;
  if (!strcmp(name, "--custom")) o->custom = 1;
  if (!strcmp(name, "--quiet")) o->quiet = 1;
  if (!strcmp(name, "--height") && (o->height = atoi(value)) < 1)
    return Usage("--height needs a number of at least 1, not", value);
  if (!strcmp(name, "--min") && (o->min = atoi(value)) < 0)
    return Usage("--min needs a number, not", value);
  if (!strcmp(name, "--pid") && (o->pid = atoi(value)) < 1)
    return Usage("--pid needs a process id, not", value);
  return -1;
}

// Parses argv into `o`. Returns -1 to go on, or an exit code.
static int ParseArgs(int argc, char** argv, Opts* o) {
  static const char kVerbs[] = " select multi input secret confirm spin ";
  char verb[32];
  if (argc < 2) return Usage("which verb?", NULL);
  o->verb = argv[1];
  if (!strcmp(o->verb, "version") || !strcmp(o->verb, "--version")) {
    printf("pick %s\n", ARX_VERSION);
    return kAnswered;
  }
  if (!strcmp(o->verb, "-h") || !strcmp(o->verb, "--help")) {
    fputs(kUsageText, stdout);
    return kAnswered;
  }
  snprintf(verb, sizeof(verb), " %s ", o->verb);
  if (strlen(o->verb) > 20 || !strstr(kVerbs, verb))
    return Usage("unknown verb", o->verb);
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--") && !strcmp(o->verb, "spin")) {
      o->cmd = argv + i + 1;
      if (!*o->cmd) return Usage("spin -- needs a command", NULL);
      break;
    }
    size_t k = 0, n = sizeof(kOptions) / sizeof(*kOptions);
    while (k < n && strcmp(kOptions[k].name, argv[i])) k++;
    if (k == n || !strstr(kOptions[k].verbs, o->verb))
      return Usage("unknown option", argv[i]);
    if (kOptions[k].value && i + 1 >= argc)
      return Usage("a value is missing after", argv[i]);
    const char* name = argv[i];
    int code = SetOption(o, name, kOptions[k].value ? argv[++i] : NULL);
    if (code >= 0) return code;
  }
  if (!strcmp(o->verb, "spin") && !o->cmd == !o->pid)
    return Usage("spin needs --pid PID or -- COMMAND", NULL);
  if (!strcmp(o->verb, "confirm") && o->def && strcmp(o->def, "yes") &&
      strcmp(o->def, "no"))
    return Usage("confirm --default is yes or no, not", o->def);
  return -1;
}

// Copies a field, with control characters made spaces.
static char* Field(const char* s, size_t n) {
  char* f = malloc(n + 1);
  if (!f) exit(kUsage);
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    f[i] = (char)(c < 0x20 || c == 0x7f ? ' ' : c);
  }
  f[n] = 0;
  return f;
}

// Reads the items from stdin. Returns 0 or kUsage.
static int ReadItems(Item** out, int* n) {
  char line[PICK_MAX_LINE + 2];
  int cap = 0;
  *n = 0;
  while (fgets(line, sizeof(line), stdin)) {
    size_t len = strlen(line);
    if (len == sizeof(line) - 1 && line[len - 1] != '\n')
      return Usage("an item line is over 4 KB", NULL);
    while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) len--;
    if (!len) continue;
    if (*n == PICK_MAX_ITEMS) return Usage("over 10,000 items", NULL);
    if (*n == cap) {
      cap = cap ? cap * 2 : 64;
      *out = realloc(*out, sizeof(**out) * (size_t)cap);
      if (!*out) exit(kUsage);
    }
    char* fields[4] = {line, NULL, NULL, NULL};
    size_t lens[4] = {len, 0, 0, 0};
    for (int f = 0; f < 3; f++) {
      char* tab = memchr(fields[f], '\t', lens[f]);
      if (!tab) break;
      fields[f + 1] = tab + 1;
      lens[f + 1] = lens[f] - (size_t)(tab + 1 - fields[f]);
      lens[f] = (size_t)(tab - fields[f]);
    }
    Item* it = &(*out)[(*n)++];
    memset(it, 0, sizeof(*it));
    it->value = Field(fields[0], lens[0]);
    it->label = lens[1] ? Field(fields[1], lens[1]) : Field(line, lens[0]);
    it->note = Field(fields[2] ? fields[2] : "", lens[2]);
    char* flags = Field(fields[3] ? fields[3] : "", lens[3]);
    char* rest = NULL;
    for (char* f = strtok_r(flags, ", ", &rest); f;
         f = strtok_r(NULL, ", ", &rest)) {
      it->checked |= !strcmp(f, "checked");
      it->off |= !strcmp(f, "off");
    }
    free(flags);
  }
  return 0;
}

// SIGINT during `spin`: wait for the work, then exit 130.
static void OnInterrupt(int sig) {
  (void)sig;
  g_interrupted = 1;
}

// Starts COMMAND with stdin from /dev/null and, when `err` is set, stderr
// into it. Returns the child's pid, or -1.
static pid_t Start(char** cmd, int err) {
  pid_t pid = fork();
  if (pid) return pid;
  int null = open("/dev/null", O_RDONLY);
  if (null >= 0) dup2(null, 0);
  if (err >= 0) dup2(err, 2);
  execvp(cmd[0], cmd);
  fprintf(stderr, "pick: cannot run %s: %s\n", cmd[0], strerror(errno));
  _exit(127);
}

// Draws one spinner frame, with the seconds after 2 s.
static void DrawSpin(const Opts* o, int frame, double secs) {
  Buf b = {0};
  int cols = TermCols() - 1;
  BufFmt(&b, "%s%s%s ", g_style.accent, g_style.spin[frame % g_style.n_spin],
         g_style.reset);
  PutFit(&b, o->title, cols - 8);
  if (secs >= 2) BufFmt(&b, "  %s%ds%s", g_style.dim, (int)secs, g_style.reset);
  TermDraw(&b, 1, -1, 0);
  free(b.s);
}

// `spin`: a spinner while COMMAND or PID runs. Without a terminal it runs
// the command plainly, so it never exits 3.
static int RunSpin(const Opts* o) {
  int tty = TermOpen() == 0, err[2] = {-1, -1}, status = 0, frame = 0;
  struct sigaction sa, old;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = OnInterrupt;
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGINT, NULL, &old) == 0 && old.sa_handler != SIG_IGN)
    sigaction(SIGINT, &sa, NULL);
  if (tty && o->cmd && pipe(err)) err[0] = err[1] = -1;
  // A background process the command leaves may hold stderr open, so the
  // last read must not wait for it.
  if (err[0] >= 0) fcntl(err[0], F_SETFL, fcntl(err[0], F_GETFL) | O_NONBLOCK);
  pid_t child = o->cmd ? Start(o->cmd, err[1]) : -1;
  if (o->cmd && child < 0) return Usage("cannot start", o->cmd[0]);
  if (err[1] >= 0) close(err[1]);
  if (tty) TermRaw(1);
  Buf errors = {0};
  struct timespec t0, now;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (int done = 0; !done;) {
    struct pollfd p = {err[0], POLLIN, 0};
    if (poll(&p, err[0] >= 0, 80) > 0) {
      char chunk[4096];
      ssize_t n = read(err[0], chunk, sizeof(chunk));
      if (n > 0 && errors.len < 65536) BufAdd(&errors, chunk, (size_t)n);
      if (n == 0) close(err[0]), err[0] = -1;
    }
    if (child > 0) {
      done = waitpid(child, &status, WNOHANG) == child;
    } else {
      done = g_interrupted || (kill(o->pid, 0) && errno == ESRCH);
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    double secs = (double)(now.tv_sec - t0.tv_sec) +
                  (double)(now.tv_nsec - t0.tv_nsec) / 1e9;
    if (tty && !done) DrawSpin(o, frame++, secs);
  }
  char chunk[4096];
  ssize_t n;
  while (err[0] >= 0 && (n = read(err[0], chunk, sizeof(chunk))) > 0)
    if (errors.len < 65536) BufAdd(&errors, chunk, (size_t)n);
  if (tty) TermClear(), TermRestore();
  int code = WIFEXITED(status)     ? WEXITSTATUS(status)
             : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                   : 0;
  if (g_interrupted) code = kCancel;
  if (code && errors.len) fwrite(errors.s, 1, errors.len, stderr);
  free(errors.s);
  return code;
}

// pick VERB [options]; see kUsageText.
int main(int argc, char** argv) {
  setlocale(LC_CTYPE, "");
  StyleInit();
  Opts o = {.title = "", .height = 8};
  int code = ParseArgs(argc, argv, &o), n = 0;
  if (code >= 0) return code;
  if (!strcmp(o.verb, "spin")) return RunSpin(&o);
  int list = !strcmp(o.verb, "select") || !strcmp(o.verb, "multi");
  Item* items = NULL;
  if (list && (code = ReadItems(&items, &n))) return code;
  if (list && !n && !o.custom) return Usage("no items on stdin", NULL);
  code = TermOpen();  // kNoTerminal (3), or 0
  if (!code && list) {
    code = RunList(&o, items, n, !strcmp(o.verb, "multi"));
  } else if (!code && !strcmp(o.verb, "confirm")) {
    code = RunConfirm(&o);
  } else if (!code) {
    code = RunText(&o, !strcmp(o.verb, "secret"));
  }
  for (int i = 0; i < n; i++) {
    free(items[i].value);
    free(items[i].label);
    free(items[i].note);
  }
  free(items);
  fflush(stdout);
  return code;
}
