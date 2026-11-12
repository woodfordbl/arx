// manifest_test.c: unit tests for the accepted list (src/harness/manifest.c)
// over the file walk (signature.c): what a build records, what counts as a
// change, the copy limit, and that a revert puts bytes, mode and symlinks
// back. `make test` builds it with the sanitizers and runs it.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

static int g_passed, g_failed;
static char g_dir[256];

// Records one check.
static void Check(const char* what, int ok) {
  if (ok) {
    g_passed++;
    printf("  ok    %s\n", what);
  } else {
    g_failed++;
    printf("  FAIL  %s\n", what);
  }
}

// The path of `rel` in the test folder (a static buffer per call site).
static char* At(const char* rel) { return XAsprintf("%s/%s", g_dir, rel); }

// Writes `text` to `rel` with `mode`.
static void Put(const char* rel, const char* text, mode_t mode) {
  char* path = At(rel);
  char* dir = DirName(path);
  MakeDirs(dir);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  WriteAll(fd, text, strlen(text));
  fchmod(fd, mode);
  close(fd);
  free(dir);
  free(path);
}

// True when `rel` holds exactly `text` with `mode`.
static int Holds(const char* rel, const char* text, mode_t mode) {
  char* path = At(rel);
  char* have = ReadFile(path, NULL);
  struct stat st;
  int ok = have && !strcmp(have, text) && stat(path, &st) == 0 &&
           (st.st_mode & 07777) == mode;
  free(have);
  free(path);
  return ok;
}

// The record of `rel`.
static ManifestFile* Rec(const Manifest* m, const char* rel) {
  char* path = At(rel);
  ManifestFile* f = ManifestFind(m, path);
  free(path);
  return f;
}

// ManifestChangeFn: appends "<change> <rel>;" to a buffer.
static void Note(void* ctx, const ManifestFile* old, const ManifestFile* now,
                 const char* change) {
  BufferPrintf(ctx, "%s %s;", change, now ? now->rel : old->rel);
}

// The changes between `m` and the disk, as text (malloc'd).
static char* Changes(const Manifest* m, const Spec* spec) {
  Manifest now;
  Buffer b = {0};
  BufferAppendStr(&b, "");
  ManifestBuild(&now, spec, NULL, 0);
  ManifestDiff(m, &now, Note, &b);
  ManifestFree(&now);
  return BufferTake(&b);
}

// True when the changes between `m` and the disk are exactly `want`.
static int ChangesAre(const Manifest* m, const Spec* spec, const char* want) {
  char* have = Changes(m, spec);
  int ok = !strcmp(have, want);
  if (!ok) printf("        have: %s\n", have);
  free(have);
  return ok;
}

int main(void) {
  snprintf(g_dir, sizeof(g_dir), "%s/arx-manifest.XXXXXX",
           getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
  if (!mkdtemp(g_dir)) return 1;
  char* config = At("config");
  setenv("ARX_CONFIG_DIR", config, 1);
  Put("agent.yaml", "name: test\n", 0644);
  Put("hooks/before_tool", "#!/bin/sh\nexit 0\n", 0755);
  Put("tools/look", "#!/bin/sh\necho look\n", 0755);
  Put("prompts/system.md", "be kind\n", 0644);
  Put("bin/compact", "#!/bin/sh\ncat\n", 0755);
  char* target = At("tools/look");
  char* link = At("tools/alias");
  symlink(target, link);

  Layer layer = {.dir = g_dir};
  Spec spec = {.path = At("agent.yaml"), .dir = g_dir, .layers = &layer};
  spec.layer_count = 1;
  spec.root = cJSON_Parse(
      "{\"instructions\": {\"file\": \"prompts/system.md\"},"
      " \"compactors\": {\"mine\": \"bin/compact\"}}");

  Manifest m;
  ManifestBuild(&m, &spec, NULL, 1);
  ManifestFile* hook = Rec(&m, "hooks/before_tool");
  Check("a hook is recorded with its kind and folder",
        hook && !strcmp(hook->kind, "hook") && !strcmp(hook->layer, "spec") &&
            !strcmp(hook->rel, "hooks/before_tool"));
  Check("its bytes are copied",
        hook && hook->copied && hook->len == 17 &&
            !memcmp(hook->data, "#!/bin/sh\nexit 0\n", 17));
  Check("a prompt file and a named program are recorded",
        Rec(&m, "prompts/system.md") && Rec(&m, "bin/compact") &&
            !strcmp(Rec(&m, "bin/compact")->kind, "program"));
  Check("a missing scheduler is recorded as missing",
        Rec(&m, "scheduler") && !Rec(&m, "scheduler")->exists);
  Check("a symlink keeps its target",
        Rec(&m, "tools/alias") && Rec(&m, "tools/alias")->link &&
            !strcmp(Rec(&m, "tools/alias")->link, target));
  Check("a fresh list is not dirty", !ManifestDirty(&m, &spec));
  Check("and has no changes", ChangesAre(&m, &spec, ""));

  // What counts as a change.
  Put("hooks/before_tool", "#!/bin/sh\nexit 1\n", 0755);
  Put("hooks/after_tool", "#!/bin/sh\n", 0755);
  char* gone = At("prompts/system.md");
  unlink(gone);
  Put("scheduler", "#!/bin/sh\n", 0755);
  Check("the list is dirty after edits", ManifestDirty(&m, &spec));
  Check("changed, added and removed files are found",
        ChangesAre(&m, &spec,
                   "removed prompts/system.md;added hooks/after_tool;"
                   "changed hooks/before_tool;added scheduler;") ||
            ChangesAre(&m, &spec,
                       "removed prompts/system.md;changed hooks/before_tool;"
                       "added hooks/after_tool;added scheduler;"));
  Check("the changed file is not current", !ManifestCurrent(hook));

  // Revert.
  Check("a changed file reverts", ManifestRevert(hook) == 0);
  Check("with its bytes and mode",
        Holds("hooks/before_tool", "#!/bin/sh\nexit 0\n", 0755));
  Check("and is current again", ManifestCurrent(hook));
  Check("a removed file comes back",
        ManifestRevert(Rec(&m, "prompts/system.md")) == 0 &&
            Holds("prompts/system.md", "be kind\n", 0644));
  ManifestFile added = {.path = At("hooks/after_tool")};
  Check("an added file goes away",
        ManifestRevert(&added) == 0 && access(added.path, F_OK) != 0);
  Check("a file that was named but missing goes away too",
        ManifestRevert(Rec(&m, "scheduler")) == 0 &&
            access(Rec(&m, "scheduler")->path, F_OK) != 0);
  Check("nothing differs after the reverts", ChangesAre(&m, &spec, ""));

  // A chmod, and an edit that keeps size and mtime.
  chmod(target, 0644);
  Check("a chmod is a change",
        ChangesAre(&m, &spec, "changed tools/look;changed tools/alias;") ||
            ChangesAre(&m, &spec, "changed tools/alias;changed tools/look;"));
  Check("the mode reverts",
        ManifestRevert(Rec(&m, "tools/look")) == 0 &&
            Holds("tools/look", "#!/bin/sh\necho look\n", 0755));
  // The alias saw the same change through its link; take the new stat.
  ManifestFree(&m);
  ManifestBuild(&m, &spec, NULL, 1);
  ManifestFile* tool = Rec(&m, "tools/look");
  struct timeval times[2] = {{tool->mtime / 1000000000, 0},
                             {tool->mtime / 1000000000, 0}};
  sleep(1);  // so the ctime moves on a file system with coarse times
  Put("tools/look", "#!/bin/sh\necho LOOK\n", 0755);
  utimes(target, times);
  Check("an edit with the old size and mtime is still a change",
        !ManifestCurrent(tool));
  ManifestRevert(tool);

  // A symlink that became a regular file.
  unlink(link);
  Put("tools/alias", "#!/bin/sh\necho other\n", 0755);
  ManifestFile* alias = Rec(&m, "tools/alias");
  struct stat st;
  Check("a replaced symlink reverts to a link",
        ManifestRevert(alias) == 0 && lstat(link, &st) == 0 &&
            S_ISLNK(st.st_mode));
  Check("and its target is untouched",
        Holds("tools/look", "#!/bin/sh\necho look\n", 0755));

  // The rejected version is kept.
  char* kept = At("session/harness/rejected/3-hooks__before_tool");
  Put("hooks/before_tool", "#!/bin/sh\nrm -rf /\n", 0755);
  Check("the version on disk is kept aside",
        ManifestKeep(Rec(&m, "hooks/before_tool")->path, kept) == 0 &&
            Holds("session/harness/rejected/3-hooks__before_tool",
                  "#!/bin/sh\nrm -rf /\n", 0644));
  ManifestRevert(Rec(&m, "hooks/before_tool"));

  // The copy limit.
  size_t big = 3 * 1024 * 1024;
  char* bytes = XMalloc(big + 1);
  memset(bytes, 'x', big);
  bytes[big] = 0;
  Put("tools/a-big", bytes, 0755);
  Put("tools/b-big", bytes, 0755);
  Manifest limited;
  ManifestBuild(&limited, &spec, &m, 1);
  int copies = Rec(&limited, "tools/a-big")->copied +
               Rec(&limited, "tools/b-big")->copied;
  Check("copies stop at 4 MB in all",
        copies == 1 && limited.bytes <= 4 * 1024 * 1024);
  ManifestFile* over = Rec(&limited, "tools/a-big")->copied
                           ? Rec(&limited, "tools/b-big")
                           : Rec(&limited, "tools/a-big");
  Check("a file over the limit is still recorded", over->exists);
  Check("and cannot be reverted", ManifestRevert(over) == -1);
  Check("a list takes the copies of the one before",
        Rec(&limited, "hooks/before_tool")->copied &&
            !Rec(&m, "hooks/before_tool")->copied);

  printf("\n%d passed, %d failed\n", g_passed, g_failed);
  return g_failed ? 1 : 0;
}
