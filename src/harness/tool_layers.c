// tool_layers.c: which tool wins when two layers have a tool of one name.
// The rule lives here only (ToolPass), for the tool set, `arx check`, policy
// folders and sandboxes:
//   1. a policy layer's tool wins;
//   2. else a tool of a plugin that lists the name in `replaces:` wins,
//      wherever the plugin is in the active list;
//   3. else the first tool with the name wins, in layer order.
// Inside steps 1 and 2 the first layer in order wins.

#include <stdlib.h>
#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// The step of the rule that tries a layer's tool; see trust.h.
int ToolPass(const Layer* layer, const char* name) {
  if (layer->policy) return 1;
  cJSON* c;
  cJSON_ArrayForEach(c, layer->replaces) {
    if (cJSON_IsString(c) && !strcmp(c->valuestring, name)) return 2;
  }
  return 3;
}

// True for a <name>.json schema file, which sits next to its tool.
static int IsSchemaFile(const char* name) {
  size_t n = strlen(name);
  return n > 5 && !strcmp(name + n - 5, ".json");
}

// How notes name a layer: "" for the spec folder, "policy <name>: " or
// "plugin <name>: " for those, and the folder for the user's config folder.
static char* LayerName(const Spec* spec, int index) {
  const Layer* layer = &spec->layers[index];
  if (layer->policy) return XAsprintf("policy %s: ", layer->plugin);
  if (layer->plugin) return XAsprintf("plugin %s: ", layer->plugin);
  for (int l = 0; l < index; l++) {
    if (!spec->layers[l].plugin) return XAsprintf("%s/", layer->dir);
  }
  return XStrdup("");
}

// Puts the tools in the order of `rank` (one number for each tool), so the
// model sees them in layer order whichever step of the rule added them.
static void SortTools(ToolSet* tools, int* rank) {
  for (int i = 1; i < tools->count; i++) {
    Tool tool = tools->items[i];
    int r = rank[i], j = i;
    for (; j > 0 && rank[j - 1] > r; j--) {
      tools->items[j] = tools->items[j - 1];
      rank[j] = rank[j - 1];
    }
    tools->items[j] = tool;
    rank[j] = r;
  }
}

// Adds the executables of every layer; see trust.h.
int ToolsAddLayers(struct Agent* a, char*** names, Buffer* notes) {
  int total = 0;
  int* rank = NULL;
  *names = NULL;
  for (int pass = 1; pass <= 3; pass++) {
    for (int l = 0; l < a->spec.layer_count; l++) {
      const Layer* layer = &a->spec.layers[l];
      // Steps 1 and 2 only look at the layers that can win there.
      if (pass == 1 ? !layer->policy : pass == 2 && !layer->replaces) continue;
      char* dir = PathJoin(layer->dir, "tools");
      char* where = LayerName(&a->spec, l);
      char** found;
      int n = ListNames(dir, &found);
      for (int i = 0; i < n; i++) {
        if (IsSchemaFile(found[i]) || ToolPass(layer, found[i]) != pass) {
          free(found[i]);
          continue;
        }
        int before = a->tools.count;
        if (!ToolFind(a, found[i])) {
          ToolAddExecutable(a, layer, where, found[i], notes);
        } else {
          BufferPrintf(notes, "- %stools/%s is hidden by a tool above it\n",
                       where, found[i]);
        }
        if (a->tools.count > before) {
          rank = XRealloc(rank, (size_t)a->tools.count * sizeof(*rank));
          rank[before] = l * 65536 + i;
        }
        *names = XRealloc(*names, (size_t)(total + 1) * sizeof(**names));
        (*names)[total++] = found[i];
      }
      free(found);
      free(where);
      free(dir);
    }
  }
  if (rank) SortTools(&a->tools, rank);
  free(rank);
  return total;
}
