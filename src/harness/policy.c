// policy.c: policy folders. A policy folder is a plugin folder that the
// person who starts a run names with --policy DIR or ARX_POLICY. It loads
// before the spec folder, and no key in agent.yaml, config.yaml or a kit
// can remove it, because none of them names it.

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// Adds the absolute path of folder `dir` to `list`, once. A problem goes
// to `err` as "arx: policy DIR: <problem>".
static void AddFolder(cJSON* list, const char* dir, Buffer* err) {
  char* real = realpath(dir, NULL);
  struct stat st;
  if (!real || stat(real, &st)) {
    BufferPrintf(err, "arx: policy %s: %s\n", dir, strerror(errno));
  } else if (!S_ISDIR(st.st_mode)) {
    BufferPrintf(err, "arx: policy %s: not a folder\n", dir);
  } else {
    cJSON* c;
    int have = 0;
    cJSON_ArrayForEach(c, list) have |= !strcmp(c->valuestring, real);
    if (!have) cJSON_AddItemToArray(list, cJSON_CreateString(real));
  }
  free(real);
}

// Resolves the policy folders; see trust.h.
int PolicyResolve(cJSON** policy, Buffer* err) {
  size_t before = err->len;
  cJSON* list = cJSON_CreateArray();
  const char* env = getenv("ARX_POLICY");
  while (env && *env) {
    size_t n = strcspn(env, ":");
    char* dir = XStrndup(env, n);
    if (n) AddFolder(list, dir, err);
    free(dir);
    env += n + (env[n] == ':');
  }
  cJSON* c;
  cJSON_ArrayForEach(c, *policy) AddFolder(list, c->valuestring, err);
  cJSON_Delete(*policy);
  *policy = cJSON_GetArraySize(list) ? list : NULL;
  if (!*policy) cJSON_Delete(list);
  return err->len == before ? 0 : -1;
}
