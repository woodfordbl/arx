// harness.h: everything the agent can change about itself, and how arx reads
// it. The agent's own files live next to the spec, so edits take effect on
// the next turn; plugins add more of the same from their own folders.
//   spec.c       loads agent.yaml (YAML -> cJSON, with line numbers)
//   active.c     the active list: which plugins a run uses, in which order
//   kits.c       kits: kit.yaml, extends, kit.lock
//   plugins.c    the layers: the spec folder, plugins and the user's config
//                folder; plugin.yaml
//   describe.c   `arx check --plugin`: one plugin, without loading it
//   signature.c  fingerprints every layer with stat() for hot reload
//   fields.c     the field tables of agent.yaml, plugin.yaml and kit.yaml
//   validate.c   validation against them ("did you mean" hints)
//   schema.c     the JSON Schema for `arx schema`, from the same table
//   tools.c      finds tools: tools/<name> in every layer, and subagents
//   tool_exec.c  runs one tool call; subagents run arx again
//   keys.c       the keys of a tool call, which say what may run together
//   shell_tools.c  bash and edit, for `arx tool` (the shell plugin)
//   hooks.c      runs hooks/<point>, by band and then in layer order
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
  char* dir;        // the folder
  char* plugin;     // the plugin name, or NULL for the spec and config folders
  char* skills;     // its skills folder, or NULL
  cJSON* hooks;     // a plugin's hook options (from plugin.yaml), or NULL
  cJSON* settings;  // a plugin's settings from the active list, or NULL
  cJSON* replaces;  // the tools a plugin hides on purpose, or NULL
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
  cJSON* active;    // [{name, why}]: only these load; NULL: all installed
  cJSON* off;       // {name: why} for the plugins `disable` turned off
  cJSON* settings;  // {name: settings}, merged from every source
  char* kit;        // the kit in use, or NULL
  char* kit_dir;    // its folder
  char* kit_from;   // where it was named: config.yaml, agent.yaml, --kit
  int kit_pinned;   // its plugins name exact versions (@ref): write kit.lock
  cJSON* rows;      // for `arx check --list`: [{name, state, why, dir}]
} Spec;

// Loads and validates `path`, merged over the kit and the user's defaults
// in ConfigDir()/config.yaml (the spec wins key by key, and the kit wins
// over the defaults), then applies `sets` (from --set and --kit, which is
// `kit=NAME`; may be NULL), then builds the active list (see ActiveBuild)
// and adds the plugins (see PluginsLoad). A kit that is missing is an
// error. With
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

// Merges `from` over `target`, recursing into mappings that both have, so
// `from` wins. Copies the values; `from` is not changed.
void JsonMergeOver(cJSON* target, const cJSON* from);

// ---- active.c ----

// Builds spec->active, off, settings and kit* from the kit, plugins, enable
// and disable keys of `config`, `agent` (NULL when the defaults are the
// spec) and `sets`, in that order; see active.c. Sets `*kit_root` to the
// kit's model_settings and instructions, or NULL. Returns 0, or -1 with
// the problem in `err` (a kit that is missing or broken).
int ActiveBuild(Spec* spec, cJSON* config, cJSON* agent, cJSON* sets,
                cJSON** kit_root, Buffer* err);

// The name a list entry refers to: "acme/tools/lint@v1" -> "lint", and
// {guard: {...}} -> "guard". Returns a pointer into a static buffer.
const char* EntryName(const cJSON* entry);

// ---- kits.c ----

// A kit with its extends resolved.
typedef struct Kit {
  char* dir;              // the kit's folder
  cJSON* plugins;         // its plugin list, in order (raw entries)
  cJSON* model_settings;  // or NULL
  char* prompt;           // the absolute path of its prompt file, or NULL
  int pinned;             // some entry names an exact version (@ref)
} Kit;

// Loads the kit `name` (kits/<name> next to the spec, else in the config
// folder) and the kits it extends. Returns 0, or -1 with the problem in
// `err` (missing, not valid, or holding an executable).
int KitLoad(const char* spec_dir, const char* name, Kit* kit, Buffer* err);

// Frees a kit from KitLoad.
void KitFree(Kit* kit);

// Reads and checks the kit in `dir` without using it, for `arx check
// --kit-dir`. Appends "key=value" lines to `out` (name, version,
// description, extends, plugins, enable, disable). Returns 0, or -1 with
// the problems in `err`, which include any executable file in the kit.
int KitDescribe(const char* dir, Buffer* out, Buffer* err);

// Writes kit.lock next to the spec when the kit pins versions (@ref): the
// source and commit of the kit and each plugin, from their .arx-source.
void KitLockWrite(const Spec* spec);

// ---- plugins.c ----

// Builds spec->layers and spec->rows. With an active list (spec->active):
// the spec folder, then each plugin of the list in its order, from
// <spec dir>/plugins/<name>/ or else the config folder's plugins/<name>/.
// Without one: the spec folder, its plugins/<name>/, then (when it is a
// different folder) the config folder and its plugins/<name>/, less the
// ones `disable` turned off. A plugin's tools, compactors and observers
// merge under the spec; its hook options, settings (which may set its
// `tools` and `hooks` options) and `replaces` stay with its layer. A plugin
// that is broken, missing or needs a newer arx is skipped and explained in
// spec->problems, so it cannot stop the harness.
void PluginsLoad(Spec* spec);

// Frees spec->layers.
void LayersFree(Spec* spec);

// Parses and checks `dir`/plugin.yaml into `plugin`. Returns 0, or -1 with
// the problems in `err`. Free `plugin` with SpecFree either way.
int PluginRead(const char* dir, Spec* plugin, Buffer* err);

// Lists the entries of `dir` that do not start with '.', sorted so that
// lists stay stable between runs. Returns the count; free each name and the
// array.
int ListNames(const char* dir, char*** names);

// ---- describe.c ----

// Reads and checks the plugin in `dir` without loading it, for `arx check
// --plugin`. Appends "key=value" lines to `out` (name, version,
// description, arx, requires, missing, tools, hooks, skills, commands).
// Returns 0, or -1 with the problems in `err`.
int PluginDescribe(const char* dir, Buffer* out, Buffer* err);

// ---- signature.c ----

// Returns a fingerprint of every harness file: the spec, the prompt files it
// names, and tools/, hooks/ and skills in every layer, plus each
// plugin.yaml and kit.yaml. It uses stat() only, so calling it before every
// model call costs microseconds.
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
  kPluginList,  // a list of names or {name: {settings}}
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

// The keys of plugin.yaml, ending with a zeroed Field.
extern const Field kPluginFields[];

// The keys of kit.yaml, ending with a zeroed Field.
extern const Field kKitFields[];

// The hook points, NULL-terminated: session_start, before_model,
// after_model, before_tool, after_tool, stop.
extern const char* const kHookPoints[];

// The characters allowed in tool names (OpenAI function names).
extern const char kNameChars[];

// Validates `spec->root` against the field table and the extra rules,
// appending problems to `err`. Called by SpecLoad.
void SpecValidate(const Spec* spec, Buffer* err);

// Validates a parsed plugin.yaml (name, version, description, arx,
// requires, tools, hooks, replaces, observers, compactors), appending
// problems to `err`.
void PluginValidate(const Spec* plugin, Buffer* err);

// Validates a parsed kit.yaml against kKitFields, appending problems to
// `err`.
void KitValidate(const Spec* kit, Buffer* err);

// ---- schema.c ----

// Appends a JSON Schema for agent.yaml, generated from the field table.
void SpecSchema(Buffer* out);

// ---- tools.c and tool_exec.c ----

// How a tool runs.
typedef enum ToolKind {
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
  char* core;        // NAME when the file only runs `arx tool NAME`, or NULL
  cJSON* keys;       // key templates from the schema; NULL means ["*"]
} Tool;

// The tools of the current harness version.
typedef struct ToolSet {
  Tool* items;
  int count;
} ToolSet;

// Rebuilds a->tools from the spec and the tools/ folder of every layer.
// Any executable in tools/ is a tool named after its file and described by
// <file>.json next to it, or else by `<tool> --schema`; {{timeout}},
// {{tool_output.head}} and {{tool_output.tail}} in its description become
// the spec's values. The first layer with a working tool of a name wins. A
// file that only runs `exec "$ARX_BIN" tool NAME "$@"` is started as
// `arx tool NAME` directly, without a shell. A spec entry with `agent:
// path` is a subagent. Problems, and skipped plugins, become harness notes,
// once per change.
void ToolsBuild(struct Agent* a);

// Frees every tool and empties the set.
void ToolsFree(ToolSet* tools);

// Returns the tools in OpenAI "tools" format (a new array).
cJSON* ToolsJson(const ToolSet* tools);

// A tool call that runs; see ToolStart.
typedef struct ToolRun ToolRun;

// Finds the tool called `name`, or returns NULL.
Tool* ToolFind(struct Agent* a, const char* name);

// Starts tool `name` with JSON `args` and returns at once; ProcPoll on
// ToolChild() runs it, and ToolFinish ends it. Stores the full-output path
// in `*output_path` (malloc'd, or NULL). Returns NULL when the call ends
// at once (an unknown tool, bad arguments, or a process that could not
// start): then `*text` is the result (malloc'd) and `*is_error` is set.
ToolRun* ToolStart(struct Agent* a, const char* name, const char* args,
                   char** text, int* is_error, char** output_path,
                   cJSON* end_event);

// The process of a started call, for ProcPoll.
ProcChild* ToolChild(ToolRun* run);

// Ends a call (stopping its process if it still runs) and frees `run`.
// Returns the text for the model (malloc'd), sets `*is_error`, and adds
// exit, secs, bytes and path to `end_event`.
char* ToolFinish(ToolRun* run, int* is_error, cJSON* end_event);

// Returns the ARX_* environment entries for tools and hooks (ARX_SESSION,
// ARX_SESSION_DIR, ARX_TURN, ARX_CWD, ARX_SPEC, ARX_SPEC_DIR, ARX_DEPTH,
// ARX_BIN, and ARX_PLUGIN_DIR when `plugin_dir` is not NULL),
// NULL-terminated. Free it with FreeEnv.
char** ToolEnv(struct Agent* a, const char* plugin_dir);

// Frees an array from ToolEnv.
void FreeEnv(char** env);

// ---- keys.c ----

// True when `keys` is an array of strings.
int KeysValid(cJSON* keys);

// Returns the keys of a call to `tool` (may be NULL for an unknown tool,
// which gets []) with the arguments `args`, as a new array. A tool that
// declares no keys gets ["*"]; a subagent gets []. In each key, {name}
// becomes the value of the top-level argument `name` ("" when it is
// missing), and in a key that starts with "host:", just the host of that
// value, so ["host:{url}"] gives "host:example.com".
cJSON* KeysFor(const Tool* tool, cJSON* args);

// True when two calls with these keys may not run at the same time: one of
// them has "*", or they share a key.
int KeysConflict(cJSON* a, cJSON* b);

// ---- shell_tools.c ----

// Returns the schema of `arx tool <name>` as JSON text ({"description",
// "parameters"}, as plugins/shell/tools/<name>.json has it), or NULL when
// `name` is not bash or edit.
const char* ShellToolSchema(const char* name);

// Runs `arx tool <name>` with the JSON arguments `args`, as a process tool:
// the result goes to stdout, and the exit code is 0 or 1 for an error. bash
// replaces this process with `sh -c <command>` and does not return unless
// that fails.
int ShellToolRun(const char* name, const char* args);

// ---- hooks.c ----

// Runs hooks/<point> for a decision point (session_start or stop) in every
// layer that has one, by band and then in layer order, with `input` (consumed)
// plus point, session and turn on stdin. Sets `*output` to the combined JSON
// (or NULL):
//   session_start  {"context": "..."}           every hook's, joined
//   stop           {"decision": "continue" | "restart", "message": "..."}
//                                                the first decision
// Returns 0 when there is no hook and 1 when hooks ran. A hook that fails
// (non-zero exit, timeout, or output that is not a JSON object) is reported
// and then ignored, unless its options say `fail: closed`; then HookRun
// stops and returns -1.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output);

// Runs hooks/<point> for a raw-object point as a chain: the `policy` band
// first, then `normal`, then `final`, each in layer order. Each
// hook gets `object` (kept by the caller) plus point, session and turn, and
// prints the fields it changes; they replace the fields of `object` before
// the next hook runs:
//   before_model  {messages, tools, model, settings, reason}
//                 prints any of messages, tools, model, settings
//   after_model   {reply, usage, finish}; prints reply
//   before_tool   {id, name, args}; prints name or args, or result to skip
//                 the tool, which ends the chain. {"decision": "deny",
//                 "reason"} becomes the result "denied: <reason>" and adds
//                 "is_error": true to `object`.
//   after_tool    {call, result, is_error}; prints result. {"note"} is
//                 appended to the result.
// A `result` that a policy hook sets is final: later hooks cannot change
// it, and their events say "ignored". Plugin hooks also get their settings
// as ARX_PLUGIN_SETTINGS (JSON). A field of the wrong type makes the answer
// a failure. Each hook event
// lists the fields that hook changed under "changed", and the names are
// also added to `changed` (an array; may be NULL). Returns 0 when there is
// no hook, 1 when hooks ran, and -1 when a `fail: closed` hook failed,
// which stops the chain.
int HookChain(struct Agent* a, const char* point, cJSON* object,
              cJSON* changed);

// True when any layer has an executable hooks/<point>.
int HookExists(struct Agent* a, const char* point);

// The options of `layer`'s hook at `point`: a plugin's come from its
// plugin.yaml, the others from the spec's hooks.<point>. May be NULL.
cJSON* HookOptions(const Spec* spec, const Layer* layer, const char* point);

// The band of `layer`'s hook at `point`: 0 policy, 1 normal (the
// default), 2 final.
int HookBand(const Spec* spec, const Layer* layer, const char* point);

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
