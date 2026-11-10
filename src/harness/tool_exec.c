// tool_exec.c: starts and ends one tool call; the runtime runs many at
// once. Output goes to a file in the session, and the model sees only its
// head and tail. Subagents are this same binary run one level deeper, with
// their events forwarded into ours.

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/mcp/mcp.h"

// Captured output: the head and tail in memory, everything in a file.
typedef struct Capture {
  Buffer head, tail;
  size_t total, head_max, tail_max;
  int fd;
} Capture;

// DataFn: saves output to the file and keeps the head and the tail.
static void CaptureSink(void* ctx, const char* data, size_t n) {
  Capture* c = ctx;
  if (c->fd >= 0) WriteAll(c->fd, data, n);
  c->total += n;
  if (c->head.len < c->head_max) {
    size_t room = c->head_max - c->head.len;
    BufferAppend(&c->head, data, n < room ? n : room);
  }
  BufferAppend(&c->tail, data, n);
  if (c->tail.len > 2 * c->tail_max + 65536) {  // trim now and then, not always
    memmove(c->tail.data, c->tail.data + c->tail.len - c->tail_max,
            c->tail_max);
    c->tail.len = c->tail_max;
  }
}

// What the model sees: all of a short output, or head + marker + tail.
static char* CaptureText(const Capture* c, const char* path) {
  Buffer b = {0};
  BufferAppend(&b, NULL, 0);
  BufferAppend(&b, c->head.data, c->head.len);
  if (c->total > c->head_max + c->tail_max) {
    BufferPrintf(&b, "\n[... %zu bytes omitted; full output: %s ...]\n",
                 c->total - c->head_max - c->tail_max, path);
    BufferAppend(&b, c->tail.data + c->tail.len - c->tail_max, c->tail_max);
  } else if (c->total > c->head_max) {
    size_t rest = c->total - c->head_max;
    BufferAppend(&b, c->tail.data + c->tail.len - rest, rest);
  }
  char* text = Utf8Clean(b.data, b.len);
  BufferFree(&b);
  return text;
}

// ARX_* variables so tools and hooks know where they run. A plugin's
// folders are named from its name, never from the resolved folder, so a
// linked plugin gets the folders of its name. arx makes neither folder.
char** ToolEnv(Agent* a, const char* plugin_dir, const char* plugin) {
  char buf[4096];
  const char* cwd = getcwd(buf, sizeof(buf)) ? buf : ".";
  char** env = XMalloc(12 * sizeof(*env));
  int n = 0;
  env[n++] = XAsprintf("ARX_SESSION=%s", a->session.id);
  env[n++] = XAsprintf("ARX_SESSION_DIR=%s", a->session.dir);
  env[n++] = XAsprintf("ARX_TURN=%d", a->session.turns);
  env[n++] = XAsprintf("ARX_CWD=%s", cwd);
  env[n++] = XAsprintf("ARX_SPEC=%s", a->spec.path);
  env[n++] = XAsprintf("ARX_SPEC_DIR=%s", a->spec.dir);
  env[n++] = XAsprintf("ARX_DEPTH=%d", a->depth);
  env[n++] = XAsprintf("ARX_BIN=%s", g_self);
  if (plugin_dir) env[n++] = XAsprintf("ARX_PLUGIN_DIR=%s", plugin_dir);
  if (plugin) {
    env[n++] = XAsprintf("ARX_STATE_DIR=%s/plugins/%s", a->session.dir, plugin);
    env[n++] = XAsprintf("ARX_DATA_DIR=%s/.arx/data/%s", cwd, plugin);
  }
  env[n] = NULL;
  return env;
}

// ToolEnv for a layer's program, plus ARX_PLUGIN_SETTINGS (its settings
// from the active list, as JSON) for a plugin's; see harness.h.
char** PluginEnv(Agent* a, const Layer* layer) {
  char** env = ToolEnv(a, layer->plugin ? layer->dir : NULL, layer->plugin);
  if (!layer->plugin) return env;
  int n = 0;
  while (env[n]) n++;
  env = XRealloc(env, (size_t)(n + 2) * sizeof(*env));
  char* json =
      layer->settings ? cJSON_PrintUnformatted(layer->settings) : XStrdup("{}");
  env[n] = XAsprintf("ARX_PLUGIN_SETTINGS=%s", json);
  env[n + 1] = NULL;
  free(json);
  return env;
}

// Frees the strings and the array.
void FreeEnv(char** env) {
  for (char** p = env; *p; p++) free(*p);
  free(env);
}

// DataFn for a subagent's fd 3: forwards each complete event line.
static void ForwardSink(void* ctx, const char* data, size_t n) {
  Buffer* b = ctx;
  BufferAppend(b, data, n);
  char* nl;
  while (b->len && (nl = memchr(b->data, '\n', b->len))) {
    size_t len = (size_t)(nl - b->data) + 1;
    EventForward(b->data, len);
    memmove(b->data, b->data + len, b->len - len);
    b->len -= len;
  }
}

// A tool call that runs: its process and what it collects.
struct ToolRun {
  ToolKind kind;
  double timeout;
  Capture cap;
  Buffer out, forward;  // a subagent's --json answer, and its event lines
  char** env;
  char* input;  // stdin, kept until the process ends
  char* path;   // the full output
  ProcChild* child;
  McpCall* mcp;  // an MCP call has no process of its own
};

// Starts a subagent: `arx -p - --spec <path> --json --events fd:3`, with our
// caps and one more level of depth. Each subagent forwards its own events,
// one whole line at a time, so several can run at once.
static ProcChild* StartSubagent(Agent* a, Tool* t, ToolRun* run) {
  int k = 0;
  char** argv = XMalloc((size_t)(12 + 2 * a->cap_count) * sizeof(*argv));
  char* fixed[] = {g_self,   "-p",      "-",        "--spec", t->path,
                   "--json", "--quiet", "--events", "fd:3"};
  for (size_t i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++) {
    argv[k++] = fixed[i];
  }
  for (int i = 0; i < a->cap_count; i++) {
    argv[k++] = "--cap";
    argv[k++] = a->cap_args[i];
  }
  argv[k] = NULL;
  free(run->env[6]);
  run->env[6] = XAsprintf("ARX_DEPTH=%d", a->depth + 1);
  Proc p = {.argv = argv,
            .in = run->input,
            .in_len = strlen(run->input),
            .timeout = t->timeout,
            .env = run->env,
            .on_out = BufferSink,
            .out_ctx = &run->out,
            .on_err = CaptureSink,
            .err_ctx = &run->cap,
            .on_fd3 = ForwardSink,
            .fd3_ctx = &run->forward};
  ProcChild* child = ProcStart(&p);
  free(argv);
  return child;
}

// Turns a subagent's --json output and exit code into the tool result.
static char* SubagentResult(const Buffer* out, const Capture* cap,
                            const char* path, int code) {
  cJSON* result = cJSON_Parse(out->data ? out->data : "");
  const char* answer = JsonStr(result, "final_output", "");
  char* text;
  if (code == kExitDone) {
    text = XStrdup(answer);
  } else if (code == kExitCap) {
    text = XAsprintf("[the subagent stopped at a cap]\n%s", answer);
  } else {
    char* err = CaptureText(cap, path);
    text = XAsprintf("[the subagent failed with exit %d]\n%s%s", code, answer,
                     err);
    free(err);
  }
  cJSON_Delete(result);
  return text;
}

// Output plus a status line for timeouts, interrupts and non-zero exits.
static char* ProcessResult(const Capture* cap, const char* path,
                           const ProcResult* r, double timeout) {
  char* body = CaptureText(cap, path);
  Buffer b = {0};
  BufferAppendStr(&b, *body || r->code ? body : "(no output)");
  if (r->timed_out) {
    BufferPrintf(&b,
                 "\n[timed out after %.0fs; the process group was "
                 "killed]",
                 timeout);
  } else if (r->interrupted) {
    BufferAppendStr(&b, "\n[interrupted]");
  } else if (r->code) {
    BufferPrintf(&b, "\n[exit code %d]", r->code);
  }
  free(body);
  return BufferTake(&b);
}

// Checks the arguments a tool needs; returns an error message or NULL.
static char* CheckArgs(const Tool* t, cJSON* args) {
  if (t->kind == kToolAgent && !JsonStr(args, "task", NULL)) {
    return XStrdup("this subagent needs a string argument `task`");
  }
  return NULL;
}

// Finds a tool by name; see harness.h.
Tool* ToolFind(Agent* a, const char* name) {
  for (int i = 0; i < a->tools.count; i++) {
    if (!strcmp(a->tools.items[i].name, name)) return &a->tools.items[i];
  }
  return McpToolFor(a, name);
}

// Starts a tool: an executable or a subagent as a process, an MCP tool as
// a call on its server. The run has no child when the process did not
// start.
static ToolRun* StartProcessTool(Agent* a, Tool* t, cJSON* args,
                                 const char* raw, char* path,
                                 cJSON* end_event) {
  ToolRun* run = XMalloc(sizeof(*run));
  memset(run, 0, sizeof(*run));
  run->kind = t->kind;
  run->timeout = t->timeout;
  run->path = path;
  run->cap.head_max = JsonSize(a->spec.root, "tool_output.head", 2048);
  run->cap.tail_max = JsonSize(a->spec.root, "tool_output.tail", 6144);
  run->cap.fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  run->env = ToolEnv(a, t->plugin_dir, t->plugin);
  if (t->kind == kToolMcp) {
    if (t->server) cJSON_AddStringToObject(end_event, "server", t->server);
    run->mcp =
        McpCallStart(a, t, args, JsonStr(end_event, "id", ""), run->path);
  } else if (t->kind == kToolAgent) {
    run->input = XStrdup(JsonStr(args, "task", ""));
    run->child = StartSubagent(a, t, run);
  } else {
    // A file that only hands over to `arx tool NAME` starts as arx itself.
    char* file_argv[] = {t->path, NULL};
    char* core_argv[] = {g_self, "tool", t->core, NULL};
    run->input = XStrdup(raw);
    Proc p = {.argv = t->core ? core_argv : file_argv,
              .in = run->input,
              .in_len = strlen(run->input),
              .timeout = t->timeout,
              .env = run->env,
              .on_out = CaptureSink,
              .out_ctx = &run->cap};
    run->child = ProcStart(&p);
  }
  return run;
}

// The process of a started call; see harness.h.
ProcChild* ToolChild(ToolRun* run) { return run->child; }

// True when the call ended; see harness.h.
int ToolDone(ToolRun* run) {
  return run->mcp ? McpCallDone(run->mcp) : ProcDone(run->child);
}

// Ends a started call and frees it; see harness.h.
char* ToolFinish(ToolRun* run, int* is_error, cJSON* end_event) {
  ProcResult r = {.code = -1, .spawn_failed = 1};
  int saved = errno;
  if (run->child) ProcFinish(run->child, &r);
  char* text = NULL;
  if (run->mcp) {  // its text gets the same head and tail cut as any output
    memset(&r, 0, sizeof(r));
    char* full = McpCallFinish(run->mcp, &r.code, &r.secs);
    CaptureSink(&run->cap, *full ? full : "(no output)",
                *full ? strlen(full) : 11);
    text = CaptureText(&run->cap, run->path);
    free(full);
  } else if (r.spawn_failed) {
    text = XAsprintf("could not start the tool: %s", strerror(saved));
  } else if (run->kind == kToolAgent) {
    text = SubagentResult(&run->out, &run->cap, run->path, r.code);
  } else {
    text = ProcessResult(&run->cap, run->path, &r, run->timeout);
  }
  if (run->cap.fd >= 0) close(run->cap.fd);
  *is_error = r.spawn_failed || r.code != 0 || r.timed_out;
  cJSON_AddNumberToObject(end_event, "exit", r.code);
  cJSON_AddNumberToObject(end_event, "secs", r.secs);
  cJSON_AddNumberToObject(end_event, "bytes", (double)run->cap.total);
  cJSON_AddStringToObject(end_event, "path", run->path);
  BufferFree(&run->cap.head);
  BufferFree(&run->cap.tail);
  BufferFree(&run->out);
  BufferFree(&run->forward);
  FreeEnv(run->env);
  free(run->input);
  free(run);
  return text;
}

// Starts one tool call; see harness.h.
ToolRun* ToolStart(Agent* a, const char* name, const char* args, char** text,
                   int* is_error, char** output_path, cJSON* end_event) {
  *is_error = 1;
  *output_path = NULL;
  *text = NULL;
  Tool* t = ToolFind(a, name);
  if (!t) {
    Buffer names = {0};
    for (int i = 0; i < a->tools.count; i++) {
      BufferPrintf(&names, "%s%s", i ? ", " : "", a->tools.items[i].name);
    }
    *text = XAsprintf("unknown tool \"%s\" (available: %s)", name,
                      names.data ? names.data : "none");
    BufferFree(&names);
    return NULL;
  }
  const char* raw = args && *args ? args : "{}";
  cJSON* parsed = cJSON_Parse(raw);
  ToolRun* run = NULL;
  if (!cJSON_IsObject(parsed)) {
    *text = XAsprintf("the arguments are not a valid JSON object: %.200s", raw);
  } else if (!(*text = CheckArgs(t, parsed))) {
    *output_path = SessionOutputPath(&a->session);
    run = StartProcessTool(a, t, parsed, raw, *output_path, end_event);
    if (!run->child && !run->mcp) {  // report it at once, with the end fields
      *text = ToolFinish(run, is_error, end_event);
      run = NULL;
    }
  }
  cJSON_Delete(parsed);
  return run;
}
