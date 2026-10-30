// proc.c: the process runner behind every tool, hook, curl call and
// subagent. One poll() loop feeds stdin, drains stdout, stderr and fd 3, and
// enforces the timeout on the child's whole process group.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"

extern char** environ;

// Seconds between SIGTERM and SIGKILL when a child is stopped.
static const double kKillGraceSeconds = 3.0;

// How long to keep reading after the child exits, for output that its
// background children still hold open.
static const double kDrainSeconds = 0.2;

// Returns a copy of environ with `extra` entries added or replaced.
static char** EnvWith(char* const* extra) {
  size_t n = 0, m = 0, k = 0;
  while (environ[n]) n++;
  while (extra[m]) m++;
  char** env = XMalloc((n + m + 1) * sizeof(*env));
  for (size_t i = 0; i < n; i++) {
    const char* eq = strchr(environ[i], '=');
    size_t key_len = eq ? (size_t)(eq - environ[i]) : strlen(environ[i]);
    int replaced = 0;
    for (size_t j = 0; j < m && !replaced; j++) {
      replaced =
          !strncmp(extra[j], environ[i], key_len) && extra[j][key_len] == '=';
    }
    if (!replaced) env[k++] = environ[i];
  }
  for (size_t j = 0; j < m; j++) env[k++] = extra[j];
  env[k] = NULL;
  return env;
}

// pipe() with both ends close-on-exec, so other children never inherit them.
static int PipeCloexec(int p[2]) {
  if (pipe(p)) return -1;
  fcntl(p[0], F_SETFD, FD_CLOEXEC);
  fcntl(p[1], F_SETFD, FD_CLOEXEC);
  return 0;
}

// Closes *fd if it is open and marks it closed.
static void CloseFd(int* fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

// Reads one chunk from *fd into `cb`; closes *fd at end of file.
static void Pump(int* fd, DataFn cb, void* ctx) {
  char chunk[65536];
  ssize_t n = read(*fd, chunk, sizeof(chunk));
  if (n > 0) {
    if (cb) cb(ctx, chunk, (size_t)n);
  } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
    CloseFd(fd);
  }
}

// Adds `fd` to the poll set if it is open. Returns its index, or -1.
static int PollAdd(struct pollfd* pf, int* n, int fd, int events) {
  if (fd < 0) return -1;
  pf[*n] = (struct pollfd){.fd = fd, .events = (int16_t)events, .revents = 0};
  return (*n)++;
}

// The four pipes between us and the child; index 0 reads, 1 writes.
typedef struct Pipes {
  int in[2], out[2], err[2], fd3[2];
} Pipes;

// Closes every pipe end that is still open.
static void ClosePipes(Pipes* p) {
  int* all[] = {&p->in[0],  &p->in[1],  &p->out[0], &p->out[1],
                &p->err[0], &p->err[1], &p->fd3[0], &p->fd3[1]};
  for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) CloseFd(all[i]);
}

// Starts the child with its pipes, its own process group and default signal
// handling. Returns 0 or an errno value.
static int Spawn(const Proc* p, Pipes* io, pid_t* pid) {
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  if (p->in) {
    posix_spawn_file_actions_adddup2(&fa, io->in[0], 0);
  } else {
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  }
  posix_spawn_file_actions_adddup2(&fa, io->out[1], 1);
  posix_spawn_file_actions_adddup2(&fa, p->on_err ? io->err[1] : io->out[1], 2);
  if (p->on_fd3) posix_spawn_file_actions_adddup2(&fa, io->fd3[1], 3);

  posix_spawnattr_t attr;
  sigset_t defaults, mask;
  posix_spawnattr_init(&attr);
  sigemptyset(&defaults);
  sigaddset(&defaults, SIGINT);
  sigaddset(&defaults, SIGTERM);
  sigaddset(&defaults, SIGPIPE);
  sigemptyset(&mask);
  posix_spawnattr_setsigdefault(&attr, &defaults);
  posix_spawnattr_setsigmask(&attr, &mask);
  posix_spawnattr_setpgroup(&attr, 0);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP |
                                      POSIX_SPAWN_SETSIGDEF |
                                      POSIX_SPAWN_SETSIGMASK);

  char** env = p->env ? EnvWith(p->env) : environ;
  int rc = posix_spawnp(pid, p->argv[0], &fa, &attr, p->argv, env);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&attr);
  if (env != environ) free(env);
  return rc;
}

// Runs the child to completion; see base.h.
int ProcRun(const Proc* p, ProcResult* r) {
  Pipes io = {{-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}};
  memset(r, 0, sizeof(*r));
  r->code = -1;
  if ((p->in && PipeCloexec(io.in)) || PipeCloexec(io.out) ||
      (p->on_err && PipeCloexec(io.err)) ||
      (p->on_fd3 && PipeCloexec(io.fd3))) {
    ClosePipes(&io);
    r->spawn_failed = 1;
    return -1;
  }
  double start = Now();
  pid_t pid;
  int rc = Spawn(p, &io, &pid);
  CloseFd(&io.in[0]);
  CloseFd(&io.out[1]);
  CloseFd(&io.err[1]);
  CloseFd(&io.fd3[1]);
  if (rc) {
    ClosePipes(&io);
    r->spawn_failed = 1;
    errno = rc;
    return -1;
  }
  if (io.in[1] >= 0) fcntl(io.in[1], F_SETFL, O_NONBLOCK);

  size_t written = 0;
  int status = 0, reaped = 0, killed = 0;
  double kill_at = 0, drain_until = 0;
  double deadline = p->timeout > 0 ? start + p->timeout : 0;
  for (;;) {
    struct pollfd pf[4];
    int n = 0;
    int i_in = PollAdd(pf, &n, io.in[1], POLLOUT);
    int i_out = PollAdd(pf, &n, io.out[0], POLLIN);
    int i_err = PollAdd(pf, &n, io.err[0], POLLIN);
    int i_fd3 = PollAdd(pf, &n, io.fd3[0], POLLIN);
    if (reaped && (n == 0 || Now() >= drain_until)) break;
    int wait_ms = reaped ? (int)((drain_until - Now()) * 1000) + 1 : 100;
    if (n && poll(pf, (nfds_t)n, wait_ms) > 0) {
      if (i_in >= 0 && pf[i_in].revents) {
        ssize_t w = write(io.in[1], p->in + written, p->in_len - written);
        if (w > 0) written += (size_t)w;
        if ((w < 0 && errno != EAGAIN && errno != EINTR) ||
            written >= p->in_len) {
          CloseFd(&io.in[1]);
        }
      }
      if (i_out >= 0 && pf[i_out].revents)
        Pump(&io.out[0], p->on_out, p->out_ctx);
      if (i_err >= 0 && pf[i_err].revents)
        Pump(&io.err[0], p->on_err, p->err_ctx);
      if (i_fd3 >= 0 && pf[i_fd3].revents)
        Pump(&io.fd3[0], p->on_fd3, p->fd3_ctx);
    } else if (!n) {
      struct timespec ms = {0, 1000000};  // all pipes closed: wait for exit
      nanosleep(&ms, NULL);
    }
    if (!reaped && waitpid(pid, &status, WNOHANG) == pid) {
      reaped = 1;
      drain_until = Now() + kDrainSeconds;
      CloseFd(&io.in[1]);
    }
    double t = Now();
    if (!reaped && !killed && (g_interrupted || (deadline && t > deadline))) {
      if (g_interrupted) {
        r->interrupted = 1;
      } else {
        r->timed_out = 1;
      }
      kill(-pid, SIGTERM);
      killed = 1;
      kill_at = t + kKillGraceSeconds;
    } else if (!reaped && killed && t > kill_at) {
      kill(-pid, SIGKILL);
      kill_at = t + 1e9;
    }
  }
  ClosePipes(&io);
  if (!reaped) waitpid(pid, &status, 0);
  if (killed) kill(-pid, SIGKILL);  // anything left in the group
  r->secs = Now() - start;
  r->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  return 0;
}
