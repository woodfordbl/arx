// kits.c: kits. A kit is a folder with a kit.yaml, prompts/ and init/, and
// no executables: it chooses the plugins of a run, their order, their
// settings and the prompt, and so makes one kind of agent. If something
// runs, it belongs in a plugin; a kit only chooses.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// How deep `extends` may go, which also stops a kit that extends itself.
static const int kMaxExtends = 8;

// The folder of the installed kit `name` (malloc'd): kits/<name> next to
// the spec, else in the config folder; NULL if neither has a kit.yaml.
static char* KitFind(const char* spec_dir, const char* name) {
  char* config = ConfigDir();
  const char* parents[] = {spec_dir, config};
  char* found = NULL;
  for (int i = 0; i < 2 && !found && *name && !strchr(name, '/'); i++) {
    if (!parents[i]) continue;
    char* yaml = XAsprintf("%s/kits/%s/kit.yaml", parents[i], name);
    if (!access(yaml, R_OK)) found = XAsprintf("%s/kits/%s", parents[i], name);
    free(yaml);
  }
  free(config);
  return found;
}

// Appends the first executable file under `dir` to `found`. Returns 1 when
// there is one.
static int FindExecutable(const char* dir, Buffer* found, int depth) {
  DIR* d = depth < 16 ? opendir(dir) : NULL;
  struct dirent* e;
  int any = 0;
  while (d && !any && (e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    char* path = XAsprintf("%s/%s", dir, e->d_name);
    struct stat st;
    if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
      any = FindExecutable(path, found, depth + 1);
    } else if (stat(path, &st) == 0 && (st.st_mode & 0111)) {
      BufferAppendStr(found, path);
      any = 1;
    }
    free(path);
  }
  if (d) closedir(d);
  return any;
}

// Parses and checks `dir`/kit.yaml into `kit`. Returns 0, or -1 with the
// problems in `err`.
static int ReadKit(const char* dir, Spec* kit, Buffer* err) {
  size_t before = err->len;
  Buffer exe = {0};
  memset(kit, 0, sizeof(*kit));
  kit->path = XAsprintf("%s/kit.yaml", dir);
  kit->dir = XStrdup(dir);
  if (access(kit->path, R_OK)) {
    BufferPrintf(err, "%s: not a kit (no kit.yaml)\n", dir);
  } else if (SpecParse(kit->path, kit, err) == 0) {
    KitValidate(kit, err);
  }
  if (FindExecutable(dir, &exe, 0)) {
    BufferPrintf(err,
                 "%s: is executable, and a kit holds no code (put it in a "
                 "plugin, or chmod -x it)\n",
                 exe.data);
  }
  BufferFree(&exe);
  return err->len == before ? 0 : -1;
}

// The entry of `list` that names the same plugin as `entry`, or NULL.
// EntryName returns a static buffer, so one name is copied first.
static cJSON* Find(cJSON* list, const cJSON* entry) {
  char name[256];
  snprintf(name, sizeof(name), "%s", EntryName(entry));
  cJSON* c;
  cJSON_ArrayForEach(c, list) {
    if (!strcmp(EntryName(c), name)) return c;
  }
  return NULL;
}

// Adds `enable` to the end of `list` and takes `disable` out of it.
static void EnableDisable(cJSON* list, cJSON* enable, cJSON* disable) {
  cJSON* c;
  cJSON_ArrayForEach(c, enable) {
    if (!Find(list, c)) cJSON_AddItemToArray(list, cJSON_Duplicate(c, 1));
  }
  cJSON_ArrayForEach(c, disable) {
    cJSON* e = cJSON_IsString(c) ? Find(list, c) : NULL;
    if (e) cJSON_Delete(cJSON_DetachItemViaPointer(list, e));
  }
}

// True when an entry of `list` names an exact version (name@ref).
static int Pinned(const cJSON* list) {
  const cJSON* c;
  cJSON_ArrayForEach(c, list) {
    const char* ref = cJSON_IsString(c) ? c->valuestring : c->child->string;
    if (strchr(ref, '@')) return 1;
  }
  return 0;
}

// Loads kit `name` into `kit`, with the kits it extends below it.
static int Load(const char* spec_dir, const char* name, Kit* kit, Buffer* err,
                int depth) {
  char* dir = KitFind(spec_dir, name);
  if (!dir) {
    BufferPrintf(err, "kit %s is not installed: run `arx kit add %s`\n", name,
                 name);
    return -1;
  }
  Spec yaml;
  int rc = ReadKit(dir, &yaml, err);
  const char* own = JsonStr(yaml.root, "name", name);
  if (rc == 0 && strcmp(own, name)) {
    BufferPrintf(err, "%s: name \"%s\" must match the folder name\n", yaml.path,
                 own);
    rc = -1;
  }
  const char* parent = rc ? NULL : JsonStr(yaml.root, "extends", NULL);
  if (parent && depth >= kMaxExtends) {
    BufferPrintf(err, "%s: extends goes more than %d kits deep\n", yaml.path,
                 kMaxExtends);
    rc = -1;
  } else if (parent) {
    rc = Load(spec_dir, parent, kit, err, depth + 1);
  }
  if (rc == 0) {
    cJSON* own_list = JsonGet(yaml.root, "plugins");
    if (own_list || !kit->plugins) {
      cJSON_Delete(kit->plugins);
      kit->plugins =
          own_list ? cJSON_Duplicate(own_list, 1) : cJSON_CreateArray();
    }
    EnableDisable(kit->plugins, JsonGet(yaml.root, "enable"),
                  JsonGet(yaml.root, "disable"));
    cJSON* settings = JsonGet(yaml.root, "model_settings");
    if (settings && !kit->model_settings) {
      kit->model_settings = cJSON_CreateObject();
    }
    if (settings) JsonMergeOver(kit->model_settings, settings);
    const char* prompt = JsonStr(yaml.root, "prompt", NULL);
    if (prompt) {
      free(kit->prompt);
      kit->prompt = PathJoin(dir, prompt);
    }
    kit->pinned = Pinned(kit->plugins);
    free(kit->dir);
    kit->dir = dir;
    dir = NULL;
  }
  SpecFree(&yaml);
  free(dir);
  return rc;
}

// Loads a kit and the kits it extends; see harness.h.
int KitLoad(const char* spec_dir, const char* name, Kit* kit, Buffer* err) {
  memset(kit, 0, sizeof(*kit));
  int rc = Load(spec_dir, name, kit, err, 0);
  if (rc) KitFree(kit);
  return rc;
}

// Frees a kit; see harness.h.
void KitFree(Kit* kit) {
  free(kit->dir);
  cJSON_Delete(kit->plugins);
  cJSON_Delete(kit->model_settings);
  free(kit->prompt);
  memset(kit, 0, sizeof(*kit));
}

// Appends "key=" and the names in a list, space-separated, as written.
static void AppendList(Buffer* out, const char* key, cJSON* list) {
  cJSON* c;
  int first = 1;
  BufferPrintf(out, "%s=", key);
  cJSON_ArrayForEach(c, list) {
    const char* ref = cJSON_IsString(c) ? c->valuestring
                      : c->child        ? c->child->string
                                        : "";
    BufferPrintf(out, "%s%s", first ? "" : " ", ref);
    first = 0;
  }
  BufferAppendStr(out, "\n");
}

// Describes a kit folder; see harness.h.
int KitDescribe(const char* dir, Buffer* out, Buffer* err) {
  Spec kit;
  int rc = ReadKit(dir, &kit, err);
  if (rc == 0) {
    const char* keys[] = {"name", "version", "description", "extends"};
    for (int i = 0; i < 4; i++) {
      const char* value = JsonStr(kit.root, keys[i], "");
      BufferPrintf(out, "%s=", keys[i]);
      for (const char* p = value; *p; p++) {
        BufferAppend(out, *p == '\n' ? " " : p, 1);
      }
      BufferAppendStr(out, "\n");
    }
    AppendList(out, "plugins", JsonGet(kit.root, "plugins"));
    AppendList(out, "enable", JsonGet(kit.root, "enable"));
    AppendList(out, "disable", JsonGet(kit.root, "disable"));
  }
  SpecFree(&kit);
  return rc;
}

// Appends one kit.lock line for the part in `dir`, from its .arx-source.
static void LockLine(Buffer* out, const char* lead, const char* name,
                     const char* dir) {
  char* path = XAsprintf("%s/.arx-source", dir);
  char* text = ReadFile(path, NULL);
  cJSON* part = cJSON_CreateObject();
  cJSON_AddStringToObject(part, "name", name);
  char* real = realpath(dir, NULL);
  struct stat st;
  if (lstat(dir, &st) == 0 && S_ISLNK(st.st_mode)) {
    char* link = XAsprintf("link to %s", real ? real : dir);
    cJSON_AddStringToObject(part, "source", link);
    free(link);
  }
  for (char* line = text; line && *line;) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    char* eq = strchr(line, '=');
    if (eq && (!strncmp(line, "source=", 7) || !strncmp(line, "commit=", 7))) {
      *eq = 0;
      if (!cJSON_GetObjectItem(part, line)) {
        cJSON_AddStringToObject(part, line, eq + 1);
      }
    }
    line = nl ? nl + 1 : NULL;
  }
  if (!cJSON_GetObjectItem(part, "source")) {
    cJSON_AddStringToObject(part, "source", "(copied by hand)");
  }
  char* json = cJSON_PrintUnformatted(part);  // JSON is valid YAML
  BufferPrintf(out, "%s%s\n", lead, json);
  free(json);
  cJSON_Delete(part);
  free(real);
  free(text);
  free(path);
}

// Writes kit.lock; see harness.h.
void KitLockWrite(const Spec* spec) {
  if (!spec->kit || !spec->kit_pinned || !spec->dir) return;
  Buffer b = {0};
  BufferPrintf(&b,
               "# kit.lock: the exact parts of kit %s, written by arx because "
               "the kit\n# pins versions. Keep it with the project to repeat "
               "a run.\nkit: ",
               spec->kit);
  LockLine(&b, "", spec->kit, spec->kit_dir);
  BufferAppendStr(&b, "plugins:\n");
  for (int i = 0; i < spec->layer_count; i++) {
    const Layer* layer = &spec->layers[i];
    if (layer->plugin) LockLine(&b, "  - ", layer->plugin, layer->dir);
  }
  char* path = PathJoin(spec->dir, "kit.lock");
  char* old = ReadFile(path, NULL);
  if (!old || strcmp(old, b.data)) WriteFileAtomic(path, b.data, b.len);
  free(old);
  free(path);
  BufferFree(&b);
}
