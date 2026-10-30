// util.c: buffers, checked allocation, strings, files, paths and time.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

volatile sig_atomic_t g_interrupted;
char* g_self;

// Prints "arx: <message>" and exits.
void Die(int code, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("arx: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(code);
}

// malloc that never returns NULL.
void* XMalloc(size_t n) {
  void* p = malloc(n ? n : 1);
  if (!p) Die(kExitError, "out of memory");
  return p;
}

// realloc that never returns NULL.
void* XRealloc(void* p, size_t n) {
  p = realloc(p, n ? n : 1);
  if (!p) Die(kExitError, "out of memory");
  return p;
}

// Copies n bytes into a new NUL-terminated string.
char* XStrndup(const char* s, size_t n) {
  char* d = XMalloc(n + 1);
  memcpy(d, s, n);
  d[n] = 0;
  return d;
}

// Copies a string.
char* XStrdup(const char* s) { return XStrndup(s, strlen(s)); }

// Grows the buffer so it can hold `extra` more bytes plus the NUL.
static void Reserve(Buffer* b, size_t extra) {
  if (b->len + extra + 1 <= b->cap) return;
  size_t cap = b->cap ? b->cap : 64;
  while (cap < b->len + extra + 1) cap *= 2;
  b->data = XRealloc(b->data, cap);
  b->cap = cap;
}

// Appends raw bytes.
void BufferAppend(Buffer* b, const void* s, size_t n) {
  Reserve(b, n);
  if (n) memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

// Appends a string.
void BufferAppendStr(Buffer* b, const char* s) {
  BufferAppend(b, s, strlen(s));
}

// Appends formatted text from a va_list.
void BufferVprintf(Buffer* b, const char* fmt, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n = vsnprintf(NULL, 0, fmt, copy);
  va_end(copy);
  if (n < 0) return;
  Reserve(b, (size_t)n);
  vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap);
  b->len += (size_t)n;
}

// Appends formatted text.
void BufferPrintf(Buffer* b, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(b, fmt, ap);
  va_end(ap);
}

// Hands the contents to the caller.
char* BufferTake(Buffer* b) {
  char* p = b->data ? b->data : XStrdup("");
  b->data = NULL;
  b->len = b->cap = 0;
  return p;
}

// Releases the contents.
void BufferFree(Buffer* b) {
  free(b->data);
  b->data = NULL;
  b->len = b->cap = 0;
}

// Collects process output into a Buffer; output past 1 MB is dropped.
void BufferSink(void* ctx, const char* data, size_t n) {
  Buffer* b = ctx;
  if (b->len < (1 << 20)) BufferAppend(b, data, n);
}

// Formats into a new string.
char* XAsprintf(const char* fmt, ...) {
  Buffer b = {0};
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(&b, fmt, ap);
  va_end(ap);
  return BufferTake(&b);
}

// Returns the length of the UTF-8 sequence at s[0..n), or 0 if it is invalid.
static size_t Utf8SequenceLength(const unsigned char* s, size_t n) {
  size_t len = s[0] >= 0xC2 && s[0] <= 0xDF   ? 2
               : s[0] >= 0xE0 && s[0] <= 0xEF ? 3
               : s[0] >= 0xF0 && s[0] <= 0xF4 ? 4
                                              : 0;
  if (!len || len > n) return 0;
  for (size_t k = 1; k < len; k++) {
    if ((s[k] & 0xC0) != 0x80) return 0;
  }
  return len;
}

// Makes text safe for JSON: valid UTF-8, no NULs.
char* Utf8Clean(const char* s, size_t n) {
  Buffer b = {0};
  BufferAppend(&b, NULL, 0);
  for (size_t i = 0; i < n;) {
    const unsigned char* u = (const unsigned char*)s + i;
    size_t len = u[0] < 0x80 ? 1 : Utf8SequenceLength(u, n - i);
    if (u[0] == 0) {
      BufferAppend(&b, "?", 1);
      len = 1;
    } else if (len) {
      BufferAppend(&b, s + i, len);
    } else {
      BufferAppend(&b, "\xEF\xBF\xBD", 3);
      len = 1;
    }
    i += len;
  }
  return BufferTake(&b);
}

// Cuts a string without splitting a UTF-8 character.
char* Truncate(const char* s, size_t max) {
  size_t n = strlen(s);
  if (n <= max) return XStrdup(s);
  while (max && ((unsigned char)s[max] & 0xC0) == 0x80) max--;
  return XAsprintf("%.*s…", (int)max, s);
}

// Reads a file into memory.
char* ReadFile(const char* path, size_t* len) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  Buffer b = {0};
  char chunk[65536];
  ssize_t n;
  BufferAppend(&b, NULL, 0);
  while ((n = read(fd, chunk, sizeof(chunk))) > 0) {
    BufferAppend(&b, chunk, (size_t)n);
  }
  close(fd);
  if (n < 0) {
    BufferFree(&b);
    return NULL;
  }
  if (len) *len = b.len;
  return BufferTake(&b);
}

// Writes everything, retrying short writes.
int WriteAll(int fd, const void* p, size_t n) {
  const char* c = p;
  while (n) {
    ssize_t w = write(fd, c, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    c += w;
    n -= (size_t)w;
  }
  return 0;
}

// Writes a temp file next to `path`, then renames it over `path`. The file
// mode is kept so an edited tool stays executable.
int WriteFileAtomic(const char* path, const char* data, size_t len) {
  struct stat st;
  mode_t mode = stat(path, &st) == 0 ? (st.st_mode & 07777) : 0644;
  char* tmp = XAsprintf("%s.tmp%d", path, (int)getpid());
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
  if (fd < 0) {
    free(tmp);
    return -1;
  }
  int ok = WriteAll(fd, data, len) == 0 && fchmod(fd, mode) == 0;
  close(fd);
  if (!ok || rename(tmp, path)) {
    unlink(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  return 0;
}

// Appends to a file.
int AppendFile(const char* path, const char* data, size_t len) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  if (fd < 0) return -1;
  int r = WriteAll(fd, data, len);
  close(fd);
  return r;
}

// mkdir -p.
int MakeDirs(const char* path) {
  char* p = XStrdup(path);
  for (char* c = p + 1; *c; c++) {
    if (*c != '/') continue;
    *c = 0;
    mkdir(p, 0755);
    *c = '/';
  }
  int r = mkdir(p, 0755) == 0 || errno == EEXIST ? 0 : -1;
  free(p);
  return r;
}

// Joins a directory and a relative path.
char* PathJoin(const char* a, const char* b) {
  if (!b) b = "";
  if (b[0] == '/' || !a || !*a || !strcmp(a, ".")) return XStrdup(b);
  return XAsprintf("%s/%s", a, b);
}

// Returns everything before the last '/'.
char* DirName(const char* path) {
  const char* slash = strrchr(path, '/');
  if (!slash) return XStrdup(".");
  if (slash == path) return XStrdup("/");
  return XStrndup(path, (size_t)(slash - path));
}

// Finds our own executable so subagents run the same binary.
char* SelfPath(const char* argv0) {
  char tmp[4096];
#ifdef __APPLE__
  uint32_t n = sizeof(tmp);
  if (_NSGetExecutablePath(tmp, &n) == 0) {
    char* real = realpath(tmp, NULL);
    if (real) return real;
  }
#else
  ssize_t n = readlink("/proc/self/exe", tmp, sizeof(tmp) - 1);
  if (n > 0) {
    tmp[n] = 0;
    return XStrdup(tmp);
  }
#endif
  char* real = realpath(argv0, NULL);
  return real ? real : XStrdup(argv0);
}

// stat() for hot reload: modification time and size.
int64_t MtimeNs(const char* path, int64_t* size) {
  struct stat st;
  if (stat(path, &st)) {
    if (size) *size = -1;
    return -1;
  }
  if (size) *size = (int64_t)st.st_size;
#ifdef __APPLE__
  return (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
  return (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
}

// Monotonic seconds.
double Now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

// ISO 8601 UTC time with milliseconds.
void IsoTime(char out[32]) {
  struct timespec t;
  struct tm tm;
  clock_gettime(CLOCK_REALTIME, &t);
  gmtime_r(&t.tv_sec, &tm);
  size_t n = strftime(out, 32, "%Y-%m-%dT%H:%M:%S", &tm);
  snprintf(out + n, 32 - n, ".%03dZ", (int)(t.tv_nsec / 1000000));
}

// Sleeps in 100 ms steps so Ctrl-C is noticed quickly.
void SleepSeconds(double s) {
  while (s > 0 && !g_interrupted) {
    double step = s > 0.1 ? 0.1 : s;
    struct timespec ts = {(time_t)step,
                          (int)((step - (double)(time_t)step) * 1e9)};
    nanosleep(&ts, NULL);
    s -= step;
  }
}

// Parses a duration with an optional ms/s/m/h suffix.
int ParseDuration(const char* s, double* out) {
  char* end;
  double v = strtod(s, &end);
  if (end == s || v < 0) return -1;
  while (*end == ' ') end++;
  if (!*end || !strcmp(end, "s")) {
    *out = v;
  } else if (!strcmp(end, "ms")) {
    *out = v / 1000;
  } else if (!strcmp(end, "m")) {
    *out = v * 60;
  } else if (!strcmp(end, "h")) {
    *out = v * 3600;
  } else {
    return -1;
  }
  return 0;
}

// Parses a size with an optional b/kb/mb/gb suffix (powers of 1024).
int ParseSize(const char* s, size_t* out) {
  char* end;
  double v = strtod(s, &end);
  if (end == s || v < 0) return -1;
  while (*end == ' ') end++;
  double unit;
  if (!*end || !strcasecmp(end, "b")) {
    unit = 1;
  } else if (!strcasecmp(end, "kb") || !strcasecmp(end, "k")) {
    unit = 1024;
  } else if (!strcasecmp(end, "mb") || !strcasecmp(end, "m")) {
    unit = 1024.0 * 1024;
  } else if (!strcasecmp(end, "gb") || !strcasecmp(end, "g")) {
    unit = 1024.0 * 1024 * 1024;
  } else {
    return -1;
  }
  *out = (size_t)(v * unit);
  return 0;
}
