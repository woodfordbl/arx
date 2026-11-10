// signature.c: the walk over every harness file, and the fingerprint for
// hot reload that is built on it. The walk covers the spec, the prompt
// files that it and each plugin name, tools/, hooks/, skills and the
// scheduler in every layer, named programs, and plugin.yaml and kit.yaml
// files. The fingerprint uses stat() only, so arx can check it before every
// model call.

#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// A walk in progress: the callback, and the folder the files are in.
typedef struct Walk {
  HarnessFileFn fn;
  void* ctx;
  const char* layer;  // the label of the current folder
  const char* dir;    // the current folder, for `rel`
  int policy;         // the current folder is a policy folder
} Walk;

// Reports one file. `rel` is its path inside the current folder; NULL
// works it out from `path`.
static void Report(const Walk* w, const char* kind, const char* path,
                   const char* rel) {
  size_t n = strlen(w->dir);
  if (!rel && !strncmp(path, w->dir, n) && path[n] == '/') rel = path + n + 1;
  HarnessFile file = {path, kind, w->layer, rel ? rel : path, w->policy};
  w->fn(w->ctx, &file);
}

// Reports every entry of `dir`/`sub`, in the order the folder lists them.
static void ReportDir(const Walk* w, const char* kind, const char* dir,
                      const char* sub) {
  char* folder = XAsprintf("%s/%s", dir, sub);
  DIR* d = opendir(folder);
  struct dirent* e;
  while (d && (e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char* path = XAsprintf("%s/%s", folder, e->d_name);
    Report(w, kind, path, NULL);
    free(path);
  }
  if (d) closedir(d);
  free(folder);
}

// The plugin or policy layer whose folder holds `path`, or NULL.
static const Layer* LayerOf(const Spec* spec, const char* path) {
  for (int l = 0; l < spec->layer_count; l++) {
    const Layer* layer = &spec->layers[l];
    size_t n = strlen(layer->dir);
    if (layer->plugin && !strncmp(path, layer->dir, n) && path[n] == '/') {
      return layer;
    }
  }
  return NULL;
}

// Reports `path`, a file that the spec names, in the folder that holds it:
// a plugin's, the kit's, or else the spec folder. A policy folder reports
// all of its files itself.
static void ReportNamed(const Spec* spec, const Walk* w, const char* kind,
                        const char* path) {
  Walk in = *w;
  const Layer* layer = LayerOf(spec, path);
  if (layer && layer->policy) return;
  char* label = layer ? XAsprintf("plugin:%s", layer->plugin) : NULL;
  size_t n = spec->kit_dir ? strlen(spec->kit_dir) : 0;
  if (layer) {
    in.dir = layer->dir;
  } else if (n && !strncmp(path, spec->kit_dir, n) && path[n] == '/') {
    label = XAsprintf("kit:%s", spec->kit);
    in.dir = spec->kit_dir;
  }
  if (label) in.layer = label;
  Report(&in, kind, path, NULL);
  free(label);
}

// Reports the files that a text node points at. A plugin's and a kit's
// paths are absolute, so PathJoin keeps them.
static void ReportText(const Spec* spec, const Walk* w, cJSON* node) {
  if (cJSON_IsArray(node)) {
    for (cJSON* c = node->child; c; c = c->next) ReportText(spec, w, c);
    return;
  }
  const char* file = JsonStr(node, "file", NULL);
  if (!file) return;
  char* path = PathJoin(spec->dir, file);
  ReportNamed(spec, w, "prompt", path);
  free(path);
}

// Reports one layer: tools/, hooks/, skills, its prompt files and its
// scheduler.
static void ReportLayer(const Spec* spec, const Walk* w, const Layer* layer) {
  ReportDir(w, "tool", layer->dir, "tools");
  ReportDir(w, "hook", layer->dir, "hooks");
  DIR* d = layer->skills ? opendir(layer->skills) : NULL;
  struct dirent* e;
  while (d && (e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char* path = XAsprintf("%s/%s/SKILL.md", layer->skills, e->d_name);
    Report(w, "skill", path, NULL);
    free(path);
  }
  if (d) closedir(d);
  ReportText(spec, w, layer->instructions);
  char* scheduler = XAsprintf("%s/scheduler", layer->dir);
  Report(w, "scheduler", scheduler, "scheduler");
  free(scheduler);
}

// The kind of the file at `rel` in a policy folder.
static const char* PolicyKind(const char* rel) {
  const char* slash = strchr(rel, '/');
  size_t n = strlen(rel);
  if (!strcmp(rel, "plugin.yaml")) return "plugin";
  if (!strcmp(rel, "scheduler")) return "scheduler";
  if (!strncmp(rel, "tools/", 6) && !strchr(slash + 1, '/')) return "tool";
  if (!strncmp(rel, "hooks/", 6) && !strchr(slash + 1, '/')) return "hook";
  if (n > 9 && !strcmp(rel + n - 9, "/SKILL.md")) return "skill";
  return "file";
}

// Reports every file under `dir`, a policy folder or a folder in one, at
// most kPolicyDepth folders deep. A change to any of them stops a run, so
// the walk covers the helper files of the policy's hooks and tools too.
static void ReportTree(const Walk* w, const char* dir, int depth) {
  enum { kPolicyDepth = 8 };
  DIR* d = opendir(dir);
  struct dirent* e;
  while (d && (e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char* path = XAsprintf("%s/%s", dir, e->d_name);
    struct stat st;
    if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
      if (depth < kPolicyDepth) ReportTree(w, path, depth + 1);
    } else {
      Report(w, PolicyKind(path + strlen(w->dir) + 1), path, NULL);
    }
    free(path);
  }
  if (d) closedir(d);
}

// Reports each `file` (plugin.yaml or kit.yaml) one level under
// `parent`/`sub`, in the folder "<kind>:<entry>".
static void ReportInstalled(const Walk* w, const char* parent, const char* sub,
                            const char* kind, const char* file) {
  char* folder = XAsprintf("%s/%s", parent, sub);
  DIR* d = opendir(folder);
  struct dirent* e;
  while (d && (e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char* dir = XAsprintf("%s/%s", folder, e->d_name);
    char* path = XAsprintf("%s/%s", dir, file);
    char* label = XAsprintf("%s:%s", kind, e->d_name);
    Walk in = {w->fn, w->ctx, label, dir, 0};
    Report(&in, kind, path, file);
    free(label);
    free(path);
    free(dir);
  }
  if (d) closedir(d);
  free(folder);
}

// Walks every harness file; see trust.h.
void HarnessFiles(const Spec* spec, HarnessFileFn fn, void* ctx) {
  int own = !spec->config || strcmp(spec->config, spec->path);
  Walk w = {fn, ctx, own ? "spec" : "config", spec->dir, 0};
  const char* slash = strrchr(spec->path, '/');
  Report(&w, own ? "spec" : "config", spec->path,
         slash ? slash + 1 : spec->path);
  if (spec->config && own) {
    slash = strrchr(spec->config, '/');
    Walk c = {fn, ctx, "config", spec->dir, 0};
    Report(&c, "config", spec->config, slash ? slash + 1 : spec->config);
  }
  ReportText(spec, &w, JsonGet(spec->root, "instructions"));
  ReportText(spec, &w, JsonGet(spec->root, "first_message"));
  ReportText(spec, &w, JsonGet(spec->root, "compaction.prompt"));
  int seen_spec = 0;
  for (int i = 0; i < spec->layer_count; i++) {
    const Layer* layer = &spec->layers[i];
    int is_spec = !layer->plugin && !seen_spec;
    seen_spec |= is_spec;
    char* label = layer->plugin
                      ? XAsprintf("%s:%s", layer->policy ? "policy" : "plugin",
                                  layer->plugin)
                      : XStrdup(is_spec ? "spec" : "config");
    Walk in = {fn, ctx, label, layer->dir, layer->policy};
    if (layer->policy) {
      ReportTree(&in, layer->dir, 0);
    } else {
      ReportLayer(spec, &in, layer);
    }
    free(label);
  }
  const char* programs[] = {"compactors", "credentials", "adapters"};
  for (int i = 0; i < 3; i++) {
    cJSON* c;
    cJSON_ArrayForEach(c, JsonGet(spec->root, programs[i])) {
      if (!cJSON_IsString(c)) continue;
      char* path = PathJoin(spec->dir, c->valuestring);
      ReportNamed(spec, &w, "program", path);
      free(path);
    }
  }
  // A plugin or kit that is added, removed, or changes its plugin.yaml or
  // kit.yaml.
  char* config = ConfigDir();
  const char* parents[] = {spec->dir, config};
  for (int i = 0; i < (strcmp(spec->dir, config) ? 2 : 1); i++) {
    ReportInstalled(&w, parents[i], "plugins", "plugin", "plugin.yaml");
    ReportInstalled(&w, parents[i], "kits", "kit", "kit.yaml");
  }
  free(config);
}

// Mixes bytes into an FNV-1a hash.
static void Fnv(uint64_t* h, const void* p, size_t n) {
  const unsigned char* c = p;
  for (size_t i = 0; i < n; i++) {
    *h ^= c[i];
    *h *= 1099511628211ULL;
  }
}

// HarnessFileFn: mixes a file's path, modification time and size into the
// hash, and the mode of a tool or hook, so a chmod +x counts as a change.
static void HashFile(void* ctx, const HarnessFile* file) {
  uint64_t* h = ctx;
  int64_t size, mtime = MtimeNs(file->path, &size);
  Fnv(h, file->path, strlen(file->path));
  Fnv(h, &mtime, sizeof(mtime));
  Fnv(h, &size, sizeof(size));
  struct stat st;
  int runs = !strcmp(file->kind, "tool") || !strcmp(file->kind, "hook");
  if (runs && stat(file->path, &st) == 0) {
    Fnv(h, &st.st_mode, sizeof(st.st_mode));
  }
}

// Fingerprints every file that makes up the harness; see trust.h.
uint64_t SpecSignature(const Spec* spec) {
  uint64_t h = 1469598103934665603ULL;
  HarnessFiles(spec, HashFile, &h);
  return h;
}
