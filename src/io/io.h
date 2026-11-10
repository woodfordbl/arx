// io.h: what a session leaves behind and how it is shown.
//   session.c  the files under .arx/sessions/<id>/:
//                transcript.jsonl  every message, with reset markers
//                events.jsonl      the event stream
//                meta.json         counters, for --resume
//                tool-NNNN.out     full tool outputs
//                inbox             commands from `arx ctl` (note, stop)
//   events.c   the event stream, arx's plugin API: one JSON line per event,
//              {"v":1,"t":...,"session":...,"depth":0,"turn":7,"type":...}.
//              arx is the only writer; observers can never block it.
//   render.c   the terminal view of events, and `arx watch`

#ifndef SRC_IO_IO_H_
#define SRC_IO_IO_H_

#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>

#include "vendor/cjson/cJSON.h"

#include "src/base/base.h"

// ---- session.c ----

// An open session.
typedef struct Session {
  char* id;
  char* dir;  // absolute path
  FILE* transcript;
  int64_t inbox_offset;
  int tool_seq;  // the number of the last tool-NNNN.out
  int call_seq;  // the number of the last background call (c1, c2, ...)
  cJSON* calls;  // background calls whose result the agent has not seen
  int turns;
  int64_t tokens_in;
  int64_t tokens_out;
  double cost;
} Session;

// Creates a new session directory. A top-level session (depth 0) also
// becomes `last`. Returns 0 or -1.
int SessionNew(Session* s, int depth);

// Reopens a session (`ref` is an id, "last" or a directory) and rebuilds its
// message history into a new array in `*messages`. Returns 0 or -1.
int SessionResume(Session* s, const char* ref, cJSON** messages);

// Returns the absolute directory for an id, "last" or a path, or NULL.
char* SessionDir(const char* ref);

// Appends one message to the transcript.
void SessionAppend(Session* s, cJSON* message);

// Records that the history was replaced (compaction, a new system prompt):
// a reset marker, then every message.
void SessionReset(Session* s, cJSON* messages);

// Writes meta.json with the counters and `status`.
void SessionWriteMeta(Session* s, const char* status);

// Returns the inbox commands added since the last call, as a JSON array.
cJSON* SessionReadInbox(Session* s);

// Returns the path for the next tool output file.
char* SessionOutputPath(Session* s);

// Closes the transcript and frees the session.
void SessionClose(Session* s);

// ---- events.c ----

// The most observers a session can start.
#define ARX_MAX_OBSERVERS 8

// Where events go and how they are shown.
typedef struct Events {
  int fd;        // the session's events.jsonl, or -1
  int extra_fd;  // the --events target (path, stdout or fd:N), or -1
  int render;    // draw the terminal view on stderr
  int color;     // use ANSI colors in the terminal view
  const char* session;
  int depth;  // 0 for the top-level agent, 1 for its subagents, ...
  int turn;
  Buffer delta;       // model text not yet sent as a model.delta event
  double delta_time;  // when the last model.delta was sent
  int observers[ARX_MAX_OBSERVERS];  // write ends of observer stdin pipes
  pid_t observer_pids[ARX_MAX_OBSERVERS];
  int observer_count;
  int64_t dropped;  // events a slow observer missed
} Events;

// The process-wide event stream.
extern Events g_events;

// Opens the session file and the optional --events target ("-" for stdout,
// "fd:N", or a path). Either may be NULL. Returns 0, or -1 if `extra` cannot
// be opened.
int EventsOpen(const char* session_file, const char* extra);

// Returns a new event with the common fields filled in; add fields, then
// pass it to EventSend.
cJSON* EventNew(const char* type);

// Writes the event to every sink, shows it, and frees it.
void EventSend(cJSON* event);

// Streams model text: shows it at once, and batches it into model.delta
// events about every 50 ms.
void EventDelta(const char* text, size_t n);

// Sends any batched model text now.
void EventFlush(void);

// Passes a subagent's event line through to our sinks and shows it.
void EventForward(const char* line, size_t n);

// Starts `sh -c command` with the event stream on its stdin and `env`
// ("KEY=value", NULL-terminated, may be NULL) added to its environment.
void EventsAddObserver(const char* command, char* const* env);

// Flushes, closes the sinks, and gives observers a moment to finish.
void EventsClose(void);

// ---- render.c ----

// Draws one event on stderr. `from_log` is 1 when the event was read back
// from a log or a subagent (so model text is drawn from model.delta events),
// and 0 for our own live events (whose text EventDelta already drew).
void RenderEvent(cJSON* event, int from_log);

// Draws streamed model text, indented by subagent depth.
void RenderText(int depth, const char* text);

// `arx watch`: follows a session's events.jsonl (`ref` is an id, "last" or a
// directory) until the session ends. `json` prints raw lines instead of the
// view; `from_start` replays the session first. Returns an exit code.
int WatchMain(const char* ref, int json, int from_start);

#endif  // SRC_IO_IO_H_
