// harness.h: everything the agent can change about itself, and how arx reads
// it. Edits take effect on the next turn; plugins add more from their folders.
//   spec.c       loads agent.yaml (YAML -> cJSON, with line numbers)
//   active.c     the active list: which plugins a run uses, in which order
//   kits.c       kits: kit.yaml, extends, kit.lock
//   plugins.c    the layers (spec folder, plugins, config folder); plugin.yaml
//   plugin_keys.c  a plugin's instructions and model_settings
//   describe.c   `arx check --plugin`: one plugin, without loading it
//   signature.c  walks the harness files; the fingerprint (trust.h)
//   fields.c     the field tables of agent.yaml, plugin.yaml and kit.yaml
//   validate.c, schema.c  validation and `arx schema`, from those tables
//   tools.c      finds tools: tools/<name> in every layer, and subagents
//   policy.c, tool_layers.c, manifest.c, gate.c  see trust.h
//   tool_exec.c  runs one tool call; subagents run arx again
//   keys.c       the keys of a tool call, which say what may run together
//   hooks.c      runs hooks/<point>, by band and then in layer order
//   chain.c      the hook chain over one raw object around model and tools
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
  cJSON* instructions;  // a plugin's text node, with absolute paths, or NULL
  int policy;           // a policy folder (--policy): see trust.h
} Layer;

// A loaded, validated spec.
typedef struct Spec {
  cJSON* root;      // the spec as JSON
  cJSON* lines;     // "dotted.path" -> line ("file:line" from config.yaml)
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
  cJSON* setting_from;  // {"model_settings.<path>": plugin}, from plugins
  Buffer warnings;      // for `arx check`: plugins that set a field apart
  char* prompt_from;    // where the base prompt came from, for `arx check`
  cJSON* policy;        // the policy folders (absolute), in order, or NULL
} Spec;

// Loads and validates `path`, merged over the kit and the user's defaults
// in ConfigDir()/config.yaml (the spec wins key by key, and the kit wins
// over the defaults), applies `sets` (--set, and --kit as `kit=NAME`; may be
// NULL), builds the active list (see ActiveBuild) and adds the plugins (see
// PluginsLoad), the policy folders in `policy` (may be NULL) first. A missing
// kit is an error. With `path` NULL the defaults are the whole spec, and
// tools/ and hooks/ come from the config directory. Returns 0 and fills
// `spec`, or returns -1, appends one line per problem to `err`
// ("file:line: path: message") and leaves `spec` empty.
int SpecLoad(const char* path, cJSON* sets, cJSON* policy, Spec* spec,
             Buffer* err);

// Parses the YAML file at `path` into spec->root and spec->lines, without
// validating it. Returns 0, or -1 with the problem in `err`.
int SpecParse(const char* path, Spec* spec, Buffer* err);

// Moves every key of `from` that `spec` lacks into `spec`, recursing into
// mappings that both have, so `spec` wins. Keeps line numbers for errors.
void SpecMergeUnder(Spec* spec, Spec* from);

// Frees a loaded spec.
void SpecFree(Spec* spec);

// The text of a text node: a string, {file: path} (relative to the spec) or a
// list of them joined by blank lines; NULL if missing. Read errors go to `err`.
char* SpecText(const Spec* spec, cJSON* node, Buffer* err);

// Parses one --set argument ("limits.max_turns=10") into `sets`. A value
// that starts with [ or { is JSON ("plugins=[]"). Returns 0, or -1 if no "=".
int SpecAddSet(cJSON* sets, const char* key_value);

// Merges `from` over `target`, recursing into mappings that both have, so
// `from` wins. Copies the values; `from` is not changed.
void JsonMergeOver(cJSON* target, const cJSON* from);

// ---- active.c ----

// Builds spec->active, off, settings and kit* from the kit, plugins, enable
// and disable keys of `config`, `agent` (NULL when the defaults are the
// spec) and `sets`, in that order. Sets `*kit_root` to the kit's spec values
// or NULL. Returns 0, or -1 with the problem in `err` (a missing or bad kit).
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

// Loads kit `name` (kits/<name> next to the spec, else in the config folder)
// and the kits it extends. Returns 0, or -1 with the problem in `err`.
int KitLoad(const char* spec_dir, const char* name, Kit* kit, Buffer* err);

// Frees a kit from KitLoad.
void KitFree(Kit* kit);

// Checks the kit in `dir` without using it, for `arx check --kit-dir`, and
// appends key=value lines to `out`. Returns 0, or -1 with problems in `err`.
int KitDescribe(const char* dir, Buffer* out, Buffer* err);

// Writes kit.lock next to the spec when the kit pins versions (@ref): the
// source and commit of the kit and each plugin, from their .arx-source.
void KitLockWrite(const Spec* spec);

// ---- plugins.c ----

// Builds spec->layers and spec->rows. With an active list (spec->active):
// the spec folder, then each listed plugin in order, from <spec
// dir>/plugins/<name>/ or else the config folder's. Without one: the spec
// folder, its plugins/, then the config folder (when different) and its
// plugins/, less those `disable` names. A plugin's tools, compactors,
// observers and model_settings merge under the spec; its hook options,
// settings, `replaces` and instructions stay with its layer. A broken,
// missing or too-new plugin is skipped and explained in spec->problems.
void PluginsLoad(Spec* spec);

// Adopt's part for a plugin's instructions and model_settings (plugin_keys.c).
// `over` holds the values of the policy folders before this one, or is NULL.
void PluginKeysAdopt(Spec* spec, cJSON* root, Layer* layer, cJSON* over);

// Frees spec->layers.
void LayersFree(Spec* spec);

// Parses and checks `dir`/plugin.yaml into `plugin`. Returns 0, or -1 with
// the problems in `err`. Free `plugin` with SpecFree either way.
int PluginRead(const char* dir, Spec* plugin, Buffer* err);

// Lists `dir` sorted, without '.' entries. Returns the count; free them all.
int ListNames(const char* dir, char*** names);

// ---- describe.c ----

// Checks the plugin in `dir` without loading it, for `arx check --plugin`,
// and appends key=value lines to `out`: fields, parts, hosts. Returns 0 or -1.
int PluginDescribe(const char* dir, Buffer* out, Buffer* err);

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

// One key of the spec: name, type, sub-fields (kMap, kDict) and a doc line.
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

// True when `v` has the shape that `type` needs (fields.c).
int TypeOk(FieldType type, const cJSON* v);

// Describes `type` for messages, such as "a string" (fields.c).
const char* TypeName(FieldType type);

// Validates the spec and the plugins' settings; appends problems to `err`.
void SpecValidate(const Spec* spec, Buffer* err);

// Validates a parsed plugin.yaml against kPluginFields, and its programs,
// hosts and text, appending problems to `err`.
void PluginValidate(const Spec* plugin, Buffer* err);

// Validates a parsed kit.yaml against kKitFields, appending to `err`.
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
  char* plugin;      // that plugin's name, or NULL
  char* core;        // NAME when the file only runs `arx tool NAME`, or NULL
  cJSON* keys;       // key templates from the schema; NULL means ["*"]
} Tool;

// The tools of the current harness version.
typedef struct ToolSet {
  Tool* items;
  int count;
} ToolSet;

// Rebuilds a->tools from the spec and every layer's tools/: an executable
// is a tool named after its file, described by <file>.json or else
// `<tool> --schema`, with {{timeout}} and {{tool_output.*}} filled in. When
// layers share a name, ToolPass (trust.h) says which wins. A file that only
// runs `exec "$ARX_BIN" tool NAME "$@"` starts as `arx tool NAME`. A spec entry
// with `agent: path` is a subagent. Problems become notes, once each.
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
// in `*output_path` (malloc'd, or NULL). Returns NULL when the call ends at
// once (unknown tool, bad arguments, no start), with `*text` and `*is_error`.
ToolRun* ToolStart(struct Agent* a, const char* name, const char* args,
                   char** text, int* is_error, char** output_path,
                   cJSON* end_event);

// The process of a started call, for ProcPoll.
ProcChild* ToolChild(ToolRun* run);

// Ends a call (stopping its process if it still runs) and frees `run`.
// Returns the text for the model (malloc'd), sets `*is_error`, and adds
// exit, secs, bytes and path to `end_event`.
char* ToolFinish(ToolRun* run, int* is_error, cJSON* end_event);

// Returns the ARX_* environment for tools and hooks, NULL-terminated:
// ARX_SESSION, _SESSION_DIR, _TURN, _CWD, _SPEC, _SPEC_DIR, _DEPTH, _BIN;
// ARX_PLUGIN_DIR for `plugin_dir`; and for a plugin's name, ARX_STATE_DIR
// (<session>/plugins/<name>) and ARX_DATA_DIR (<cwd>/.arx/data/<name>).
char** ToolEnv(struct Agent* a, const char* plugin_dir, const char* plugin);

// ToolEnv for a program of `layer`, plus ARX_PLUGIN_SETTINGS for a plugin's.
char** PluginEnv(struct Agent* a, const Layer* layer);

// Frees an array from ToolEnv or PluginEnv.
void FreeEnv(char** env);

// ---- keys.c ----

// Appends the host of a URL or bare host name: no scheme, user, port, path.
void AppendHost(Buffer* b, const char* url);

// True when `keys` is an array of strings.
int KeysValid(cJSON* keys);

// Returns the keys of a call to `tool` (NULL: unknown, which gets []) with
// `args`, as a new array: ["*"] when it declares none, [] for a subagent.
// In each key, {name} becomes the top-level argument `name` ("" if
// missing), and in a "host:" key its host: "host:{url}" -> "host:a.com".
cJSON* KeysFor(const Tool* tool, cJSON* args);

// True when two calls with these keys may not run at the same time: one of
// them has "*", or they share a key.
int KeysConflict(cJSON* a, cJSON* b);

// ---- hooks.c ----

// Runs hooks/<point> for session_start or stop in every layer that has one,
// by band, then in layer order, with `input` (consumed) plus point, session
// and turn on stdin. Sets `*output` to the combined JSON or NULL:
// session_start joins every {"context"}; stop takes the first {"decision":
// "continue" | "restart", "message"}. Returns 0 when there is no hook, 1
// when hooks ran. A failed hook (non-zero exit, timeout, stdout that is not
// a JSON object) is ignored, unless `fail: closed`: then it returns -1.
int HookRun(struct Agent* a, const char* point, cJSON* input, cJSON** output);

// True when any layer has an executable hooks/<point>.
int HookExists(struct Agent* a, const char* point);

// The path of `layer`'s runnable hooks/<point> (malloc'd), or NULL.
char* HookPath(const Layer* layer, const char* point);

// Runs `layer`'s hook at `path` with `text` on stdin. Sets `*output` to the
// JSON object it printed, or NULL, and `*event` to its hook event, not yet
// sent. Returns 1 when it ran and -1 when it failed.
int HookRunOne(struct Agent* a, const Layer* layer, const char* point,
               const char* path, const char* text, cJSON** output,
               cJSON** event);

// The options of `layer`'s hook at `point`: a plugin's come from its
// plugin.yaml, the others from the spec's hooks.<point>. May be NULL.
cJSON* HookOptions(const Spec* spec, const Layer* layer, const char* point);

// The band of `layer`'s hook at `point`: 0 policy, 1 normal (the
// default), 2 final.
int HookBand(const Spec* spec, const Layer* layer, const char* point);

// ---- chain.c ----

// Runs hooks/<point> for a raw-object point (before_model, after_model,
// before_tool, after_tool) as a chain, by band, then in layer order: each
// hook gets `object` (kept by the caller), and the fields it prints replace
// those of `object` (chain.c lists them). A before_tool `result` ends the
// chain. Changed fields are added to `changed` (an array; may be NULL).
// Returns 0 when no hook ran, 1 when hooks ran, and -1 when a
// `fail: closed` hook failed (the chain stops).
int HookChain(struct Agent* a, const char* point, cJSON* object,
              cJSON* changed);

// ---- compact.c ----

// A rough token count for `messages`: serialized bytes / 4.
int64_t EstimateTokens(cJSON* messages);

// The estimate scaled by what the provider reported for the last call.
int64_t CurrentTokens(struct Agent* a);

// Compacts with `strategy`: mask (clear old tool outputs, the default),
// summarize (one model call), hybrid (mask, then summarize if still over),
// restart (fresh context, then `message` if not NULL), a name from
// `compactors:`, or a path to an executable that rewrites {"messages"}.
// Records a transcript reset and a compact event. Returns 0, or -1.
int Compact(struct Agent* a, const char* strategy, const char* message);

// Compacts with the spec's strategy when the prompt is over
// compaction.trigger x context_window.
void MaybeCompact(struct Agent* a);

#endif  // SRC_HARNESS_HARNESS_H_
