// run.c: the session lifecycle around the loop: load the spec, open
// or resume the session, start the event stream and observers, run headless
// or interactively, and report the result. No background call outlives the
// session, or in interactive mode the turn: they are stopped first.

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"
#include "src/io/io.h"

// The "status" for an exit code.
static const char* StatusName(int code) {
  switch (code) {
    case kExitDone:
      return "done";
    case kExitCap:
      return "cap";
    case kExitAuth:
      return "auth";
    case kExitPolicy:
      return "policy";
    case kExitInterrupted:
      return "interrupted";
    default:
      return "error";
  }
}

// Opens or resumes the session and points the event stream at it.
// Returns 0 or an exit code.
static int OpenSession(Agent* a) {
  int failed = a->resume ? SessionResume(&a->session, a->resume, &a->messages)
                         : SessionNew(&a->session, a->depth);
  if (failed) {
    fprintf(stderr, "arx: cannot %s session %s\n",
            a->resume ? "resume" : "create", a->resume ? a->resume : "");
    return a->resume ? kExitUsage : kExitError;
  }
  if (!a->resume) a->messages = cJSON_CreateArray();
  g_events.session = a->session.id;
  g_events.depth = a->depth;
  g_events.turn = a->session.turns;
  g_events.render = !a->quiet;
  char* path = XAsprintf("%s/events.jsonl", a->session.dir);
  int bad = EventsOpen(path, a->events);
  free(path);
  if (bad) {
    fprintf(stderr, "arx: cannot open --events %s\n", a->events);
    return kExitUsage;
  }
  return 0;
}

// Loads the harness and starts the session. Returns 0 or an exit code.
static int Start(Agent* a) {
  Buffer err = {0};
  if (PolicyResolve(&a->policy, &err) ||
      SpecLoad(a->spec_path, a->sets, a->policy, &a->spec, &err)) {
    fputs(err.data, stderr);
    BufferFree(&err);
    return kExitUsage;
  }
  int code = OpenSession(a);
  if (code) return code;
  cJSON* observer;
  // Observers get the same ARX_* variables as tools; a plugin's observer
  // gets its own from the wrapper that plugins.c puts around it.
  char** env = ToolEnv(a, NULL, NULL);
  cJSON_ArrayForEach(observer, JsonGet(a->spec.root, "observers")) {
    if (cJSON_IsString(observer)) EventsAddObserver(observer->valuestring, env);
  }
  FreeEnv(env);
  ToolsBuild(a);
  GateOpen(a);  // the files on disk at the start are the accepted ones
  cJSON* e = EventNew("session.start");
  cJSON_AddStringToObject(e, "name", JsonStr(a->spec.root, "name", "agent"));
  cJSON_AddStringToObject(e, "model", JsonStr(a->spec.root, "model", ""));
  cJSON_AddStringToObject(e, "spec", a->spec.path);
  cJSON_AddBoolToObject(e, "resumed", a->resume != NULL);
  cJSON_AddNumberToObject(e, "tools", a->tools.count);
  cJSON_AddNumberToObject(e, "context_window",
                          JsonNum(a->spec.root, "context_window", 128000));
  char cwd[4096];
  cJSON_AddStringToObject(e, "cwd", getcwd(cwd, sizeof(cwd)) ? cwd : "");
  cJSON* names = a->spec.policy ? cJSON_AddArrayToObject(e, "policy") : NULL;
  for (int l = 0; names && l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    if (!layer->policy) continue;
    cJSON_AddItemToArray(names, cJSON_CreateString(layer->plugin));
  }
  EventSend(e);
  // The calls a stopped session left in flight become notes.
  if (a->resume) CallsResume(a);
  return 0;
}

// Starts a conversation: system prompt, session_start hook, first message.
static void Begin(Agent* a, const char* prompt) {
  char* system = SystemPrompt(a);
  AgentAddMessage(a, "system", system);
  free(system);
  cJSON* out = NULL;
  HookRun(a, "session_start", cJSON_CreateObject(), &out);
  char* first = FirstMessage(a, prompt);
  const char* context = JsonStr(out, "context", NULL);
  if (context) {
    char* joined = XAsprintf("%s\n\n%s", first, context);
    free(first);
    first = joined;
  }
  AgentAddMessage(a, "user", first);
  free(first);
  cJSON_Delete(out);
}

// Takes a prompt from the user into the session: sends prompt.start, then
// starts the conversation with it (`first`) or adds it as a user message.
static void Prompt(Agent* a, const char* text, int first) {
  cJSON* e = EventNew("prompt.start");
  JsonAddTruncated(e, "text", text, 65536);
  EventSend(e);
  if (first) {
    Begin(a, text);
  } else {
    AgentAddMessage(a, "user", text);
  }
}

// Adds what session.end and prompt.end share: the status for `code` and the
// session's totals.
static void AddTotals(Agent* a, cJSON* e, int code) {
  cJSON_AddStringToObject(e, "status", StatusName(code));
  cJSON_AddNumberToObject(e, "turns", a->session.turns);
  cJSON_AddNumberToObject(
      e, "tokens", (double)(a->session.tokens_in + a->session.tokens_out));
  cJSON_AddNumberToObject(e, "cost", a->session.cost);
}

// Headless: one task, run until the agent stops.
static int Headless(Agent* a) {
  if (!a->resume || (a->prompt && *a->prompt)) {
    Prompt(a, a->prompt ? a->prompt : "", !a->resume);
  }
  return RunTurns(a);
}

// Reads the next line of stdin through `in` (malloc'd, no newline), or NULL
// at the end of input. With `retry`, a signal is not the end: Ctrl-C only
// ends a prompt, so one that lands after the prompt ended is dropped and
// the read goes on. SIGTERM still ends the input.
static char* ReadLine(Buffer* in, int retry) {
  for (;;) {
    if (retry && g_interrupted == SIGTERM) return NULL;
    if (retry) g_interrupted = 0;
    char* line = LinePop(in);
    if (line) return line;
    char chunk[4096];
    ssize_t n = read(0, chunk, sizeof(chunk));
    if (n > 0) {
      BufferAppend(in, chunk, (size_t)n);
    } else if (n == 0 || errno != EINTR || !retry) {
      return n == 0 && in->len ? BufferTake(in) : NULL;  // a last line
    }
  }
}

// The prompt of one --input jsonl line (consumed): {"prompt": "TEXT"}, with
// other keys ignored. Returns NULL for a blank line, and for any other line
// after an error event.
static char* JsonlPrompt(char* line) {
  cJSON* o = cJSON_Parse(line);
  const char* text = cJSON_IsObject(o) ? JsonStr(o, "prompt", NULL) : NULL;
  char* prompt = text && *text ? XStrdup(text) : NULL;
  if (!prompt && line[strspn(line, " \t\r")]) {
    char* clean = Utf8Clean(line, strlen(line));
    char* why = XAsprintf("bad input line: %s", clean);
    cJSON* e = EventNew("error");
    JsonAddTruncated(e, "error", why, 300);
    EventSend(e);
    free(why);
    free(clean);
  }
  cJSON_Delete(o);
  free(line);
  return prompt;
}

// Interactive: one prompt per line, from the terminal or as --input jsonl.
// Ctrl-C stops the current prompt. At the terminal, Ctrl-D, /exit or Ctrl-C
// at the prompt ends the session; with --input jsonl, the end of stdin does.
static int Interactive(Agent* a) {
  Buffer in = {0};
  char* first_prompt = NULL;
  int code = kExitDone, started = a->resume != NULL, jsonl = a->input_jsonl;
  for (;;) {
    if (!jsonl) {
      fputs(g_events.color ? "\n\033[1m› \033[0m" : "\n› ", stderr);
      g_interrupted = 0;
    }
    char* line = ReadLine(&in, jsonl);
    if (!line) break;
    if (jsonl) line = JsonlPrompt(line);
    int quit = !jsonl && (!strcmp(line, "/exit") || !strcmp(line, "/quit"));
    if (!line || !*line || quit) {
      free(line);
      if (quit) break;
      continue;
    }
    if (!started) {
      first_prompt = XStrdup(line);
      a->prompt = first_prompt;  // kept for {{prompt}} after a restart
    }
    Prompt(a, line, !started);
    free(line);
    started = 1;
    // This prompt's answer and its own `arx ctl stop`, not the last one's.
    free(a->final_output);
    a->final_output = NULL;
    a->stop_requested = 0;
    code = RunTurns(a);
    // The prompt cannot poll, so nothing runs on behind it: the calls in
    // flight end `stopped` before prompt.end, and their results reach the
    // agent with the next message.
    CallsShutdown(a);
    cJSON* e = EventNew("prompt.end");
    AddTotals(a, e, code);
    JsonAddTruncated(e, "final_output", a->final_output, 2000);
    EventSend(e);
    if (code == kExitInterrupted) {
      if (!jsonl) fputs("\n(interrupted)\n", stderr);
      code = kExitDone;
    } else if (code == kExitAuth) {
      break;
    }
  }
  if (jsonl && g_interrupted == SIGTERM) code = kExitInterrupted;
  BufferFree(&in);
  a->prompt = NULL;
  free(first_prompt);
  return code;
}

// Prints --json output, or the final answer when it was not already shown.
static void PrintResult(Agent* a, int code) {
  const char* answer = a->final_output ? a->final_output : "";
  if (a->json) {
    cJSON* r = cJSON_CreateObject();
    cJSON_AddStringToObject(r, "session", a->session.id ? a->session.id : "");
    cJSON_AddStringToObject(r, "status", StatusName(code));
    cJSON_AddNumberToObject(r, "exit", code);
    cJSON_AddStringToObject(r, "final_output", answer);
    cJSON_AddNumberToObject(r, "turns", a->session.turns);
    cJSON* tokens = cJSON_AddObjectToObject(r, "tokens");
    cJSON_AddNumberToObject(tokens, "input", (double)a->session.tokens_in);
    cJSON_AddNumberToObject(tokens, "output", (double)a->session.tokens_out);
    cJSON_AddNumberToObject(r, "cost", a->session.cost);
    char* text = cJSON_PrintUnformatted(r);
    puts(text);
    free(text);
    cJSON_Delete(r);
  } else if (*answer && !(g_events.render && isatty(1) && isatty(2))) {
    puts(answer);  // on a terminal the view already showed it
  }
}

// Ends the session: stops the calls in flight, then the final event,
// meta.json and the result.
static void Finish(Agent* a, int code) {
  CallsShutdown(a);
  cJSON* e = EventNew("session.end");
  AddTotals(a, e, code);
  cJSON_AddNumberToObject(e, "secs", Now() - a->start);
  JsonAddTruncated(e, "final_output", a->final_output, 2000);
  EventSend(e);
  SessionWriteMeta(&a->session, StatusName(code));
  EventsClose();
  PrintResult(a, code);
}

// Runs the agent; see agent.h.
int AgentMain(Agent* a) {
  // A plugin's variables never reach a program that is not that plugin's,
  // also when a plugin command runs `arx -p`.
  const char* inherited[] = {"ARX_PLUGIN_DIR", "ARX_PLUGIN_SETTINGS",
                             "ARX_STATE_DIR", "ARX_DATA_DIR"};
  for (int i = 0; i < 4; i++) unsetenv(inherited[i]);
  a->start = Now();
  const char* depth = getenv("ARX_DEPTH");
  a->depth = depth ? atoi(depth) : 0;
  if (a->caps.depth >= 0 && a->depth > a->caps.depth) {
    fprintf(stderr, "arx: subagent depth %d is over the cap of %" PRId64 "\n",
            a->depth, a->caps.depth);
    PrintResult(a, kExitCap);
    return kExitCap;
  }
  int code = Start(a);
  if (code) return code;
  code = a->interactive ? Interactive(a) : Headless(a);
  Finish(a, code);
  GateFree(a);
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  SessionClose(&a->session);
  cJSON_Delete(a->messages);
  BufferFree(&a->notes);
  free(a->final_output);
  free(a->calls);
  return code;
}
