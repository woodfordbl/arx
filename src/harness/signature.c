// signature.c: the fingerprint for hot reload. It covers the spec, the
// prompt files that it and each plugin name, kit.yaml files, and tools/,
// hooks/ and skills in every layer, using stat() only, so arx can check it
// before every model call.

#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// Mixes bytes into an FNV-1a hash.
static void Fnv(uint64_t* h, const void* p, size_t n) {
  const unsigned char* c = p;
  for (size_t i = 0; i < n; i++) {
    *h ^= c[i];
    *h *= 1099511628211ULL;
  }
}

// Mixes a file's path, modification time and size into the hash.
static void HashFile(uint64_t* h, const char* path) {
  int64_t size, mtime = MtimeNs(path, &size);
  Fnv(h, path, strlen(path));
  Fnv(h, &mtime, sizeof(mtime));
  Fnv(h, &size, sizeof(size));
}

// Hashes every entry of `dir` (or `dir/<entry>/<inner>` when `inner` is set),
// including file modes so a chmod +x counts as a change.
static void HashDir(uint64_t* h, const char* dir, const char* inner) {
  DIR* d = opendir(dir);
  if (!d) return;
  struct dirent* e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char* path = inner ? XAsprintf("%s/%s/%s", dir, e->d_name, inner)
                       : XAsprintf("%s/%s", dir, e->d_name);
    struct stat st;
    HashFile(h, path);
    if (!inner && stat(path, &st) == 0) Fnv(h, &st.st_mode, sizeof(st.st_mode));
    free(path);
  }
  closedir(d);
}

// Hashes the files that a text node points at. A plugin's paths are
// absolute, so PathJoin keeps them.
static void HashTextFiles(uint64_t* h, const Spec* spec, cJSON* node) {
  if (cJSON_IsArray(node)) {
    for (cJSON* c = node->child; c; c = c->next) HashTextFiles(h, spec, c);
    return;
  }
  const char* file = JsonStr(node, "file", NULL);
  if (!file) return;
  char* path = PathJoin(spec->dir, file);
  HashFile(h, path);
  free(path);
}

// Fingerprints every file that makes up the harness; see harness.h.
uint64_t SpecSignature(const Spec* spec) {
  uint64_t h = 1469598103934665603ULL;
  HashFile(&h, spec->path);
  if (spec->config) HashFile(&h, spec->config);
  HashTextFiles(&h, spec, JsonGet(spec->root, "instructions"));
  HashTextFiles(&h, spec, JsonGet(spec->root, "first_message"));
  HashTextFiles(&h, spec, JsonGet(spec->root, "compaction.prompt"));
  for (int i = 0; i < spec->layer_count; i++) {
    const Layer* layer = &spec->layers[i];
    char* dir = PathJoin(layer->dir, "tools");
    HashDir(&h, dir, NULL);
    free(dir);
    dir = PathJoin(layer->dir, "hooks");
    HashDir(&h, dir, NULL);
    free(dir);
    if (layer->skills) HashDir(&h, layer->skills, "SKILL.md");
    HashTextFiles(&h, spec, layer->instructions);
  }
  // A plugin or kit that is added, removed, or changes its plugin.yaml or
  // kit.yaml.
  char* config = ConfigDir();
  const char* parents[] = {spec->dir, config};
  for (int i = 0; i < 2; i++) {
    char* dir = PathJoin(parents[i], "plugins");
    HashDir(&h, dir, "plugin.yaml");
    free(dir);
    dir = PathJoin(parents[i], "kits");
    HashDir(&h, dir, "kit.yaml");
    free(dir);
  }
  free(config);
  return h;
}
