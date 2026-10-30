// run.c: the session lifecycle around the loop: load the spec, open
// or resume the session, start the event stream and observers, run headless
// or interactively, and report the result.

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
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
  if (SpecLoad(a->spec_path, a->sets, &a->spec, &err)) {
    fputs(err.data, stderr);
    BufferFree(&err);
    return kExitUsage;
  }
  int code = OpenSession(a);
  if (code) return code;
  cJSON* observer;
  cJSON_ArrayForEach(observer, JsonGet(a->spec.root, "observers")) {
    if (cJSON_IsString(observer)) EventsAddObserver(observer->valuestring);
  }
  ToolsBuild(a);
  cJSON* e = EventNew("session.start");
  cJSON_AddStringToObject(e, "name", JsonStr(a->spec.root, "name", "agent"));
  cJSON_AddStringToObject(e, "model", JsonStr(a->spec.root, "model", ""));
  cJSON_AddStringToObject(e, "spec", a->spec.path);
  cJSON_AddBoolToObject(e, "resumed", a->resume != NULL);
  cJSON_AddNumberToObject(e, "tools", a->tools.count);
  EventSend(e);
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

// Headless: one task, run until the agent stops.
static int Headless(Agent* a) {
  if (!a->resume) {
    Begin(a, a->prompt ? a->prompt : "");
  } else if (a->prompt && *a->prompt) {
    AgentAddMessage(a, "user", a->prompt);
  }
  return RunTurns(a);
}

// Interactive: one line per message. Ctrl-C stops the current turn; Ctrl-D,
// /exit or Ctrl-C at the prompt ends the session.
static int Interactive(Agent* a) {
  char *line = NULL, *first_prompt = NULL;
  size_t cap = 0;
  int code = kExitDone, started = a->resume != NULL;
  for (;;) {
    fputs(g_events.color ? "\n\033[1m› \033[0m" : "\n› ", stderr);
    g_interrupted = 0;
    if (getline(&line, &cap, stdin) < 0) break;
    line[strcspn(line, "\n")] = 0;
    if (!*line) continue;
    if (!strcmp(line, "/exit") || !strcmp(line, "/quit")) break;
    if (!started) {
      first_prompt = XStrdup(line);
      a->prompt = first_prompt;  // kept for {{prompt}} after a restart
      Begin(a, line);
      started = 1;
    } else {
      AgentAddMessage(a, "user", line);
    }
    code = RunTurns(a);
    if (code == kExitInterrupted) {
      fputs("\n(interrupted)\n", stderr);
      code = kExitDone;
    } else if (code == kExitAuth) {
      break;
    }
  }
  free(line);
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

// Ends the session: final event, meta.json, result.
static void Finish(Agent* a, int code) {
  cJSON* e = EventNew("session.end");
  cJSON_AddStringToObject(e, "status", StatusName(code));
  cJSON_AddNumberToObject(e, "turns", a->session.turns);
  cJSON_AddNumberToObject(
      e, "tokens", (double)(a->session.tokens_in + a->session.tokens_out));
  cJSON_AddNumberToObject(e, "cost", a->session.cost);
  cJSON_AddNumberToObject(e, "secs", Now() - a->start);
  JsonAddTruncated(e, "final_output", a->final_output, 2000);
  EventSend(e);
  SessionWriteMeta(&a->session, StatusName(code));
  EventsClose();
  PrintResult(a, code);
}

// Runs the agent; see agent.h.
int AgentMain(Agent* a) {
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
  ToolsFree(&a->tools);
  SpecFree(&a->spec);
  SessionClose(&a->session);
  cJSON_Delete(a->messages);
  BufferFree(&a->notes);
  free(a->final_output);
  return code;
}
