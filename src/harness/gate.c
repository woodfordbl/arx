// gate.c: the gate on harness edits. With a policy folder (--policy), arx
// keeps the accepted list (manifest.c). Before a changed harness loads,
// each policy folder's hooks/harness_edit sees every changed file and
// accepts or rejects it; arx writes the accepted version back over a
// rejected one. A change inside a policy folder stops the run. Without a
// sandbox this stops mistakes, not a hostile agent: the agent's bash can
// write every file arx reads.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"
#include "src/io/io.h"

// The gate of one run (the Gate of trust.h).
struct Gate {
  Manifest accepted;  // every harness file as the policy accepted it
  Manifest seen;      // the disk as the last GateReload judged it
  cJSON* reverted;    // {path: true} for the files that reload restored
  int gated;          // a policy folder has a harness_edit hook
  char* stopped;      // why the run must stop, or NULL
};

// One reload at the gate: the changes and what the hooks said.
typedef struct Round {
  struct Agent* a;
  cJSON* changes;   // [{path, rel, layer, kind, change, ...}], the hook input
  cJSON* files;     // for each change, its path as the accepted list has it
  cJSON* rejects;   // {path: {reason, policy}}
  const char* tmp;  // the private folder with the `old` copies, or NULL
  int policy;       // a file in a policy folder changed
} Round;

// Marks the run as stopped by the policy, with the first reason given.
static void Stop(Gate* g, const char* reason) {
  if (!g->stopped) g->stopped = XStrdup(reason);
}

// Why the run must stop; see trust.h.
const char* GateStopped(struct Agent* a) {
  return a->gate ? a->gate->stopped : NULL;
}

// Starts the gate after the first load; see trust.h.
void GateOpen(struct Agent* a) {
  if (a->gate || !a->spec.policy) return;
  Gate* g = XMalloc(sizeof(*g));
  memset(g, 0, sizeof(*g));
  for (int l = 0; l < a->spec.layer_count; l++) {
    char* hook = a->spec.layers[l].policy
                     ? HookPath(&a->spec.layers[l], "harness_edit")
                     : NULL;
    g->gated |= hook != NULL;
    free(hook);
  }
  ManifestBuild(&g->accepted, &a->spec, NULL, g->gated);
  a->gate = g;
}

// Frees the gate; see trust.h.
void GateFree(struct Agent* a) {
  if (!a->gate) return;
  ManifestFree(&a->gate->accepted);
  ManifestFree(&a->gate->seen);
  cJSON_Delete(a->gate->reverted);
  free(a->gate->stopped);
  free(a->gate);
  a->gate = NULL;
}

// True when a harness file differs from the accepted list; see trust.h.
int GateDirty(struct Agent* a) {
  return ManifestDirty(&a->gate->accepted, &a->spec);
}

// Checks a file right before arx runs it; see trust.h.
int GateAllows(struct Agent* a, const char* path, const char** why) {
  Gate* g = a->gate;
  if (!g) return 1;
  const ManifestFile* f = ManifestFind(&g->accepted, path);
  int policy = f && f->policy;
  for (int l = 0; !f && l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    size_t n = strlen(layer->dir);
    policy |= layer->policy && !strncmp(path, layer->dir, n) && path[n] == '/';
  }
  if (!policy && !g->gated) return 1;
  if (f && ManifestCurrent(f)) return 1;
  if (policy) {
    char* reason = XAsprintf("a file in a policy folder changed: %s", path);
    Stop(g, reason);
    free(reason);
  }
  *why =
      "changed since the policy accepted it; the policy sees it before "
      "the next model call";
  return 0;
}

// ManifestChangeFn: adds one change to the hook input, with a copy of the
// accepted version in the private folder.
static void AddChange(void* ctx, const ManifestFile* old,
                      const ManifestFile* now, const char* change) {
  Round* r = ctx;
  const ManifestFile* f = now ? now : old;
  cJSON* c = cJSON_CreateObject();
  // The hook gets an absolute path; arx keeps the one it opens files by.
  char cwd[4096];
  const char* rest = f->path;
  while (!strncmp(rest, "./", 2)) rest += 2;
  char* full = *rest == '/' || !getcwd(cwd, sizeof(cwd))
                   ? XStrdup(rest)
                   : XAsprintf("%s/%s", cwd, rest);
  cJSON_AddStringToObject(c, "path", full);
  cJSON_AddItemToArray(r->files, cJSON_CreateString(f->path));
  free(full);
  cJSON_AddStringToObject(c, "rel", f->rel);
  cJSON_AddStringToObject(c, "layer", f->layer);
  cJSON_AddStringToObject(c, "kind", f->kind);
  cJSON_AddStringToObject(c, "change", change);
  r->policy |= f->policy;
  if (now && now->exists) cJSON_AddBoolToObject(c, "exec", IsRunnable(f->path));
  char* copy = NULL;
  if (old && old->copied && r->tmp) {
    copy = XAsprintf("%s/%d", r->tmp, cJSON_GetArraySize(r->changes));
    if (WriteFileAtomic(copy, old->data, old->len) == 0) {
      cJSON_AddStringToObject(c, "old", copy);
    }
  }
  static const char* const kYaml[] = {"spec", "config", "plugin", "kit"};
  for (int i = 0; i < 4 && !f->policy; i++) {
    if (!strcmp(f->kind, kYaml[i])) EditKeys(c, copy, now, r->a->sets);
  }
  free(copy);
  cJSON_AddItemToArray(r->changes, c);
}

// Records that `policy` rejects `path`; the first reason for a path stays.
static void Reject(Round* r, const char* path, const char* reason,
                   const char* policy) {
  if (cJSON_GetObjectItemCaseSensitive(r->rejects, path)) return;
  cJSON* why = cJSON_AddObjectToObject(r->rejects, path);
  cJSON_AddStringToObject(why, "reason", reason);
  cJSON_AddStringToObject(why, "policy", policy);
}

// Rejects every change, with one reason.
static void RejectAll(Round* r, const char* reason, const char* policy) {
  cJSON* c;
  cJSON_ArrayForEach(c, r->changes) {
    Reject(r, JsonStr(c, "path", ""), reason, policy);
  }
}

// Takes in what one policy's hook printed. Returns 1 when it stops the run.
static int Answer(Round* r, const Layer* layer, cJSON* answer, cJSON* event) {
  const char* decision = JsonStr(answer, "decision", "");
  const char* reason = JsonStr(answer, "reason", "rejected by the policy");
  if (!strcmp(decision, "stop")) {
    Stop(r->a->gate, reason);
    return 1;
  }
  if (!strcmp(decision, "reject")) RejectAll(r, reason, layer->plugin);
  Buffer ignored = {0};
  cJSON* one;
  cJSON_ArrayForEach(one, JsonGet(answer, "reject")) {
    int known = 0;
    cJSON* c;
    cJSON_ArrayForEach(c, r->changes) {
      known |= !strcmp(JsonStr(c, "path", ""), one->string);
    }
    if (known) {
      Reject(r, one->string,
             cJSON_IsString(one) ? one->valuestring : "rejected by the policy",
             layer->plugin);
    } else {
      BufferPrintf(&ignored, "%s%s", ignored.len ? ", " : "", one->string);
    }
  }
  if (ignored.len) {
    char* text = XAsprintf("reject: no change has the path %s", ignored.data);
    JsonAddTruncated(event, "ignored", text, 500);
    free(text);
  }
  BufferFree(&ignored);
  return 0;
}

// Runs each policy folder's harness_edit hook with the changes, by band and
// then in layer order, and joins their rejects. The first stop ends it.
static void RunHooks(Round* r) {
  struct Agent* a = r->a;
  cJSON* input = cJSON_CreateObject();
  cJSON_AddStringToObject(input, "point", "harness_edit");
  cJSON_AddStringToObject(input, "session", a->session.id);
  cJSON_AddNumberToObject(input, "turn", a->session.turns);
  cJSON_AddItemReferenceToObject(input, "changes", r->changes);
  char* text = cJSON_PrintUnformatted(input);
  cJSON_Delete(input);
  int n = a->spec.layer_count, stop = 0;
  for (int k = 0; k < 3 * n && !stop; k++) {
    const Layer* layer = &a->spec.layers[k % n];
    int band = HookBand(&a->spec, layer, "harness_edit");
    char* path =
        layer->policy && band == k / n ? HookPath(layer, "harness_edit") : NULL;
    if (!path) continue;
    cJSON *answer = NULL, *event = NULL;
    int rc = HookRunOne(a, layer, "harness_edit", path, text, &answer, &event);
    cJSON* options = HookOptions(&a->spec, layer, "harness_edit");
    if (rc < 0 && strcmp(JsonStr(options, "fail", "closed"), "open")) {
      char* why =
          XAsprintf("the harness_edit hook of %s failed", layer->plugin);
      RejectAll(r, why, layer->plugin);
      free(why);
    } else if (answer) {
      stop = Answer(r, layer, answer, event);
    }
    EventSend(event);
    cJSON_Delete(answer);
    free(path);
  }
  free(text);
}

// Restores the accepted version of one rejected change and keeps the
// rejected one in the session. Returns 0, or -1 when arx cannot restore it.
static int Revert(Round* r, cJSON* change, const char* path,
                  const char* reason) {
  struct Agent* a = r->a;
  Gate* g = a->gate;
  const char* rel = JsonStr(change, "rel", "");
  Buffer flat = {0};  // the name of the kept file: "/" becomes "__"
  for (const char* p = rel; *p; p++) {
    if (*p == '/') {
      BufferAppendStr(&flat, "__");
    } else {
      BufferAppend(&flat, p, 1);
    }
  }
  char* kept = XAsprintf("%s/harness/rejected/%d-%s", a->session.dir,
                         a->session.turns, flat.data ? flat.data : "file");
  int removed = !strcmp(JsonStr(change, "change", ""), "removed");
  if (!removed) ManifestKeep(path, kept);
  ManifestFile gone = {.path = (char*)path};  // an added file: nothing before
  ManifestFile* old = ManifestFind(&g->accepted, path);
  int rc = ManifestRevert(old ? old : &gone);
  if (rc == 0) {
    if (!g->reverted) g->reverted = cJSON_CreateObject();
    cJSON_AddTrueToObject(g->reverted, path);
    int other = strcmp(JsonStr(change, "layer", ""), "spec");
    AgentNote(a,
              "The policy rejected your change to %s (%s). arx restored the "
              "previous version.%s%s%s",
              other ? JsonStr(change, "path", "") : rel, reason,
              removed ? "" : " Your version is in ", removed ? "" : kept,
              removed ? "" : ".");
  }
  free(kept);
  BufferFree(&flat);
  return rc;
}

// Sends one harness.edit event for each change, and reverts the rejected
// ones. Returns the number of rejected changes.
static int Settle(Round* r) {
  Gate* g = r->a->gate;
  int rejected = 0, at = 0;
  cJSON* c;
  cJSON_ArrayForEach(c, r->changes) {
    const char* file = cJSON_GetArrayItem(r->files, at++)->valuestring;
    cJSON* why =
        cJSON_GetObjectItemCaseSensitive(r->rejects, JsonStr(c, "path", ""));
    const char* reason = JsonStr(why, "reason", "");
    if (why && !g->stopped && Revert(r, c, file, reason)) {
      char* text = XAsprintf("arx cannot restore %s, which the policy rejected",
                             JsonStr(c, "path", ""));
      Stop(g, text);
      free(text);
    }
    rejected += why != NULL;
    cJSON* e = EventNew("harness.edit");
    const char* fields[] = {"path", "layer", "kind", "change"};
    for (int i = 0; i < 4; i++) {
      cJSON_AddStringToObject(e, fields[i], JsonStr(c, fields[i], ""));
    }
    cJSON_AddStringToObject(e, "decision",
                            g->stopped ? "stop"
                            : why      ? "reject"
                                       : "accept");
    if (why || g->stopped) {
      cJSON_AddStringToObject(e, "reason", why ? reason : g->stopped);
    }
    if (why) cJSON_AddStringToObject(e, "policy", JsonStr(why, "policy", ""));
    EventSend(e);
  }
  return rejected;
}

// Makes a new folder that only this user can read, outside the working
// directory, for the copies that a hook reads (malloc'd), or returns NULL.
// mkdir() fails on a name that exists, so nobody else made the folder.
static char* PrivateFolder(void) {
  const char* base = getenv("TMPDIR");
  for (int i = 0; i < 100; i++) {
    char* dir =
        XAsprintf("%s/arx-gate.%d-%.0f-%d", base && *base ? base : "/tmp",
                  (int)getpid(), Now() * 1e6, i);
    if (mkdir(dir, 0700) == 0) return dir;
    free(dir);
  }
  return NULL;
}

// Judges the changes before a reload; see trust.h.
int GateReload(struct Agent* a, int* rejected) {
  Gate* g = a->gate;
  char* tmp = g->gated ? PrivateFolder() : NULL;
  Round r = {.a = a,
             .changes = cJSON_CreateArray(),
             .files = cJSON_CreateArray(),
             .rejects = cJSON_CreateObject(),
             .tmp = tmp};
  ManifestFree(&g->seen);
  cJSON_Delete(g->reverted);
  g->reverted = NULL;
  ManifestBuild(&g->seen, &a->spec, NULL, 0);
  ManifestDiff(&g->accepted, &g->seen, AddChange, &r);
  if (r.policy) Stop(g, "a file in a policy folder changed");
  if (!g->stopped && g->gated && cJSON_GetArraySize(r.changes)) RunHooks(&r);
  *rejected = g->gated || g->stopped ? Settle(&r) : 0;
  for (int i = 0; r.tmp && i < cJSON_GetArraySize(r.changes); i++) {
    char* copy = XAsprintf("%s/%d", r.tmp, i);
    unlink(copy);
    free(copy);
  }
  if (tmp) rmdir(tmp);
  free(tmp);
  cJSON_Delete(r.changes);
  cJSON_Delete(r.files);
  cJSON_Delete(r.rejects);
  return g->stopped ? kExitPolicy : -1;
}

// Takes the disk as accepted after a reload; see trust.h.
void GateAccept(struct Agent* a) {
  Gate* g = a->gate;
  Manifest next;
  ManifestBuild(&next, &a->spec, &g->accepted, g->gated);
  for (int i = 0; i < next.count; i++) {
    ManifestFile* f = &next.files[i];
    const ManifestFile* judged = ManifestFind(&g->seen, f->path);
    if (cJSON_GetObjectItemCaseSensitive(g->reverted, f->path)) continue;
    if (judged ? ManifestSame(judged, f) : !f->policy) continue;
    // The file changed after the policy judged it. Keep what the policy
    // saw, without a copy, so the next check finds the change.
    next.bytes -= f->copied ? f->len : 0;
    free(f->data);
    f->data = NULL;
    f->copied = 0;
    f->exists = judged ? judged->exists : 0;
    f->dev = judged ? judged->dev : 0;
    f->ino = judged ? judged->ino : 0;
    f->size = judged ? judged->size : 0;
    f->mtime = judged ? judged->mtime : 0;
    f->ctime = judged ? judged->ctime : 0;
    f->mode = judged ? judged->mode : 0;
    free(f->link);
    f->link = judged && judged->link ? XStrdup(judged->link) : NULL;
  }
  ManifestFree(&g->accepted);
  ManifestFree(&g->seen);
  g->accepted = next;
}
