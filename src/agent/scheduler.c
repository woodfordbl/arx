// scheduler.c: a scheduler plugin, which decides when the queued tool calls
// run. It is one long-lived process for each session: an executable file
// named `scheduler` at the top of a layer (the first in layer order wins).
// arx and the process exchange one JSON object per line; when the process
// exits or prints a bad line, arx says so and uses the built-in scheduler.

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// The session's scheduler process.
static struct {
  char* path;        // the running plugin, or NULL
  char* failed;      // a plugin that failed; it is not started again
  ProcChild* child;  // its process
  Buffer out;        // what it printed that is not read yet
  double wake_at;    // when it wants a tick (unix seconds), or 0
} g_sched;

// The wall clock in unix seconds, as the protocol uses.
static double UnixNow(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

// DataFn that drops the plugin's stderr, so it never mixes with its answers.
static void Discard(void* ctx, const char* data, size_t n) {
  (void)ctx;
  (void)data;
  (void)n;
}

// Stops the process and forgets it.
static void Stop(void) {
  if (g_sched.child) {
    ProcResult r;
    ProcFinish(g_sched.child, &r);
  }
  free(g_sched.path);
  g_sched.path = NULL;
  g_sched.child = NULL;
  g_sched.out.len = 0;
  g_sched.wake_at = 0;
}

// Reports why the plugin stopped scheduling, and stops it.
static void Fail(const char* why) {
  cJSON* e = EventNew("error");
  char* text = XAsprintf("scheduler %s: %s; using the built-in scheduler",
                         g_sched.path, why);
  JsonAddTruncated(e, "error", text, 1000);
  EventSend(e);
  free(text);
  free(g_sched.failed);
  g_sched.failed = XStrdup(g_sched.path);
  Stop();
}

// The first executable `scheduler` at the top of a layer, and its layer.
static char* Find(Agent* a, const Layer** layer) {
  for (int l = 0; l < a->spec.layer_count; l++) {
    // A path with a slash, so the spawn does not look it up in PATH.
    const char* dir = a->spec.layers[l].dir;
    char* path = strchr(dir, '/') ? PathJoin(dir, "scheduler")
                                  : XAsprintf("./%s/scheduler", dir);
    if (IsRunnable(path)) {
      *layer = &a->spec.layers[l];
      return path;
    }
    free(path);
  }
  return NULL;
}

// Starts or stops the plugin to match the layers; see agent.h.
int SchedOpen(Agent* a) {
  const Layer* layer = NULL;
  char* path = Find(a, &layer);
  if (g_sched.path && (!path || strcmp(path, g_sched.path))) Stop();
  if (!path || (g_sched.failed && !strcmp(path, g_sched.failed))) {
    free(path);
    return g_sched.child != NULL;
  }
  if (g_sched.child) {
    free(path);
    return 1;
  }
  g_sched.path = path;
  char** env = ToolEnv(a, layer->plugin ? layer->dir : NULL);
  char* argv[] = {path, NULL};
  Proc p = {.argv = argv,
            .env = env,
            .open_in = 1,
            .keep_on_interrupt = 1,
            .on_out = BufferSink,
            .out_ctx = &g_sched.out,
            .on_err = Discard};
  g_sched.child = ProcStart(&p);
  FreeEnv(env);
  if (!g_sched.child) Fail("could not start it");
  return g_sched.child != NULL;
}

// True while a plugin schedules; see agent.h.
int SchedActive(void) { return g_sched.child != NULL; }

// The plugin's process, for ProcPoll; see agent.h.
ProcChild* SchedChild(void) { return g_sched.child; }

// Sends one message (consumed) as a line.
static void Send(cJSON* message) {
  if (!g_sched.child) {
    cJSON_Delete(message);
    return;
  }
  char* line = cJSON_PrintUnformatted(message);
  ProcWrite(g_sched.child, line, strlen(line));
  ProcWrite(g_sched.child, "\n", 1);
  free(line);
  cJSON_Delete(message);
}

// Tells the plugin that a call is queued; see agent.h.
void SchedReady(const char* id, const char* name, cJSON* keys) {
  cJSON* m = cJSON_CreateObject();
  cJSON* r = cJSON_AddObjectToObject(m, "ready");
  cJSON_AddStringToObject(r, "id", id);
  cJSON_AddStringToObject(r, "name", name);
  cJSON_AddItemToObject(r, "keys", cJSON_Duplicate(keys, 1));
  Send(m);
}

// Tells the plugin that a call ended; see agent.h.
void SchedDone(const char* id, double secs, int is_error, cJSON* backoff) {
  cJSON* m = cJSON_CreateObject();
  cJSON* d = cJSON_AddObjectToObject(m, "done");
  cJSON_AddStringToObject(d, "id", id);
  cJSON_AddNumberToObject(d, "secs", secs);
  cJSON_AddBoolToObject(d, "is_error", is_error);
  cJSON_AddItemToObject(
      d, "backoff", backoff ? cJSON_Duplicate(backoff, 1) : cJSON_CreateNull());
  Send(m);
}

// Seconds until the plugin's tick is due, at most `max`; see agent.h.
double SchedWait(double max) {
  if (!g_sched.child || !g_sched.wake_at) return max;
  double wait = g_sched.wake_at - UnixNow();
  return wait < 0 ? 0 : wait < max ? wait : max;
}

// Reads one line from the plugin into `start` and `results`. Returns 0, or
// -1 when the line is not a message arx knows.
static int Read(const char* line, cJSON* start, cJSON* results) {
  cJSON* m = cJSON_Parse(line);
  cJSON* ids = cJSON_GetObjectItem(m, "start");
  cJSON* wake = cJSON_GetObjectItem(m, "wake_at");
  cJSON* result = cJSON_GetObjectItem(m, "result");
  int ok = cJSON_IsObject(m) && (ids || wake || result);
  if (ids && !KeysValid(ids)) ok = 0;  // a list of strings, as keys are
  if (wake && !cJSON_IsNumber(wake)) ok = 0;
  const char* id = JsonStr(result, "id", NULL);
  const char* text = JsonStr(result, "text", NULL);
  if (result && (!id || !text)) ok = 0;
  if (ok) {
    cJSON* s;
    cJSON_ArrayForEach(s, ids) {
      cJSON_AddItemToArray(start, cJSON_CreateString(s->valuestring));
    }
    if (wake) g_sched.wake_at = wake->valuedouble;
    if (result) cJSON_AddStringToObject(results, id, text);
  }
  cJSON_Delete(m);
  return ok ? 0 : -1;
}

// Handles what the plugin printed and sends a due tick; see agent.h.
void SchedPoll(cJSON* start, cJSON* results) {
  if (!g_sched.child) return;
  char* nl;
  while (g_sched.out.len &&
         (nl = memchr(g_sched.out.data, '\n', g_sched.out.len))) {
    *nl = 0;
    size_t len = (size_t)(nl - g_sched.out.data) + 1;
    int blank = !g_sched.out.data[strspn(g_sched.out.data, " \t\r")];
    if (!blank && Read(g_sched.out.data, start, results)) {
      char* why = XAsprintf("printed a bad line: %.200s", g_sched.out.data);
      Fail(why);
      free(why);
      return;
    }
    memmove(g_sched.out.data, g_sched.out.data + len, g_sched.out.len - len);
    g_sched.out.len -= len;
  }
  if (ProcDone(g_sched.child)) {
    Fail("it exited");
    return;
  }
  double now = UnixNow();
  if (g_sched.wake_at && now >= g_sched.wake_at) {
    g_sched.wake_at = 0;
    cJSON* m = cJSON_CreateObject();
    cJSON_AddNumberToObject(m, "tick", now);
    Send(m);
  }
}
