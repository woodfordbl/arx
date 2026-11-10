// trust.h: the parts of the harness that guard it. They build on harness.h.
//   signature.c  walks every harness file; the fingerprint for hot reload
//   policy.c     policy folders: --policy DIR and ARX_POLICY
//   tool_layers.c  which layer's tool wins, and the tools of every layer

#ifndef SRC_HARNESS_TRUST_H_
#define SRC_HARNESS_TRUST_H_

#include <stdint.h>

#include "src/harness/harness.h"

// ---- signature.c ----

// One harness file, as HarnessFiles reports it. The strings are valid
// during the callback only.
typedef struct HarnessFile {
  const char* path;   // the file, as arx opens it
  const char* kind;   // spec, config, prompt, tool, hook, scheduler, skill,
                      // plugin, kit or program
  const char* layer;  // the folder it is in: spec, config, plugin:NAME,
                      // kit:NAME or policy:NAME
  const char* rel;    // its path inside that folder
  int policy;         // it is in a policy folder
} HarnessFile;

// Called for each harness file.
typedef void (*HarnessFileFn)(void* ctx, const HarnessFile* file);

// Calls `fn` with `ctx` for every file that makes up the harness: the spec
// and config.yaml, the prompt files that the spec and each plugin name,
// every entry of tools/ and hooks/ and each skills/*/SKILL.md in every
// layer, each layer's `scheduler`, the programs that `compactors`,
// `credentials` and `adapters` name, and each plugin.yaml and kit.yaml next
// to the spec and in the config folder. A policy folder reports every file
// in it (those of no other kind as `file`). A named file is reported also
// when it is missing; a folder is listed as it is now. Hot reload and the gate
// both use this walk, so the gate covers exactly what reload covers.
void HarnessFiles(const Spec* spec, HarnessFileFn fn, void* ctx);

// Fingerprints every file of HarnessFiles with stat() only, so it costs
// microseconds before each model call: path, modification time and size,
// and the mode of the entries of tools/ and hooks/.
uint64_t SpecSignature(const Spec* spec);

// ---- policy.c ----

// Replaces `*policy` (the --policy arguments, an array of strings or NULL)
// with the absolute policy folders: those of ARX_POLICY (a colon-separated
// list) first, then the flags', each once. NULL when there are none.
// Returns 0, or -1 with one line for each missing folder in `err`.
int PolicyResolve(cJSON** policy, Buffer* err);

// The name of the policy in folder `dir`: the folder's own name.
const char* PolicyName(const char* dir);

// Adds one layer for each folder of spec->policy, in order, before the spec
// folder's (call it before PluginsLoad). A policy folder is checked like a
// plugin. Its plugin.yaml values merge over the spec, so the policy wins,
// and the first policy wins over the next; its hosts and observers add. A
// missing or broken policy is never skipped: each problem goes to `err` as
// "arx: policy DIR: <problem>", so the load fails.
void PolicyLoad(Spec* spec, Buffer* err);

// ---- plugins.c, for policy.c ----

// Adds the layer of the checked plugin `plugin` in `dir`, named `name`, and
// merges its plugin.yaml values under the spec. For a policy folder, `above`
// is not NULL: the layer is a policy layer and the values go into `above`,
// under those already there.
void PluginAdopt(Spec* spec, Spec* plugin, const char* dir, const char* name,
                 cJSON* above);

// Adds a row for `arx check --list`: a name, its state (on, off, broken,
// missing or policy), why, and its folder (may be NULL).
void PluginRow(Spec* spec, const char* name, const char* state, const char* why,
               const char* dir);

// ---- tool_layers.c and tools.c ----

// The step of the tool rule that tries `layer`'s tool `name`: 1 for a
// policy layer, 2 for a plugin that lists the name in `replaces:`, and 3
// for every other tool. The tool with the lowest step wins, and inside a
// step the first layer in order. This is the one place that states the
// rule; sandboxes use it too.
int ToolPass(const Layer* layer, const char* name);

// Adds the executables of every layer to a->tools by that rule, in layer
// order; a hidden tool gets a note. Collects every file name in `names`
// (malloc'd; free each) and returns how many there are.
int ToolsAddLayers(struct Agent* a, char*** names, Buffer* notes);

// Adds the executable tools/`name` of `layer` to a->tools, or explains in
// `notes` why it is skipped. `where` names the layer in notes ("" for the
// spec folder).
void ToolAddExecutable(struct Agent* a, const Layer* layer, const char* where,
                       const char* name, Buffer* notes);

#endif  // SRC_HARNESS_TRUST_H_
