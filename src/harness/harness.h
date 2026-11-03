// harness.h: everything the agent can change about itself, and how arx reads
// it. The agent's own files live next to the spec, so edits take effect on
// the next turn; plugins add more of the same from their own folders.
//   spec.c       loads agent.yaml (YAML -> cJSON, with line numbers)
//   plugins.c    the layers: the spec folder, plugins and the user's config
//                folder; plugin.yaml
//   signature.c  fingerprints every layer with stat() for hot reload
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

// One folder that adds tools/, hooks/ and skills to the harness: the spec
// folder, a plugin, or the user's config folder.
typedef struct Layer {
  char* dir;     // the folder
  char* plugin;  // the plugin name, or NULL for the spec and config folders
  char* skills;  // its skills folder, or NULL
  cJSON* hooks;  // a plugin's hook options (from plugin.yaml), or NULL
} Layer;

// A loaded, validated spec.
typedef struct Spec {
  cJSON* root;      // the spec as JSON
  cJSON* lines;     // "dotted.path" -> line number (or "file:line" for keys
                    // that came from the user's defaults), for error messages
  char* path;       // the spec file
  char* dir;        // its directory; tools/, hooks/ and prompts are relative
  char* config;     // the defaults file merged in (config.yaml), or NULL
  uint64_t sig;     // SpecSignature() when it was loaded
  Layer* layers;    // where tools, hooks and skills come from, first wins
  int layer_count;  // the number of layers
  Buffer problems;  // plugins that were skipped, and why
} Spec;

// Loads and validates `path`, merged over the user's defaults in
// ConfigDir()/config.yaml (the spec wins key by key), then applies `sets`
// (from --set; may be NULL), then adds the plugins (see PluginsLoad). With
// `path` NULL the defaults are the whole spec, and tools/ and hooks/ come
// from the config directory. On success returns 0 and fills `spec`. On
// failure returns -1, appends one line per problem to `err`
// ("file:line: path: message"), and leaves `spec` empty.
int SpecLoad(const char* path, cJSON* sets, Spec* spec, Buffer* err);

// Parses the YAML file at `path` into spec->root and spec->lines, without
// validating it. Returns 0, or -1 with the problem in `err`.
int SpecParse(const char* path, Spec* spec, Buffer* err);

// Moves every key of `from` that `spec` lacks into `spec`, recursing into
// mappings that both have, so `spec` wins. Keeps line numbers for errors.
void SpecMergeUnder(Spec* spec, Spec* from);

// Frees a loaded spec.
void SpecFree(Spec* spec);

// Returns the text of a text node: a string, {file: path} (relative to the
// spec) or a list of them joined by blank lines. Returns NULL when `node` is
// missing; a file that cannot be read is reported in `err` (may be NULL).
char* SpecText(const Spec* spec, cJSON* node, Buffer* err);

// Parses one --set argument ("limits.max_turns=10") into `sets`. A value
// that starts with [ or { is read as JSON ("plugins=[]").
// Returns 0, or -1 if it has no "=".
int SpecAddSet(cJSON* sets, const char* key_value);

// ---- plugins.c ----

// Builds spec->layers, in this order: the spec folder; the plugins in
// <spec dir>/plugins/<name>/; then, when it is a different folder, the
// user's config folder and its plugins/<name>/. A plugin is a folder with a
// plugin.yaml. Its tools, compactors and observers merge under the spec
// (the spec wins), and its hook options stay with its layer. The spec's
// `plugins:` list, when set, names the only plugins to use, and leaves out
// the config folder's own tools/, hooks/ and skills/. A plugin that
// is broken or needs a newer arx is skipped and explained in
// spec->problems, so it cannot stop the harness.
void PluginsLoad(Spec* spec);

// Frees spec->layers.
void LayersFree(Spec* spec);

// Reads and checks the plugin in `dir` without loading it, for `arx check
// --plugin`. Appends "key=value" lines to `out` (name, version,
// description, arx, requires, missing, tools, hooks, skills, commands).
// Returns 0, or -1 with the problems in `err`.
int PluginDescribe(const char* dir, Buffer* out, Buffer* err);

// Lists the entries of `dir` that do not start with '.', sorted so that
// lists stay stable between runs. Returns the count; free each name and the
// array.
int ListNames(const char* dir, char*** names);

// ---- signature.c ----

// Returns a fingerprint of every harness file: the spec, the prompt files it
// names, and tools/, hooks/ and skills in every layer, plus each
// plugin.yaml. It uses stat() only, so calling it before every model call
// costs microseconds.
uint64_t SpecSignature(const Spec* spec);

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

// Validates a parsed plugin.yaml (name, version, description, arx,
// requires, tools, hooks, observers, compactors), appending problems to
// `err`.
void PluginValidate(const Spec* plugin, Buffer* err);

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
  char* plugin_dir;  // the plugin folder it came from, or NULL
} Tool;

// The tools of the current harness version.
typedef struct ToolSet {
  Tool* items;
  int count;
} ToolSet;

// Rebuilds a->tools from the spec and the tools/ folder of every layer.
// Built-ins are bash and edit; any executable in tools/ is a tool named
// after its file and described by `<tool> --schema`, and the first layer
// with a working tool of that name wins; a spec entry with `agent: path` is
// a subagent. Problems, and skipped plugins, become harness notes, once per
// change.
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
// ARX_BIN, and ARX_PLUGIN_DIR when `plugin_dir` is not NULL),
// NULL-terminated. Free it with FreeEnv.
char** ToolEnv(struct Agent* a, const char* plugin_dir);

// Frees an array from ToolEnv.
void FreeEnv(char** env);

// ---- hooks.c ----

// Runs hooks/<point> in every layer that has one, in layer order, with
// `input` (consumed) plus point, session and turn on stdin. Sets `*output`
// to the combined JSON decision (or NULL):
//   session_start  {"context": "..."}           every hook's, joined
//   before_tool    {"decision": "deny", "reason": "..."}   the first deny
//   after_tool     {"note": "..."}               every hook's, joined
//   stop           {"decision": "continue" | "restart", "message": "..."}
//                                                the first decision
// Returns 0 when there is no hook and 1 when hooks ran. A hook that fails
// (non-zero exit, timeout, or output that is not a JSON object) is reported
// and then ignored, unless its options say `fail: closed`; then HookRun
// stops and returns -1, and a before_tool call is denied.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output);

// ---- compact.c ----

// A rough token count for `messages`: serialized bytes / 4.
int64_t EstimateTokens(cJSON* messages);

// The estimate scaled by what the provider reported for the last call.
int64_t CurrentTokens(struct Agent* a);

// Compacts with `strategy`: mask (clear old tool outputs, the default),
// summarize (one model call), hybrid (mask, then summarize if still over),
// restart (fresh context; `message` is added after it, may be NULL), a name
// from the spec's `compactors:` (plugins add theirs there), or a path to an
// executable that rewrites {"messages": [...]}. Records a transcript reset
// and a compact event. Returns 0, or -1 when nothing could be compacted.
int Compact(struct Agent* a, const char* strategy, const char* message);

// Compacts with the spec's strategy when the prompt is over
// compaction.trigger x context_window.
void MaybeCompact(struct Agent* a);

#endif  // SRC_HARNESS_HARNESS_H_
