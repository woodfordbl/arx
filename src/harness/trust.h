// trust.h: the parts of the harness that guard it. They build on harness.h.
//   signature.c  walks every harness file; the fingerprint for hot reload

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
  const char* layer;  // the folder it is in: spec, config, plugin:NAME or
                      // kit:NAME
  const char* rel;    // its path inside that folder
} HarnessFile;

// Called for each harness file.
typedef void (*HarnessFileFn)(void* ctx, const HarnessFile* file);

// Calls `fn` with `ctx` for every file that makes up the harness: the spec
// and config.yaml, the prompt files that the spec and each plugin name,
// every entry of tools/ and hooks/ and each skills/*/SKILL.md in every
// layer, each layer's `scheduler`, the programs that `compactors`,
// `credentials` and `adapters` name, and each plugin.yaml and kit.yaml next
// to the spec and in the config folder. A named file is reported also when
// it is missing; a folder is listed as it is now. Hot reload and the gate
// both use this walk, so the gate covers exactly what reload covers.
void HarnessFiles(const Spec* spec, HarnessFileFn fn, void* ctx);

// Fingerprints every file of HarnessFiles with stat() only, so it costs
// microseconds before each model call: path, modification time and size,
// and the mode of the entries of tools/ and hooks/.
uint64_t SpecSignature(const Spec* spec);

#endif  // SRC_HARNESS_TRUST_H_
