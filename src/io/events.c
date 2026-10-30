// events.c: writes the event stream to the session file, the --events target
// and observers. Observer pipes are non-blocking: a slow observer loses
// events, never the run.

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "src/io/io.h"

extern char** environ;

Events g_events = {.fd = -1, .extra_fd = -1};

// Model text is batched into one model.delta event per this many seconds.
static const double kDeltaSeconds = 0.05;

// Opens an event target: "-" (stdout), "fd:N", or a file to append to.
static int OpenTarget(const char* where) {
  int fd;
  if (!strcmp(where, "-")) {
    fd = dup(1);
  } else if (!strncmp(where, "fd:", 3)) {
    fd = atoi(where + 3);
    if (fcntl(fd, F_GETFD) < 0) return -1;
  } else {
    fd = open(where, O_WRONLY | O_CREAT | O_APPEND, 0644);
  }
  if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);  // tools must not inherit it
  return fd;
}

// Opens the sinks; see io.h.
int EventsOpen(const char* session_file, const char* extra) {
  g_events.fd = session_file ? OpenTarget(session_file) : -1;
  g_events.extra_fd = extra ? OpenTarget(extra) : -1;
  g_events.color = g_events.render && isatty(2) && !getenv("NO_COLOR");
  return extra && g_events.extra_fd < 0 ? -1 : 0;
}

// Starts an event with the fields every event has.
cJSON* EventNew(const char* type) {
  char time[32];
  IsoTime(time);
  cJSON* e = cJSON_CreateObject();
  cJSON_AddNumberToObject(e, "v", 1);
  cJSON_AddStringToObject(e, "t", time);
  cJSON_AddStringToObject(e, "session",
                          g_events.session ? g_events.session : "");
  cJSON_AddNumberToObject(e, "depth", g_events.depth);
  cJSON_AddNumberToObject(e, "turn", g_events.turn);
  cJSON_AddStringToObject(e, "type", type);
  return e;
}

// Writes one line to every sink.
static void WriteLine(const char* line, size_t n) {
  if (g_events.fd >= 0) WriteAll(g_events.fd, line, n);
  if (g_events.extra_fd >= 0) WriteAll(g_events.extra_fd, line, n);
  for (int i = 0; i < g_events.observer_count; i++) {
    int fd = g_events.observers[i];
    if (fd < 0) continue;
    ssize_t w = write(fd, line, n);
    if (w < 0 && errno == EPIPE) {
      close(fd);
      g_events.observers[i] = -1;
    } else if (w != (ssize_t)n) {
      g_events.dropped++;
    }
  }
}

// Serializes an event as one line and writes it.
static void WriteEvent(cJSON* e) {
  char* s = cJSON_PrintUnformatted(e);
  size_t n = strlen(s);
  s[n] = '\n';  // overwrite the NUL for one write; restored below
  WriteLine(s, n + 1);
  s[n] = 0;
  free(s);
}

// Sends batched model text.
void EventFlush(void) {
  if (!g_events.delta.len) return;
  cJSON* e = EventNew("model.delta");
  cJSON_AddStringToObject(e, "text", g_events.delta.data);
  g_events.delta.len = 0;
  WriteEvent(e);
  cJSON_Delete(e);
}

// Pending model text goes first so the stream stays in order.
void EventSend(cJSON* event) {
  EventFlush();
  WriteEvent(event);
  if (g_events.render) RenderEvent(event, 0);
  cJSON_Delete(event);
}

// Shows model text at once; batches it for the event stream.
void EventDelta(const char* text, size_t n) {
  if (g_events.render) {
    char* s = XStrndup(text, n);
    RenderText(g_events.depth, s);
    free(s);
  }
  BufferAppend(&g_events.delta, text, n);
  double t = Now();
  if (t - g_events.delta_time > kDeltaSeconds || g_events.delta.len > 1024) {
    EventFlush();
    g_events.delta_time = t;
  }
}

// A subagent's line is already a complete event with its own depth.
void EventForward(const char* line, size_t n) {
  EventFlush();
  WriteLine(line, n);
  if (line[n - 1] != '\n') WriteLine("\n", 1);
  if (!g_events.render) return;
  char* s = XStrndup(line, n);
  cJSON* e = cJSON_Parse(s);
  if (e) RenderEvent(e, 1);
  cJSON_Delete(e);
  free(s);
}

// Spawns an observer reading the stream from a non-blocking pipe.
void EventsAddObserver(const char* command) {
  int p[2];
  if (g_events.observer_count >= ARX_MAX_OBSERVERS || pipe(p)) return;
  fcntl(p[1], F_SETFD, FD_CLOEXEC);
  fcntl(p[1], F_SETFL, O_NONBLOCK);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[0], 0);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  char* argv[] = {"sh", "-c", (char*)command, NULL};
  pid_t pid;
  if (posix_spawnp(&pid, "sh", &fa, NULL, argv, environ) == 0) {
    g_events.observer_pids[g_events.observer_count] = pid;
    g_events.observers[g_events.observer_count++] = p[1];
  } else {
    close(p[1]);
  }
  posix_spawn_file_actions_destroy(&fa);
  close(p[0]);
}

// Observers see end of file and get up to a second each to finish.
void EventsClose(void) {
  EventFlush();
  for (int i = 0; i < g_events.observer_count; i++) {
    if (g_events.observers[i] >= 0) close(g_events.observers[i]);
  }
  for (int i = 0; i < g_events.observer_count; i++) {
    for (int k = 0; k < 100; k++) {
      if (waitpid(g_events.observer_pids[i], NULL, WNOHANG) != 0) break;
      SleepSeconds(0.01);
    }
  }
  if (g_events.fd >= 0) close(g_events.fd);
  if (g_events.extra_fd >= 0) close(g_events.extra_fd);
  g_events.fd = g_events.extra_fd = -1;
  g_events.observer_count = 0;
  BufferFree(&g_events.delta);
}
