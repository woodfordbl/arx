// agent.h: one running agent: its command-line options, the loaded harness
// (spec and tools), its session and its message history, plus the entry
// points of the loop.

#ifndef SRC_AGENT_AGENT_H_
#define SRC_AGENT_AGENT_H_

#include <stdint.h>

#include "vendor/cjson/cJSON.h"

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// Hard ceilings from --cap. The spec cannot raise them; -1 means no cap.
typedef struct Caps {
  int64_t turns;  // model calls in this session
  double tokens;  // input + output tokens in this session
  double usd;     // cost in this session
  double wall;    // seconds since this process started
  int64_t depth;  // deepest subagent level allowed
} Caps;

// Where a tool call is in the runtime.
typedef enum CallState { kQueued, kRunning, kDone } CallState;

// One tool call in the session's call table, from its before_tool hooks to
// its result. It owns copies of the model's id and arguments, so the reply
// they came from may be freed (by compaction) while it runs. A background
// call (background.c) stays in the table after its reply's results are in
// the history, until it ends.
typedef struct Call {
  char* id;           // the model's tool call id
  char* args;         // the arguments as the model wrote them
  cJSON* model_call;  // {id, name, args, keys} as the model made it
  cJSON* call;        // the same after the before_tool hooks
  CallState state;
  ToolRun* run;  // while it runs
  char* text;    // the result
  int is_error;
  char* out_path;  // the full output, or NULL
  cJSON* end;      // the tool.end event, until it is sent
  // A background call: the model got `placeholder` as the result.
  char* short_id;         // "c7" once it is in the background, else NULL
  char* placeholder;      // "started as c7 ...", the result in the reply
  double detached_at;     // Now() when it moved to the background
  const char* status;     // "cancelled" or "stopped" when arx ended it
  const char* stop_line;  // the status line for a run that arx stopped
  int placed;             // its tool message is in the history
} Call;

// A running agent.
typedef struct Agent {
  // Options from the command line.
  const char* spec_path;
  const char* prompt;  // the task (-p or stdin), or NULL
  const char* resume;  // session to resume, or NULL
  const char* events;  // --events target, or NULL
  cJSON* sets;         // --set overrides, applied on every (re)load
  Caps caps;
  char** cap_args;  // the raw --cap arguments, passed on to subagents
  int cap_count;
  int json;         // print the result as JSON on stdout
  int quiet;        // no terminal view
  int interactive;  // read messages from the terminal
  // State.
  Spec spec;
  ToolSet tools;
  Session session;
  cJSON* messages;           // the conversation, OpenAI chat format
  Buffer notes;              // harness notes for the agent's next turn
  uint64_t notes_sig;        // the last tool-problem notes, to avoid repeats
  int depth;                 // 0 at the top, 1 for a subagent, ...
  double start;              // Now() when the process started
  int64_t estimate_at_call;  // EstimateTokens() at the last model call
  int64_t tokens_at_call;    // prompt_tokens the provider reported for it
  char* final_output;        // the last answer without tool calls
  int stop_requested;        // `arx ctl stop` arrived
  Call** calls;              // the session's call table (tool_calls.c)
  int call_count;
} Agent;

// Parses one --cap argument ("turns=50", "usd=2", "wall=8h", "depth=2")
// into `c`. Returns 0, or -1 if the key or value is not valid.
int CapsParse(Caps* c, const char* key_value);

// Runs the agent from start to finish: opens or resumes the session, runs
// the loop (repeatedly in interactive mode), and prints the result.
// Returns an ExitCode.
int AgentMain(Agent* a);

// Runs model turns until the agent stops (no tool calls, no background
// call in flight, and the stop hook does not continue), a cap is reached,
// or an error or interrupt happens. Returns an ExitCode.
int RunTurns(Agent* a);

// Calls the model once for the next turn, through the before_model and
// after_model hooks, and accounts for the usage. On a context-overflow
// error it compacts (before_model with reason context_overflow, else the
// built-in strategy) and retries once. Sets `*message` to the assistant
// message (the caller owns it). Returns -1 on success, else an ExitCode.
int ModelTurn(Agent* a, cJSON** message);

// Runs the tool calls in `calls` through the before_tool hooks, then
// queues the allowed calls in the session's call table and runs them by
// their keys (calls that share a key run one at a time, "*" runs alone, []
// runs with anything), or as a scheduler plugin says. after_tool runs as
// each call ends. Returns when each call is done or in the background, and
// adds the results (a placeholder for a background call) to the history
// and the transcript in the order of the calls. Calls after a Ctrl-C still
// get a result, so the history stays valid.
void RunToolCalls(Agent* a, cJSON* calls);

// Runs one round of the session's call table: after Ctrl-C, ends the
// queued calls; reads the scheduler plugin; starts calls (as the plugin
// says, else by keys, and moves to the background or cancels the calls it
// names); waits up to `wait` seconds (at most 0.1) on the running
// processes; and finishes each call whose process ended, with its
// after_tool hooks. Returns the number of calls that were queued or running.
int CallsPoll(Agent* a, double wait);

// A one-line summary of a call's arguments, for events and notes: the
// command, path or task when there is one, else the raw text (malloc'd).
char* CallPreview(const char* args);

// Ends a queued call without a run, with the result `text` (consumed).
void CallEndWithout(Agent* a, Call* c, char* text, int is_error);

// Background calls (background.c): a scheduler plugin moves a call to the
// background with {"detach"}. The model gets a placeholder result at once,
// the call runs on, and its real result reaches the agent later as a
// `result` line in the session inbox.

// Returns the call in the table with this model id or short id, or NULL.
Call* CallFind(Agent* a, const char* id);

// Moves a queued or running call to the background: gives it a short id
// (c1, c2, ...) and its placeholder, drops the key "*" (see CallsConflict),
// and sends tool.detach. Ignores NULL, a call that ended and a background call.
void CallDetach(Agent* a, Call* c);

// True when two calls may not run at the same time: they share a key, or
// one has "*". A background call holds only its named keys, so "*" on
// either side does not count: `bash` runs beside a background call.
int CallsConflict(const Call* a, const Call* b);

// Tells a background call that its process started.
void CallRuns(Agent* a, Call* c);

// Cancels the call with this model id or short id: a running call gets
// SIGTERM (SIGKILL 3 seconds later, without a wait) and ends with its
// output and "[cancelled]"; a queued call ends at once. Ignores an unknown
// id and a call that ended.
void CallCancel(Agent* a, const char* id);

// Delivers a background call that ended, after `secs` seconds (below 0: it
// never ran): appends its `result` line to the inbox and writes meta.json.
// Does nothing for a foreground call.
void CallEnded(Agent* a, Call* c, double secs);

// Queues the inbox `result` line `r` as one paragraph of the agent's next
// note, such as "c7 (reviewer: Review a.c) finished after 42s:" and the
// text. The agent has seen the call then: it leaves the session's `calls`.
void CallNote(Agent* a, cJSON* r);

// The number of background calls whose result the agent has not seen.
int CallsInFlight(Agent* a);

// Stops every call in the table before the session ends or the prompt
// comes back: running calls get SIGTERM, queued ones end, each with its
// after_tool hooks and a `result` line with the status `stopped`. Waits
// until they are gone.
void CallsShutdown(Agent* a);

// After --resume: gives the agent a note for each call that was in flight
// when the session stopped (its `result` line from the inbox, or "did not
// finish" when arx was killed), and empties the session's `calls`.
void CallsResume(Agent* a);

// Frees the calls that are done and whose tool message is in the history,
// and takes them out of the table.
void CallsSweep(Agent* a);

// The scheduler plugin (scheduler.c): one process for each session, an
// executable `scheduler` at the top of a layer (the first wins).

// Starts the plugin when a layer has one, or stops it when none has or it
// changed. A plugin that failed is not started again. Returns 1 when a
// plugin schedules.
int SchedOpen(Agent* a);

// True while a plugin schedules; it stops when it exits or prints a bad
// line (with an error event), and then the built-in scheduler takes over.
int SchedActive(void);

// Sends {"ready": {id, name, keys, kind, args}}: a call is in the queue.
// `kind` is "tool", or "agent" for a subagent; `args` are the arguments
// after the before_tool hooks.
void SchedReady(const char* id, const char* name, cJSON* keys, const char* kind,
                cJSON* args);

// Sends {"done": {id, secs, is_error, backoff, ran}}: a call ended.
// `backoff` may be NULL. `ran` is 0 for a call whose process never started
// (a queued call that was cancelled or stopped).
void SchedDone(const char* id, double secs, int is_error, cJSON* backoff,
               int ran);

// Returns the seconds until the plugin's tick is due, at most `max`.
double SchedWait(double max);

// What a scheduler plugin said since the last SchedPoll.
typedef struct SchedOut {
  cJSON* start;    // ids to start now
  cJSON* results;  // {id: text}: calls to end without a run, as an error
  cJSON* detach;   // ids to move to the background
  cJSON* cancel;   // model ids or short ids (c7) to cancel
} SchedOut;

// Reads what the plugin printed into new arrays (and one object) in `out`,
// which the caller frees with SchedOutFree, and keeps {"wake_at"}. Sends
// {"tick": <unix secs>} when it is due.
void SchedPoll(SchedOut* out);

// Frees what SchedPoll put in `out`.
void SchedOutFree(SchedOut* out);

// Expands {{vars}} in `tmpl`: prompt, harness, skills, date, cwd, session,
// turn, and file:PATH[:tail=N|:max=SIZE]. Returns a malloc'd string.
char* RenderTemplate(Agent* a, const char* tmpl);

// Returns the system prompt: the spec's instructions (or a default),
// rendered. Returns a malloc'd string.
char* SystemPrompt(Agent* a);

// Returns the first user message for `prompt`: the spec's first_message
// template with {{prompt}} filled in, or `prompt` itself.
char* FirstMessage(Agent* a, const char* prompt);

// Queues a "[harness]" note that the agent sees before its next model call.
void AgentNote(Agent* a, const char* fmt, ...);

// Appends a {"role", "content"} message to the history and the transcript.
void AgentAddMessage(Agent* a, const char* role, const char* content);

#endif  // SRC_AGENT_AGENT_H_
