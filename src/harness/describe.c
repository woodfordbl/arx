// describe.c: `arx check --plugin DIR`: reads and checks one plugin
// without loading it, and prints key=value lines for scripts such as
// `arx plugin`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// True when `program` is an executable on PATH, or at its path when it
// has a '/'.
static int OnPath(const char* program) {
  if (strchr(program, '/')) return access(program, X_OK) == 0;
  const char* path = getenv("PATH");
  for (const char* p = path ? path : ""; *p;) {
    size_t len = strcspn(p, ":");
    char* full = XAsprintf("%.*s/%s", (int)len, p, program);
    int found = len && access(full, X_OK) == 0;
    free(full);
    if (found) return 1;
    p += len + (p[len] == ':');
  }
  return 0;
}

// Appends "key=value", with line breaks turned into spaces.
static void AppendField(Buffer* out, const char* key, const char* value) {
  BufferPrintf(out, "%s=", key);
  for (const char* p = value ? value : ""; *p; p++) {
    BufferAppend(out, *p == '\n' || *p == '\r' ? " " : p, 1);
  }
  BufferAppendStr(out, "\n");
}

// Appends "key=" and the entries of `dir`, space-separated. With `inner`,
// only entries that have `dir/<entry>/<inner>`.
static void AppendNames(Buffer* out, const char* key, const char* dir,
                        const char* inner) {
  char** names;
  int n = ListNames(dir, &names);
  Buffer list = {0};
  for (int i = 0; i < n; i++) {
    char* path = inner ? XAsprintf("%s/%s/%s", dir, names[i], inner) : NULL;
    size_t len = strlen(names[i]);
    // tools/<name>.json is the schema of a tool, not a tool.
    int schema = !strcmp(key, "tools") && len > 5 &&
                 !strcmp(names[i] + len - 5, ".json");
    if (!schema && (!path || !access(path, R_OK))) {
      BufferPrintf(&list, "%s%s", list.len ? " " : "", names[i]);
    }
    free(path);
    free(names[i]);
  }
  free(names);
  AppendField(out, key, list.data);
  BufferFree(&list);
}

// Appends "key=" and the names of the map `key` in plugin.yaml, or the
// items of the list `key`, space-separated.
static void AppendKeys(Buffer* out, cJSON* root, const char* key) {
  Buffer list = {0};
  cJSON* c;
  cJSON_ArrayForEach(c, JsonGet(root, key)) {
    const char* name =
        cJSON_IsString(c) && !c->string ? c->valuestring : c->string;
    BufferPrintf(&list, "%s%s", list.len ? " " : "", name ? name : "");
  }
  AppendField(out, key, list.data);
  BufferFree(&list);
}

// Describes a plugin; see harness.h.
int PluginDescribe(const char* dir, Buffer* out, Buffer* err) {
  Spec plugin;
  int rc = PluginRead(dir, &plugin, err);
  if (rc == 0) {
    cJSON* root = plugin.root;
    char* real = realpath(dir, NULL);
    const char* base = strrchr(real ? real : dir, '/');
    Buffer
      requires
    = {0}, missing = {0};
    cJSON* c;
    AppendField(out, "name", JsonStr(root, "name", base ? base + 1 : dir));
    AppendField(out, "version", JsonStr(root, "version", ""));
    AppendField(out, "description", JsonStr(root, "description", ""));
    AppendField(out, "arx", JsonStr(root, "arx", ""));
    cJSON_ArrayForEach(c, JsonGet(root, "requires")) {
      BufferPrintf(&requires, "%s%s", requires.len ? " " : "", c->valuestring);
      if (!OnPath(c->valuestring)) {
        BufferPrintf(&missing, "%s%s", missing.len ? " " : "", c->valuestring);
      }
    }
    AppendField(out, "requires", requires.data);
    AppendField(out, "missing", missing.data);
    const char* parts[] = {"tools", "hooks", "skills", "commands"};
    for (int i = 0; i < 4; i++) {
      char* sub = PathJoin(dir, parts[i]);
      AppendNames(out, parts[i], sub, i == 2 ? "SKILL.md" : NULL);
      free(sub);
    }
    const char* programs[] = {"credentials", "adapters", "hosts"};
    for (int i = 0; i < 3; i++) AppendKeys(out, root, programs[i]);
    // The size of the raw text it adds to the prompt, and the request
    // fields it sets.
    char* text = SpecText(&plugin, JsonGet(root, "instructions"), NULL);
    char* bytes = text ? XAsprintf("%zu", strlen(text)) : NULL;
    AppendField(out, "instructions", bytes);
    AppendKeys(out, root, "model_settings");
    free(bytes);
    free(text);
    BufferFree(&requires);
    BufferFree(&missing);
    free(real);
  }
  SpecFree(&plugin);
  return rc;
}
