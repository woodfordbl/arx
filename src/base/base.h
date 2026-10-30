// base.h: the bottom layer, used by everything else.
//   util.c  growable buffers, checked allocation, files, paths, time, parsing
//   json.c  dotted-path lookups and YAML-style scalars on top of cJSON
//   proc.c  the process runner behind every tool, hook, curl call and
//           subagent (own process group, timeout, streamed output)

#ifndef SRC_BASE_BASE_H_
#define SRC_BASE_BASE_H_

#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "vendor/cjson/cJSON.h"

// ---- util.c ----

// The harness version, printed by `arx version` and in session.start events.
// The build sets it from the git tag (see the Makefile); "dev" otherwise.
#ifndef ARX_VERSION
#define ARX_VERSION "dev"
#endif

// Process exit codes. They are also the "status" of a session.
typedef enum ExitCode {
  kExitDone = 0,
  kExitError = 1,
  kExitUsage = 2,
  kExitCap = 3,
  kExitAuth = 4,
  kExitInterrupted = 130,
} ExitCode;

// A growable byte buffer that always keeps a trailing NUL after `len` bytes.
// A zeroed Buffer is empty and ready to use.
typedef struct Buffer {
  char* data;
  size_t len;
  size_t cap;
} Buffer;

// Appends `n` bytes from `s` (which may be NULL when `n` is 0).
void BufferAppend(Buffer* b, const void* s, size_t n);

// Appends a NUL-terminated string.
void BufferAppendStr(Buffer* b, const char* s);

// Appends printf-style formatted text.
void BufferPrintf(Buffer* b, const char* fmt, ...);

// Appends formatted text from a va_list.
void BufferVprintf(Buffer* b, const char* fmt, va_list ap);

// Returns the contents as a malloc'd string (never NULL) and empties `b`.
char* BufferTake(Buffer* b);

// Frees the contents and empties `b`.
void BufferFree(Buffer* b);

// A DataFn (see Proc below) that appends to the Buffer in `ctx`, up to 1 MB.
void BufferSink(void* ctx, const char* data, size_t n);

// Set by the SIGINT/SIGTERM handler; long waits check it and return early.
extern volatile sig_atomic_t g_interrupted;

// Absolute path of the running arx binary, used to start subagents.
extern char* g_self;

// Prints "arx: <message>" to stderr and exits with `code`.
void Die(int code, const char* fmt, ...);

// malloc that exits on out-of-memory.
void* XMalloc(size_t n);

// realloc that exits on out-of-memory.
void* XRealloc(void* p, size_t n);

// Returns a malloc'd copy of `s`.
char* XStrdup(const char* s);

// Returns a malloc'd copy of the first `n` bytes of `s`.
char* XStrndup(const char* s, size_t n);

// Returns a malloc'd, printf-style formatted string.
char* XAsprintf(const char* fmt, ...);

// Returns a copy of `n` bytes that is valid UTF-8 with no NULs: bad bytes
// become U+FFFD and NULs become '?'. Tool output is cleaned this way before
// it goes into JSON.
char* Utf8Clean(const char* s, size_t n);

// Returns a copy of `s` cut to at most `max` bytes (at a character boundary),
// with "…" appended when it was cut.
char* Truncate(const char* s, size_t max);

// Reads a whole file. Returns a malloc'd, NUL-terminated string, or NULL on
// error. Stores the length in `*len` when `len` is not NULL.
char* ReadFile(const char* path, size_t* len);

// Writes all `n` bytes to `fd`, retrying on EINTR. Returns 0 or -1.
int WriteAll(int fd, const void* p, size_t n);

// Replaces `path` atomically (temp file + rename), keeping its file mode.
// Returns 0 or -1.
int WriteFileAtomic(const char* path, const char* data, size_t len);

// Appends to `path`, creating it if needed. Returns 0 or -1.
int AppendFile(const char* path, const char* data, size_t len);

// Creates `path` and any missing parent directories. Returns 0 or -1.
int MakeDirs(const char* path);

// Returns `b` resolved against directory `a` (b itself if it is absolute).
char* PathJoin(const char* a, const char* b);

// Returns the directory part of `path` ("." when there is none).
char* DirName(const char* path);

// Returns the absolute path of the running executable.
char* SelfPath(const char* argv0);

// Returns arx's config directory (malloc'd): $ARX_CONFIG_DIR, else
// $XDG_CONFIG_HOME/arx, else ~/.config/arx. It holds config.yaml (the user's
// defaults) and, outside macOS, the 0600 credentials file.
char* ConfigDir(void);

// Returns a file's modification time in nanoseconds, or -1 if it is missing.
// Stores its size in `*size` (-1 if missing) when `size` is not NULL.
int64_t MtimeNs(const char* path, int64_t* size);

// Returns monotonic time in seconds.
double Now(void);

// Writes the current UTC time as "2026-10-30T22:14:03.120Z" into `out`.
void IsoTime(char out[32]);

// Sleeps for `s` seconds, returning early if g_interrupted is set.
void SleepSeconds(double s);

// Parses "30", "10s", "250ms", "5m" or "1h" into seconds. Returns 0 or -1.
int ParseDuration(const char* s, double* out);

// Parses "2048", "2kb" or "1mb" (case-insensitive) into bytes.
// Returns 0 or -1.
int ParseSize(const char* s, size_t* out);

// ---- proc.c ----

// Receives a chunk of a child's output.
typedef void (*DataFn)(void* ctx, const char* data, size_t n);

// What to run and where its input and output go.
typedef struct Proc {
  char* const* argv;  // argv[0] is looked up in PATH
  const char* in;     // stdin data; NULL means /dev/null
  size_t in_len;
  double timeout;    // seconds; 0 means no limit
  char* const* env;  // extra "KEY=value" entries, NULL-terminated, or NULL
  DataFn on_out;     // stdout, and stderr too unless on_err is set
  void* out_ctx;
  DataFn on_err;  // stderr, kept apart from stdout
  void* err_ctx;
  DataFn on_fd3;  // the child's fd 3 (subagent events)
  void* fd3_ctx;
} Proc;

// How the child finished.
typedef struct ProcResult {
  int code;          // exit code, or 128 + signal number
  int timed_out;     // killed because it ran past the timeout
  int interrupted;   // killed because g_interrupted was set
  int spawn_failed;  // could not start; errno says why
  double secs;
} ProcResult;

// Runs `p` and waits for it. The child gets its own process group, so a
// timeout or Ctrl-C kills it and everything it started (SIGTERM, then
// SIGKILL after a grace period). Returns 0, or -1 if the child could not be
// started.
int ProcRun(const Proc* p, ProcResult* r);

// Returns a copy of the environment with `extra` ("KEY=value", NULL-terminated)
// added or replaced. Free only the array; the strings are borrowed.
char** EnvWith(char* const* extra);

// ---- json.c ----

// Returns the node at a dotted path such as "tools.bash.timeout", or NULL.
cJSON* JsonGet(cJSON* o, const char* dotted);

// Returns the string at `dotted`, or `def` if it is missing or not a string.
const char* JsonStr(cJSON* o, const char* dotted, const char* def);

// Returns the number at `dotted`, or `def`.
double JsonNum(cJSON* o, const char* dotted, double def);

// Returns the boolean at `dotted` (1 or 0), or `def`.
int JsonBool(cJSON* o, const char* dotted, int def);

// Returns the duration at `dotted` in seconds ("10s", "5m" or a number),
// or `def`.
double JsonDuration(cJSON* o, const char* dotted, double def);

// Returns the size at `dotted` in bytes ("2kb" or a number), or `def`.
size_t JsonSize(cJSON* o, const char* dotted, size_t def);

// Sets `dotted` to `value` (taking ownership), creating objects on the way.
void JsonSet(cJSON* o, const char* dotted, cJSON* value);

// Parses a YAML scalar. Plain (unquoted) "true", "false", "null", "~", ""
// and numbers become those JSON types; anything else becomes a string.
cJSON* JsonScalar(const char* text, int plain);

// Adds `s` to `o` under `key`, cut to `max` bytes.
void JsonAddTruncated(cJSON* o, const char* key, const char* s, size_t max);

#endif  // SRC_BASE_BASE_H_
