// harness.h: everything the agent can change about itself, and how arx reads
// it. All of it lives next to the spec, so edits take effect on the next
// turn.
//   spec.c       loads agent.yaml (YAML -> cJSON, with line numbers) and
//                fingerprints the harness files with stat() for hot reload
//   validate.c   the field table and validation ("did you mean" hints)
//   schema.c     the JSON Schema for `arx schema`, from the same table
//   tools.c      finds tools: bash, edit, tools/<name>, subagents
//   tool_exec.c  runs one tool call; subagents run arx again
//   hooks.c      runs hooks/<point>
//   compact.c    keeps the conversation inside the context window

#ifndef SRC_HARNESS_HARNESS_H_
#define SRC_HARNESS_HARNESS_H_

#include <stdint.h>

#include "vendor/cjson/cJSON.h"

#include "src/base/base.h"

// Defined in agent.h, which includes this header.
struct Agent;

// ---- spec.c ----

// A loaded, validated spec.
typedef struct Spec {
  cJSON* root;   // the spec as JSON
  cJSON* lines;  // "dotted.path" -> line number (or "file:line" for keys
                 // that came from the user's defaults), for error messages
  char* path;    // the spec file
  char* dir;     // its directory; tools/, hooks/ and prompts are relative
  char* config;  // the defaults file merged in (config.yaml), or NULL
  uint64_t sig;  // SpecSignature() when it was loaded
} Spec;

// Loads and validates `path`, merged over the user's defaults in
// ConfigDir()/config.yaml (the spec wins key by key), then applies `sets`
// (from --set; may be NULL). With `path` NULL the defaults are the whole
// spec, and tools/ and hooks/ come from the config directory. On success
// returns 0 and fills `spec`. On failure returns -1, appends one line per
// problem to `err` ("file:line: path: message"), and leaves `spec` empty.
int SpecLoad(const char* path, cJSON* sets, Spec* spec, Buffer* err);

// Frees a loaded spec.
void SpecFree(Spec* spec);

// Returns a fingerprint of every harness file: the spec, the prompt files it
// names, tools/, hooks/ and skills. It uses stat() only, so calling it before
// every model call costs microseconds.
uint64_t SpecSignature(const Spec* spec);

// Returns the text of a text node: a string, {file: path} (relative to the
// spec) or a list of them joined by blank lines. Returns NULL when `node` is
// missing; a file that cannot be read is reported in `err` (may be NULL).
char* SpecText(const Spec* spec, cJSON* node, Buffer* err);

// Parses one --set argument ("limits.max_turns=10") into `sets`.
// Returns 0, or -1 if it has no "=".
int SpecAddSet(cJSON* sets, const char* key_value);

// ---- validate.c ----

// The type of one spec key.
typedef enum FieldType {
  kString = 1,
  kNumber,
  kInteger,
  kBoolean,
  kDuration,    // seconds, or "10s", "5m", "1h"
  kSize,        // bytes, or "2kb", "1mb"
  kText,        // a string or {file: path}
  kTextList,    // kText or a list of them
  kStringList,  // a list of strings
  kAnyMap,      // a mapping with any keys
  kMap,         // a mapping with the keys in `sub`
  kDict,        // a mapping whose values each have the keys in `sub`
} FieldType;

// One key of the spec: its name, type, sub-fields (for kMap and kDict) and
// a short description for the JSON Schema.
typedef struct Field {
  const char* key;
  FieldType type;
  const struct Field* sub;
  const char* doc;
} Field;

// The top-level keys of agent.yaml, ending with a zeroed Field.
extern const Field kTopFields[];

// The hook points, NULL-terminated: session_start, before_tool, after_tool,
// stop.
extern const char* const kHookPoints[];

// The characters allowed in tool names (OpenAI function names).
extern const char kNameChars[];

// Validates `spec->root` against the field table and the extra rules,
// appending problems to `err`. Called by SpecLoad.
void SpecValidate(const Spec* spec, Buffer* err);

// ---- schema.c ----

// Appends a JSON Schema for agent.yaml, generated from the field table.
void SpecSchema(Buffer* out);

// ---- tools.c and tool_exec.c ----

// How a tool runs.
typedef enum ToolKind {
  kToolBash,   // sh -c <command>
  kToolEdit,   // exact string replacement, in process
  kToolExec,   // tools/<name>, arguments as JSON on stdin
  kToolAgent,  // a subagent: arx -p - --spec <path>
} ToolKind;

// One tool as the model sees it, plus how to run it.
typedef struct Tool {
  char* name;
  char* description;
  char* path;     // the executable (kToolExec) or spec (kToolAgent)
  cJSON* params;  // JSON Schema of the arguments
  ToolKind kind;
  double timeout;
} Tool;

// The tools of the current harness version.
typedef struct ToolSet {
  Tool* items;
  int count;
} ToolSet;

// Rebuilds a->tools from the spec and tools/. Built-ins are bash and edit;
// any executable in <spec dir>/tools/ is a tool named after its file and
// described by `<tool> --schema`; a spec entry with `agent: path` is a
// subagent. Problems become harness notes, once per change.
void ToolsBuild(struct Agent* a);

// Frees every tool and empties the set.
void ToolsFree(ToolSet* tools);

// Returns the tools in OpenAI "tools" format (a new array).
cJSON* ToolsJson(const ToolSet* tools);

// Runs tool `name` with JSON `args`. Returns the text for the model
// (malloc'd), sets `*is_error`, stores the full-output path in
// `*output_path` (malloc'd, or NULL), and adds exit, secs, bytes and path to
// `end_event`.
char* ToolCall(struct Agent* a, const char* name, const char* args,
               int* is_error, char** output_path, cJSON* end_event);

// Returns the ARX_* environment entries for tools and hooks (ARX_SESSION,
// ARX_SESSION_DIR, ARX_TURN, ARX_CWD, ARX_SPEC, ARX_SPEC_DIR, ARX_DEPTH,
// ARX_BIN), NULL-terminated. Free it with FreeEnv.
char** ToolEnv(struct Agent* a);

// Frees an array from ToolEnv.
void FreeEnv(char** env);

// ---- hooks.c ----

// Runs the hook at <spec dir>/hooks/<point>, if there is one, with `input`
// (consumed) plus point, session and turn on stdin. Sets `*output` to its
// JSON decision (or NULL):
//   session_start  {"context": "..."}           added to the first message
//   before_tool    {"decision": "deny", "reason": "..."}
//   after_tool     {"note": "..."}               appended to the tool result
//   stop           {"decision": "continue" | "restart", "message": "..."}
// Returns 0 when there is no hook, 1 when it ran, and -1 when it failed
// (non-zero exit, timeout, or output that is not a JSON object). A failure
// is reported and then ignored unless the hook is marked fail: closed.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output);

// True when the spec sets `hooks.<point>.fail: closed`: a failed
// before_tool hook then denies the tool call.
int HookFailsClosed(struct Agent* a, const char* point);

// ---- compact.c ----

// A rough token count for `messages`: serialized bytes / 4.
int64_t EstimateTokens(cJSON* messages);

// The estimate scaled by what the provider reported for the last call.
int64_t CurrentTokens(struct Agent* a);

// Compacts with `strategy`: mask (clear old tool outputs, the default),
// summarize (one model call), hybrid (mask, then summarize if still over),
// restart (fresh context; `message` is added after it, may be NULL), or a
// path to an executable that rewrites {"messages": [...]}. Records a
// transcript reset and a compact event. Returns 0, or -1 when nothing could
// be compacted.
int Compact(struct Agent* a, const char* strategy, const char* message);

// Compacts with the spec's strategy when the prompt is over
// compaction.trigger x context_window.
void MaybeCompact(struct Agent* a);

#endif  // SRC_HARNESS_HARNESS_H_
