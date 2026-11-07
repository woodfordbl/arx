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
} Agent;

// Parses one --cap argument ("turns=50", "usd=2", "wall=8h", "depth=2")
// into `c`. Returns 0, or -1 if the key or value is not valid.
int CapsParse(Caps* c, const char* key_value);

// Runs the agent from start to finish: opens or resumes the session, runs
// the loop (repeatedly in interactive mode), and prints the result.
// Returns an ExitCode.
int AgentMain(Agent* a);

// Runs model turns until the agent stops (no tool calls and the stop hook
// does not continue), a cap is reached, or an error or interrupt happens.
// Returns an ExitCode.
int RunTurns(Agent* a);

// Calls the model once for the next turn, through the before_model and
// after_model hooks, and accounts for the usage. On a context-overflow
// error it compacts (before_model with reason context_overflow, else the
// built-in strategy) and retries once. Sets `*message` to the assistant
// message (the caller owns it). Returns -1 on success, else an ExitCode.
int ModelTurn(Agent* a, cJSON** message);

// Runs every tool call in `calls` one at a time, through the before_tool
// and after_tool hooks, and adds each result to the history and the
// transcript. Calls after a Ctrl-C still get a result, so the history stays
// valid.
void RunToolCalls(Agent* a, cJSON* calls);

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
