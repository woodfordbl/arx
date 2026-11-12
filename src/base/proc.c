// proc.c: the process runner behind every tool, hook, curl call and
// subagent. One poll() loop serves many children at once: it feeds stdin,
// drains stdout, stderr and fd 3, and enforces each timeout and Ctrl-C on
// the child's whole process group. ProcRun is the same loop for one child.
// Children that live for the session (ProcKeep) join every round, so their
// pipes drain while arx waits for something else.

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
char** EnvWith(char* const* extra) {
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
static int Spawn(const Proc* p, Pipes* io, int want_in, pid_t* pid) {
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  if (want_in) {
    posix_spawn_file_actions_adddup2(&fa, io->in[0], 0);
  } else {
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  }
  posix_spawn_file_actions_adddup2(&fa, io->out[1], 1);
  posix_spawn_file_actions_adddup2(&fa, p->on_err ? io->err[1] : io->out[1], 2);
  if (p->on_fd3) posix_spawn_file_actions_adddup2(&fa, io->fd3[1], 3);
  if (p->dir) posix_spawn_file_actions_addchdir_np(&fa, p->dir);

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

// A started child and the state of its loop.
struct ProcChild {
  Proc p;  // a copy; its buffers and contexts belong to the caller
  Pipes io;
  pid_t pid;
  Buffer more;  // stdin queued by ProcWrite (Proc.open_in)
  size_t written;
  int closing;  // ProcClose: close stdin once `more` is written
  int status, reaped, killed, done;
  double start, kill_at, drain_until, deadline;
  ProcResult r;
};

// The session-lived children that every ProcPoll round serves.
static ProcChild** g_kept;
static int g_kept_count, g_kept_cap;

// Starts a child without waiting; see base.h.
ProcChild* ProcStart(const Proc* p) {
  Pipes io = {{-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}};
  int want_in = p->in || p->open_in;
  if ((want_in && PipeCloexec(io.in)) || PipeCloexec(io.out) ||
      (p->on_err && PipeCloexec(io.err)) ||
      (p->on_fd3 && PipeCloexec(io.fd3))) {
    ClosePipes(&io);
    return NULL;
  }
  ProcChild* c = XMalloc(sizeof(*c));
  memset(c, 0, sizeof(*c));
  c->p = *p;
  c->io = io;
  c->start = Now();
  int rc = Spawn(&c->p, &c->io, want_in, &c->pid);
  CloseFd(&c->io.in[0]);
  CloseFd(&c->io.out[1]);
  CloseFd(&c->io.err[1]);
  CloseFd(&c->io.fd3[1]);
  if (rc) {
    ClosePipes(&c->io);
    free(c);
    errno = rc;
    return NULL;
  }
  if (c->io.in[1] >= 0) fcntl(c->io.in[1], F_SETFL, O_NONBLOCK);
  c->deadline = p->timeout > 0 ? c->start + p->timeout : 0;
  return c;
}

// Queues stdin for a child started with open_in; see base.h.
void ProcWrite(ProcChild* c, const char* data, size_t n) {
  if (c->io.in[1] >= 0 && !c->closing) BufferAppend(&c->more, data, n);
}

// True when the child has ended and its output is read; see base.h.
int ProcDone(const ProcChild* c) { return c->done; }

// The stdin bytes still to write, and how many.
static const char* Pending(const ProcChild* c, size_t* n) {
  const char* data = c->p.open_in ? c->more.data : c->p.in;
  size_t len = c->p.open_in ? c->more.len : c->p.in_len;
  *n = len - c->written;
  return data ? data + c->written : NULL;
}

// Writes what the child can take now; closes a fixed stdin once it is all
// written.
static void Feed(ProcChild* c) {
  size_t n;
  const char* data = Pending(c, &n);
  ssize_t w = n ? write(c->io.in[1], data, n) : 0;
  if (w > 0) c->written += (size_t)w;
  if (w < 0 && errno != EAGAIN && errno != EINTR) {
    CloseFd(&c->io.in[1]);
  } else if (c->p.open_in && c->written == c->more.len) {
    c->more.len = c->written = 0;
    if (c->closing) CloseFd(&c->io.in[1]);
  } else if (!c->p.open_in && c->written >= c->p.in_len) {
    CloseFd(&c->io.in[1]);
  }
}

// Closes stdin once the queued bytes are written; see base.h.
void ProcClose(ProcChild* c) {
  size_t n;
  c->closing = 1;
  Pending(c, &n);
  if (!n) CloseFd(&c->io.in[1]);
}

// Reaps the child, and stops it at its deadline or on Ctrl-C.
static void Check(ProcChild* c) {
  if (!c->reaped && waitpid(c->pid, &c->status, WNOHANG) == c->pid) {
    c->reaped = 1;
    c->drain_until = Now() + kDrainSeconds;
    CloseFd(&c->io.in[1]);
  }
  double t = Now();
  int stop = g_interrupted && !c->p.keep_on_interrupt;
  if (!c->reaped && !c->killed && (stop || (c->deadline && t > c->deadline))) {
    if (stop) {
      c->r.interrupted = 1;
    } else {
      c->r.timed_out = 1;
    }
    kill(-c->pid, SIGTERM);
    c->killed = 1;
    c->kill_at = t + kKillGraceSeconds;
  } else if (!c->reaped && c->killed && t > c->kill_at) {
    kill(-c->pid, SIGKILL);
    c->kill_at = t + 1e9;
  }
  int open = c->io.out[0] >= 0 || c->io.err[0] >= 0 || c->io.fd3[0] >= 0;
  if (c->reaped && (!open || t >= c->drain_until)) c->done = 1;
}

// Adds a child's open pipes to the poll set; `slot[k]` maps each entry
// back to its child.
static void AddChild(ProcChild* c, int k, struct pollfd* pf, int* slot,
                     int* n) {
  size_t pending;
  Pending(c, &pending);
  int fds[] = {c->io.in[1], c->io.out[0], c->io.err[0], c->io.fd3[0]};
  for (int i = 0; i < 4; i++) {
    if (fds[i] < 0 || (i == 0 && c->p.open_in && !pending)) continue;
    slot[*n] = k;
    PollAdd(pf, n, fds[i], i ? POLLIN : POLLOUT);
  }
}

// Handles the events of one poll entry.
static void Serve(ProcChild* c, const struct pollfd* e) {
  if (!e->revents) return;
  if (e->fd == c->io.in[1]) Feed(c);
  if (e->fd == c->io.out[0]) Pump(&c->io.out[0], c->p.on_out, c->p.out_ctx);
  if (e->fd == c->io.err[0]) Pump(&c->io.err[0], c->p.on_err, c->p.err_ctx);
  if (e->fd == c->io.fd3[0]) Pump(&c->io.fd3[0], c->p.on_fd3, c->p.fd3_ctx);
}

// Keeps a child for the session; see base.h.
void ProcKeep(ProcChild* c) {
  for (int k = 0; k < g_kept_count; k++) {
    if (g_kept[k] == c) return;
  }
  if (g_kept_count == g_kept_cap) {
    g_kept_cap = g_kept_cap ? 2 * g_kept_cap : 8;
    g_kept = XRealloc(g_kept, (size_t)g_kept_cap * sizeof(*g_kept));
  }
  g_kept[g_kept_count++] = c;
}

// Hands a kept child back to its owner; see base.h.
void ProcRelease(ProcChild* c) {
  for (int k = 0; k < g_kept_count; k++) {
    if (g_kept[k] != c) continue;
    g_kept[k] = g_kept[--g_kept_count];
    return;
  }
}

// Starts stopping the child's group; see base.h.
void ProcStop(ProcChild* c) {
  if (c->done || c->killed) return;
  CloseFd(&c->io.in[1]);
  kill(-c->pid, SIGTERM);
  c->killed = 1;
  c->kill_at = Now() + kKillGraceSeconds;
}

// The caller's children, then the kept ones it did not list. Free the array.
static ProcChild** Round(ProcChild* const* kids, int count, int* total) {
  ProcChild** all = XMalloc((size_t)(count + g_kept_count + 1) * sizeof(*all));
  int m = 0;
  for (int k = 0; k < count; k++) all[m++] = kids[k];
  for (int j = 0; j < g_kept_count; j++) {
    int listed = 0;
    for (int k = 0; k < count && !listed; k++) listed = kids[k] == g_kept[j];
    if (!listed) all[m++] = g_kept[j];
  }
  *total = m;
  return all;
}

// True while only a short wait sees what `c` needs next: its timeout, the
// SIGKILL after a stop, or an exit that no open pipe reports.
static int NeedsTick(const ProcChild* c) {
  int open = c->io.out[0] >= 0 || c->io.err[0] >= 0 || c->io.fd3[0] >= 0;
  return !c->reaped && (c->deadline || c->killed || !open);
}

// One round of the loop for many children; see base.h.
void ProcPoll(ProcChild* const* kids, int count, double max_wait) {
  ProcPollWith(kids, count, NULL, 0, max_wait > 0.1 ? 0.1 : max_wait);
}

// One round that also waits on the caller's poll entries; see base.h.
void ProcPollWith(ProcChild* const* kids, int count, struct pollfd* extra,
                  int n_extra, double max_wait) {
  ProcChild** all = Round(kids, count, &count);
  size_t room = (size_t)(4 * count + n_extra + 1);
  struct pollfd* pf = XMalloc(room * sizeof(*pf));
  int* slot = XMalloc(room * sizeof(*slot));
  int n = 0, tick = g_interrupted != 0;
  double wait = max_wait;
  for (int k = 0; k < count; k++) {
    ProcChild* c = all[k];
    if (c->done) continue;
    AddChild(c, k, pf, slot, &n);
    tick |= NeedsTick(c);
    if (c->reaped && c->drain_until - Now() < wait) {
      wait = c->drain_until - Now();
    }
  }
  if (tick && wait > 0.1) wait = 0.1;  // see exits, timeouts and Ctrl-C
  if (wait < 0) wait = 0;
  int own = n;
  for (int i = 0; i < n_extra; i++) {
    pf[n] = extra[i];
    pf[n++].revents = extra[i].revents = 0;
  }
  int wait_ms = n ? (int)(wait * 1000) + 1 : 1;  // no pipes: wait for exit
  if (poll(n ? pf : NULL, (nfds_t)n, wait_ms) > 0) {
    for (int i = 0; i < own; i++) Serve(all[slot[i]], &pf[i]);
    for (int i = own; i < n; i++) extra[i - own].revents = pf[i].revents;
  }
  for (int k = 0; k < count; k++) {
    if (!all[k]->done) Check(all[k]);
  }
  free(all);
  free(pf);
  free(slot);
}

// Stops the child if it still runs, then frees it; see base.h.
void ProcFinish(ProcChild* c, ProcResult* r) {
  ProcRelease(c);
  ProcStop(c);
  while (!c->done) ProcPoll(&c, 1, 0.1);
  ClosePipes(&c->io);
  if (c->killed) kill(-c->pid, SIGKILL);  // anything left in the group
  c->r.secs = Now() - c->start;
  int s = c->status;
  c->r.code = WIFEXITED(s) ? WEXITSTATUS(s) : 128 + WTERMSIG(s);
  *r = c->r;
  BufferFree(&c->more);
  free(c);
}

// Runs the child to completion; see base.h.
int ProcRun(const Proc* p, ProcResult* r) {
  ProcChild* c = ProcStart(p);
  if (!c) {
    memset(r, 0, sizeof(*r));
    r->code = -1;
    r->spawn_failed = 1;
    return -1;
  }
  while (!c->done) ProcPoll(&c, 1, 0.1);
  ProcFinish(c, r);
  return 0;
}
