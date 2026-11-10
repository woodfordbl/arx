// check_policy.c: what `arx check` says about policy folders (--policy
// DIR): the `policy:` line, and warnings about a harness_edit hook that
// can never run, a policy folder the agent's bash can change, and a policy
// guard that fails open.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// Prints the policy line; see cli.h.
void CheckPolicyLine(const Spec* spec) {
  int any = 0;
  for (int l = 0; l < spec->layer_count; l++) {
    const Layer* layer = &spec->layers[l];
    if (!layer->policy) continue;
    printf("%s%s", any ? " " : "policy: ", layer->plugin);
    any = 1;
  }
  if (any) printf("\n");
}

// Adds the policy warnings; see cli.h.
void CheckPolicyWarnings(const Spec* spec, Buffer* out) {
  char* cwd = realpath(".", NULL);
  size_t n = cwd ? strlen(cwd) : 0;
  int seen_spec = 0;
  for (int l = 0; l < spec->layer_count; l++) {
    const Layer* layer = &spec->layers[l];
    char* gate = HookPath(layer, "harness_edit");
    char* guard = HookPath(layer, "before_tool");
    cJSON* options = HookOptions(spec, layer, "before_tool");
    int spec_folder = !layer->plugin && !seen_spec;
    seen_spec |= spec_folder;
    if (gate && !layer->policy) {
      // Only a policy folder's gate runs: a gate the agent can edit would
      // judge its own edits.
      BufferPrintf(out,
                   "- %s%s%shooks/harness_edit runs only in a policy "
                   "folder (--policy)\n",
                   layer->plugin ? "plugin "
                   : spec_folder ? ""
                                 : layer->dir,
                   layer->plugin ? layer->plugin : "",
                   layer->plugin ? ": "
                   : spec_folder ? ""
                                 : "/");
    }
    if (layer->policy && cwd && !strncmp(layer->dir, cwd, n) &&
        layer->dir[n] == '/') {
      BufferPrintf(out,
                   "- policy %s is inside the working directory, so the "
                   "agent's bash can change it\n",
                   layer->dir);
    }
    if (layer->policy && guard &&
        (HookBand(spec, layer, "before_tool") != 0 ||
         strcmp(JsonStr(options, "fail", "open"), "closed"))) {
      BufferPrintf(out,
                   "- policy %s: before_tool hook without band: policy and "
                   "fail: closed\n",
                   layer->plugin);
    }
    free(gate);
    free(guard);
  }
  free(cwd);
}
