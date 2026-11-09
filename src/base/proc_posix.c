// proc_posix.c: the native side of the platform section in base.h, next to
// the process runner in proc.c: signals, exec, the executable check,
// observers, sleeping, and HttpStart by running curl. The browser build
// replaces both files with proc_host.c.

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"

extern char** environ;

// The first Ctrl-C stops the current step; a second one exits at once.
static void OnSignal(int sig) {
  if (g_interrupted && sig == SIGINT) _exit(kExitInterrupted);
  g_interrupted = 1;
}

// No SA_RESTART: blocking reads return so the loop can notice the signal.
void ProcInit(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = OnSignal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
}

// Replaces this process; see base.h.
int ProcExec(char* const* argv, int null_stdin) {
  if (null_stdin) {
    // What a process tool got before: no stdin, and the default SIGPIPE,
    // which arx itself ignores.
    int fd = open("/dev/null", O_RDONLY);
    if (fd > 0) {
      dup2(fd, 0);
      close(fd);
    }
    signal(SIGPIPE, SIG_DFL);
  }
  execvp(argv[0], argv);
  return -1;
}

// A regular file we may execute; see base.h.
int IsRunnable(const char* path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode) && !access(path, X_OK);
}

// Starts an observer on a non-blocking pipe; see base.h.
int ProcObserverStart(const char* command, char* const* env, int* pid) {
  int p[2];
  if (pipe(p)) return -1;
  fcntl(p[1], F_SETFD, FD_CLOEXEC);
  fcntl(p[1], F_SETFL, O_NONBLOCK);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[0], 0);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  char* argv[] = {"sh", "-c", (char*)command, NULL};
  char** full_env = env ? EnvWith(env) : environ;
  pid_t child;
  int rc = posix_spawnp(&child, "sh", &fa, NULL, argv, full_env);
  if (full_env != environ) free(full_env);
  posix_spawn_file_actions_destroy(&fa);
  close(p[0]);
  if (rc) {
    close(p[1]);
    return -1;
  }
  *pid = (int)child;
  return p[1];
}

// Polls for the observer's exit every 10 ms; see base.h.
void ProcObserverWait(int pid, double secs) {
  int steps = (int)(secs / 0.01 + 0.5);
  for (int k = 0; k < steps; k++) {
    if (waitpid(pid, NULL, WNOHANG) != 0) break;
    SleepSeconds(0.01);
  }
}

// A close-on-exec copy of stdout; see base.h.
int ProcDupStdout(void) {
  int fd = dup(1);
  if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

// Sleeps in 100 ms steps so Ctrl-C is noticed quickly.
void SleepSeconds(double s) {
  while (s > 0 && !g_interrupted) {
    double step = s > 0.1 ? 0.1 : s;
    struct timespec ts = {(time_t)step,
                          (int)((step - (double)(time_t)step) * 1e9)};
    nanosleep(&ts, NULL);
    s -= step;
  }
}

// A request in flight: its curl child and what its command line points at.
typedef struct HttpCall {
  ProcChild* child;
  char* request;   // the 0600 file with the request headers
  char* response;  // where curl writes the response headers (-D)
  char* header_arg;
  char max_time[32];
  char* argv[20];
  Buffer err;  // curl's stderr
  struct HttpCall* next;
} HttpCall;

// The requests in flight, so HttpFinish can find a child's files.
static HttpCall* g_calls;

// Deletes a request's files and frees it.
static void CallFree(HttpCall* h) {
  unlink(h->request);
  unlink(h->response);
  free(h->request);
  free(h->response);
  free(h->header_arg);
  BufferFree(&h->err);
  free(h);
}

// The curl command line, in the order docs/plugins/adapters.md shows.
static void BuildArgv(HttpCall* h, const HttpRequest* req) {
  const char* env = getenv("ARX_CURL");
  const char* curl = req->curl ? req->curl : env && *env ? env : "curl";
  char** argv = h->argv;
  int k = 0;
  if (req->adapter) argv[k++] = (char*)req->adapter;
  argv[k++] = (char*)curl;
  argv[k++] = "-sS";
  if (req->stream) argv[k++] = "-N";
  if (req->timeout > 0) {
    snprintf(h->max_time, sizeof(h->max_time), "%.0f", req->timeout);
    argv[k++] = "--max-time";
    argv[k++] = h->max_time;
  }
  argv[k++] = "-D";
  argv[k++] = h->response;
  argv[k++] = "-H";
  argv[k++] = h->header_arg;
  if (req->method) {
    argv[k++] = "-X";
    argv[k++] = (char*)req->method;
  }
  if (req->body) {
    argv[k++] = "--data-binary";
    argv[k++] = "@-";
  }
  argv[k++] = (char*)req->url;
  argv[k] = NULL;
}

// Starts curl for the request; see base.h. The headers, with the key, go
// to curl in a 0600 file, so the key never shows up in process listings.
ProcChild* HttpStart(const HttpRequest* req) {
  static int seq;
  HttpCall* h = XMalloc(sizeof(*h));
  memset(h, 0, sizeof(*h));
  seq++;
  h->request =
      XAsprintf("%s/.arx-request-%d-%d", req->tmp_dir, (int)getpid(), seq);
  h->response =
      XAsprintf("%s/.arx-response-%d-%d", req->tmp_dir, (int)getpid(), seq);
  h->header_arg = XAsprintf("@%s", h->request);
  int fd = open(h->request, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd >= 0) {
    WriteAll(fd, req->headers, strlen(req->headers));
    close(fd);
  }
  unlink(h->response);
  BuildArgv(h, req);
  Proc p = {.argv = h->argv,
            .in = req->body,
            .in_len = req->body ? req->body_len : 0,
            .timeout = req->timeout > 0 ? req->timeout + 30 : 0,
            .on_out = req->on_body,
            .out_ctx = req->body_ctx,
            .on_err = BufferSink,
            .err_ctx = &h->err};
  h->child = ProcStart(&p);
  if (!h->child) {
    int e = errno;
    CallFree(h);
    errno = e;
    return NULL;
  }
  h->next = g_calls;
  g_calls = h;
  return h->child;
}

// Reads the last HTTP status and any Retry-After from a `curl -D` file.
static void ReadStatus(const char* path, int* status, double* retry_after) {
  char* text = ReadFile(path, NULL);
  for (char* line = text; line && *line;) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    if (!strncmp(line, "HTTP/", 5)) {
      const char* space = strchr(line, ' ');
      *status = space ? atoi(space + 1) : 0;
    } else if (!strncasecmp(line, "retry-after:", 12)) {
      char* end;
      double secs = strtod(line + 12, &end);
      if (end != line + 12) *retry_after = secs;
    }
    line = nl ? nl + 1 : NULL;
  }
  free(text);
}

// Ends a request and deletes its files; see base.h.
void HttpFinish(ProcChild* c, HttpResult* r) {
  HttpCall** at = &g_calls;
  while (*at && (*at)->child != c) at = &(*at)->next;
  HttpCall* h = *at;
  if (h) *at = h->next;
  ProcResult pr;
  ProcFinish(c, &pr);
  memset(r, 0, sizeof(*r));
  r->retry_after = -1;
  r->net_error = pr.code;
  r->interrupted = pr.interrupted;
  r->secs = pr.secs;
  if (!h) return;
  ReadStatus(h->response, &r->status, &r->retry_after);
  r->err = h->err;
  memset(&h->err, 0, sizeof(h->err));
  CallFree(h);
}
