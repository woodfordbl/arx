// manifest.c: the accepted list. It records every harness file as the
// policy last accepted it: a full stat(), and for a file outside the policy
// folders its bytes, mode and symlink target, so a rejected change can be
// reverted. The copies live in memory, because the agent can write the
// session folder. The list comes from the same walk as the reload
// fingerprint (HarnessFiles), so the gate covers what reload covers.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// All copies together stay under this; a file over it is not copied.
static const size_t kCopyLimit = 4 * 1024 * 1024;

// A stat time in nanoseconds.
static int64_t Ns(struct timespec t) {
  return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

// Fills the stat fields and the symlink target of `f` from the disk. A
// missing file, or one that is not a regular file, does not exist here.
static void StatFile(ManifestFile* f) {
  struct stat st, link;
  char target[4096];
  free(f->link);
  f->link = NULL;
  f->exists = stat(f->path, &st) == 0 && S_ISREG(st.st_mode);
  f->dev = f->ino = f->size = f->mtime = f->ctime = 0;
  f->mode = 0;
  if (!f->exists) return;
  f->dev = (int64_t)st.st_dev;
  f->ino = (int64_t)st.st_ino;
  f->size = (int64_t)st.st_size;
#ifdef __APPLE__
  f->mtime = Ns(st.st_mtimespec);
  f->ctime = Ns(st.st_ctimespec);
#else
  f->mtime = Ns(st.st_mtim);
  f->ctime = Ns(st.st_ctim);
#endif
  f->mode = (uint32_t)st.st_mode;
  if (lstat(f->path, &link) == 0 && S_ISLNK(link.st_mode)) {
    ssize_t n = readlink(f->path, target, sizeof(target) - 1);
    if (n > 0) f->link = XStrndup(target, (size_t)n);
  }
}

// True when two records describe the same version; see trust.h.
int ManifestSame(const ManifestFile* a, const ManifestFile* b) {
  int a_exists = a && a->exists, b_exists = b && b->exists;
  if (!a_exists || !b_exists) return a_exists == b_exists;
  if (!a->link != !b->link || (a->link && strcmp(a->link, b->link))) return 0;
  return a->dev == b->dev && a->ino == b->ino && a->size == b->size &&
         a->mtime == b->mtime && a->ctime == b->ctime && a->mode == b->mode;
}

// Finds a file by path; see trust.h.
ManifestFile* ManifestFind(const Manifest* m, const char* path) {
  // Paths are compared without a leading "./", so "./hooks/x" finds
  // "hooks/x".
  while (!strncmp(path, "./", 2)) path += 2;
  for (int i = 0; i < m->count; i++) {
    const char* have = m->files[i].path;
    while (!strncmp(have, "./", 2)) have += 2;
    if (!strcmp(have, path)) return &m->files[i];
  }
  return NULL;
}

// Reads the bytes of `f` when they fit under the limit and the file did
// not change while it was read.
static void CopyFile(Manifest* m, ManifestFile* f) {
  if (!f->exists || f->size < 0 || (size_t)f->size > kCopyLimit - m->bytes) {
    return;
  }
  size_t len = 0;
  char* data = ReadFile(f->path, &len);
  ManifestFile after = {.path = f->path};
  StatFile(&after);
  if (data && ManifestSame(f, &after)) {
    f->data = data;
    f->len = len;
    f->copied = 1;
    m->bytes += len;
  } else {
    free(data);
  }
  free(after.link);
}

// What a build needs while it walks.
typedef struct BuildCtx {
  Manifest* m;
  Manifest* prev;
  int copy;
} BuildCtx;

// HarnessFileFn: adds one file to the list.
static void AddFile(void* ctx, const HarnessFile* file) {
  BuildCtx* b = ctx;
  Manifest* m = b->m;
  if (ManifestFind(m, file->path)) return;  // named twice
  m->files = XRealloc(m->files, (size_t)(m->count + 1) * sizeof(*m->files));
  ManifestFile* f = &m->files[m->count++];
  memset(f, 0, sizeof(*f));
  f->path = XStrdup(file->path);
  f->kind = XStrdup(file->kind);
  f->layer = XStrdup(file->layer);
  f->rel = XStrdup(file->rel);
  f->policy = file->policy;
  StatFile(f);
  if (!b->copy || f->policy || !f->exists) return;
  ManifestFile* old = b->prev ? ManifestFind(b->prev, f->path) : NULL;
  if (old && old->copied && ManifestSame(old, f)) {
    f->data = old->data;  // the same version: take its copy
    f->len = old->len;
    f->copied = 1;
    m->bytes += f->len;
    old->data = NULL;
    old->copied = 0;
  } else {
    CopyFile(m, f);
  }
}

// Builds the list; see trust.h.
void ManifestBuild(Manifest* m, const Spec* spec, Manifest* prev, int copy) {
  BuildCtx b = {m, prev, copy};
  memset(m, 0, sizeof(*m));
  HarnessFiles(spec, AddFile, &b);
}

// Frees the list; see trust.h.
void ManifestFree(Manifest* m) {
  for (int i = 0; i < m->count; i++) {
    ManifestFile* f = &m->files[i];
    free(f->path);
    free(f->kind);
    free(f->layer);
    free(f->rel);
    free(f->data);
    free(f->link);
  }
  free(m->files);
  memset(m, 0, sizeof(*m));
}

// Compares two lists; see trust.h.
int ManifestDiff(const Manifest* old, const Manifest* now, ManifestChangeFn fn,
                 void* ctx) {
  int changes = 0;
  for (int i = 0; i < now->count; i++) {
    const ManifestFile* f = &now->files[i];
    const ManifestFile* before = ManifestFind(old, f->path);
    if (ManifestSame(before, f)) continue;
    changes++;
    const char* change = !f->exists                 ? "removed"
                         : before && before->exists ? "changed"
                                                    : "added";
    if (fn) fn(ctx, before, f, change);
  }
  for (int i = 0; i < old->count; i++) {
    const ManifestFile* f = &old->files[i];
    if (!f->exists || ManifestFind(now, f->path)) continue;
    changes++;
    if (fn) fn(ctx, f, NULL, "removed");
  }
  return changes;
}

// HarnessFileFn for ManifestDirty: counts the files, and the ones that are
// not as the list has them. The files come in the order of the build, so
// the record is at the cursor unless something changed.
typedef struct DirtyCtx {
  const Manifest* m;
  int at, seen, dirty;
} DirtyCtx;

// HarnessFileFn: checks one file against its record.
static void CheckFile(void* ctx, const HarnessFile* file) {
  DirtyCtx* d = ctx;
  const Manifest* m = d->m;
  const ManifestFile* have =
      d->at < m->count && !strcmp(m->files[d->at].path, file->path)
          ? &m->files[d->at]
          : ManifestFind(m, file->path);
  if (have == &m->files[d->at]) {
    d->at++;
    d->seen++;  // a file that is named twice counts once
  }
  ManifestFile now = {.path = (char*)file->path};
  StatFile(&now);
  if (!ManifestSame(have, &now)) d->dirty = 1;
  free(now.link);
}

// True when the disk differs from the list; see trust.h.
int ManifestDirty(const Manifest* m, const Spec* spec) {
  DirtyCtx d = {m, 0, 0, 0};
  HarnessFiles(spec, CheckFile, &d);
  // A record that the walk did not reach in order is a file that is gone,
  // or the order changed: both get the full comparison of a reload.
  return d.dirty || d.seen != m->count;
}

// True when the file is still the accepted version; see trust.h.
int ManifestCurrent(const ManifestFile* f) {
  ManifestFile now = {.path = f->path};
  StatFile(&now);
  int same = ManifestSame(f, &now);
  free(now.link);
  return same;
}

// Writes `len` bytes to `path` with `mode` through a temp file in the same
// folder and rename(), so a reader never sees half a file. Returns 0 or -1.
static int WriteExact(const char* path, const char* data, size_t len,
                      uint32_t mode) {
  char* tmp = XAsprintf("%s.arx-revert", path);
  unlink(tmp);
  int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  int ok = fd >= 0 && WriteAll(fd, data, len) == 0 &&
           fchmod(fd, (mode_t)(mode & 07777)) == 0;
  if (fd >= 0) close(fd);
  if (!ok || rename(tmp, path)) {
    unlink(tmp);
    ok = 0;
  }
  free(tmp);
  return ok ? 0 : -1;
}

// Writes the accepted version back; see trust.h.
int ManifestRevert(ManifestFile* f) {
  struct stat st;
  int is_link = lstat(f->path, &st) == 0 && S_ISLNK(st.st_mode);
  if (!f->exists) {  // the file was added: it goes away
    if (unlink(f->path) && errno != ENOENT) return -1;
    return 0;
  }
  if (!f->copied) return -1;
  char* dir = DirName(f->path);
  MakeDirs(dir);
  free(dir);
  int rc = 0;
  if (f->link) {
    // Put the link back, then the bytes of the file it points at.
    char target[4096];
    ssize_t n = is_link ? readlink(f->path, target, sizeof(target) - 1) : -1;
    if (n < 0 || (size_t)n != strlen(f->link) || memcmp(target, f->link, n)) {
      unlink(f->path);
      rc = symlink(f->link, f->path);
    }
    char* real = rc ? NULL : realpath(f->path, NULL);
    if (real && !ManifestCurrent(f))
      rc = WriteExact(real, f->data, f->len, f->mode);
    if (!real && !rc) {
      // The file the link points at is gone: write it through the link.
      int fd = open(f->path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
      rc = fd >= 0 && WriteAll(fd, f->data, f->len) == 0 &&
                   fchmod(fd, (mode_t)(f->mode & 07777)) == 0
               ? 0
               : -1;
      if (fd >= 0) close(fd);
    }
    free(real);
  } else {
    if (is_link) unlink(f->path);
    rc = WriteExact(f->path, f->data, f->len, f->mode);
  }
  if (rc) return -1;
  StatFile(f);  // the restored file is the accepted one from now on
  return f->exists ? 0 : -1;
}

// Keeps the version on disk for the person; see trust.h.
int ManifestKeep(const char* path, const char* dest) {
  size_t len = 0;
  char* data = ReadFile(path, &len);
  if (!data) return errno == ENOENT ? 0 : -1;
  char* dir = DirName(dest);
  int rc = MakeDirs(dir);
  free(dir);
  if (!rc) rc = WriteFileAtomic(dest, data, len);
  free(data);
  return rc;
}
