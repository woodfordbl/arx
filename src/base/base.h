// base.h: the bottom layer, used by everything else.
//   util.c  growable buffers, checked allocation, files, paths, time, parsing
//   json.c  dotted-path lookups and YAML-style scalars on top of cJSON
//   proc.c  the process runner behind every tool, hook, curl call and
//           subagent (own process group, timeout, streamed output)
//   proc_posix.c  the rest of the platform natively: signals, exec, the
//           executable check, observers, sleeping, and HttpStart by curl
//   http.c  one HTTP request on top of the platform (HttpRun)
//   rpc.c   JSON-RPC 2.0 over JSON lines, with no I/O of its own
// The browser build swaps proc.c and proc_posix.c for proc_host.c.

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
  kExitPolicy = 5,
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

// A DataFn like BufferSink that keeps up to 64 MB, for LinePop.
void LineSink(void* ctx, const char* data, size_t n);

// Takes the first whole line out of `b` (malloc'd, no newline), or NULL.
char* LinePop(Buffer* b);

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

// Replaces `path` atomically (temp file + rename), keeping its mode. 0 or -1.
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

// Parses "30", "10s", "250ms", "5m" or "1h" into seconds. Returns 0 or -1.
int ParseDuration(const char* s, double* out);

// Parses "2048", "2kb" or "1mb" (any case) into bytes. Returns 0 or -1.
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
  int open_in;            // stdin stays open for ProcWrite (`in` is NULL)
  int keep_on_interrupt;  // Ctrl-C does not stop it (a long-lived helper)
  const char* dir;        // the child's working folder, or NULL for ours
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
// SIGKILL after a grace period). Returns 0, or -1 if it could not start.
int ProcRun(const Proc* p, ProcResult* r);

// A child started by ProcStart.
typedef struct ProcChild ProcChild;

// Starts `p` and returns at once; ProcPoll then runs it. `p.in` and the
// contexts it names must stay valid until ProcFinish. Returns NULL if the
// child could not be started (errno says why).
ProcChild* ProcStart(const Proc* p);

// Runs one round for `n` children and the kept ones: waits up to `max_wait`
// seconds (at most 0.1), feeds stdin, drains output, reaps, and stops each
// at its timeout or on Ctrl-C, as ProcRun does. Repeat until ProcDone.
void ProcPoll(ProcChild* const* kids, int n, double max_wait);

// True when the child has exited and its output has been read.
int ProcDone(const ProcChild* c);

// Queues `n` bytes for the stdin of a child started with `open_in`; ProcPoll
// writes them.
void ProcWrite(ProcChild* c, const char* data, size_t n);

// Closes the child's stdin once what ProcWrite queued is written, so it can
// finish and exit. Later ProcWrite calls are dropped.
void ProcClose(ProcChild* c);

// Fills `r` and frees the child, releasing a kept one. A child that still
// runs is stopped first (SIGTERM to its group, SIGKILL after a grace period).
void ProcFinish(ProcChild* c, ProcResult* r);

// Keeps a child for the session: every ProcPoll round serves it, whoever
// calls, so its pipes drain while arx waits for a model call or a hook. Its
// owner checks ProcDone and finishes it, and never also lists it.
void ProcKeep(ProcChild* c);

// Stops keeping a child (if kept); its owner polls it again.
void ProcRelease(ProcChild* c);

// Starts stopping a child without waiting: closes stdin, sends SIGTERM to
// its group, and ProcPoll sends SIGKILL after the grace period.
void ProcStop(ProcChild* c);

// Returns a copy of the environment with `extra` ("KEY=value", NULL-terminated)
// added or replaced. Free only the array; the strings are borrowed.
char** EnvWith(char* const* extra);

// ---- platform: proc_posix.c natively, proc_host.c in the browser ----

// Ctrl-C and SIGTERM set g_interrupted (a second Ctrl-C exits); no SIGPIPE.
void ProcInit(void);

// Replaces this process with `argv` (argv[0] from PATH); `null_stdin` gives
// it /dev/null and the default SIGPIPE. Returns -1 and errno on failure.
int ProcExec(char* const* argv, int null_stdin);

// True when `path` is a regular file this platform can run: natively, one
// we may execute; in the browser, one the runtime has a runner for.
int IsRunnable(const char* path);

// Starts `sh -c command` with `env` added, to read events on stdin. Returns
// the write end (non-blocking, close-on-exec) and sets *pid, or -1.
int ProcObserverStart(const char* command, char* const* env, int* pid);

// Waits up to `secs` for observer `pid` to exit.
void ProcObserverWait(int pid, double secs);

// Returns a close-on-exec copy of fd 1 (for `--events -`), or -1.
int ProcDupStdout(void);

// Sleeps for `s` seconds, returning early if g_interrupted is set.
void SleepSeconds(double s);

// ---- http.c, on top of the platform ----

// One HTTP request: natively curl (through any adapter), with the headers
// in a 0600 file it deletes after; in the browser, a fetch.
typedef struct HttpRequest {
  const char* method;  // NULL: POST with a body, else GET
  const char* url;
  const char* headers;  // "Name: value\n" lines
  const char* body;     // or NULL
  size_t body_len;
  double timeout;       // seconds for the whole call; 0 means none
  int stream;           // the body streams in as it arrives (curl -N)
  const char* adapter;  // endpoint.adapter program, or NULL
  const char* curl;     // native: endpoint.curl, or NULL ($ARX_CURL, curl)
  const char* tmp_dir;  // native: where the header files go
  DataFn on_body;       // body bytes as they arrive
  void* body_ctx;
} HttpRequest;

// How a request ended.
typedef struct HttpResult {
  int status;          // HTTP status of the last response, 0 if none
  double retry_after;  // Retry-After in seconds, or -1
  int net_error;       // 0, curl's exit code (6, 7, 28...), -1: no start
  int interrupted;     // stopped by Ctrl-C
  int spawn_failed;    // curl or the adapter did not start
  Buffer err;          // curl's stderr, or why it failed; free it
  double secs;
} HttpResult;

// Starts a request, which ProcPoll runs like a child; `req` and what it
// names stay valid until HttpFinish. Returns NULL (errno) if it can't start.
ProcChild* HttpStart(const HttpRequest* req);

// Ends a started request (stopping it if it runs), fills `r`, frees `c`.
void HttpFinish(ProcChild* c, HttpResult* r);

// HttpStart, ProcPoll until it is done, then HttpFinish. Returns 0, or -1
// when it could not start (r->spawn_failed, with the reason in r->err).
int HttpRun(const HttpRequest* req, HttpResult* r);

// ---- rpc.c ----

// One JSON-RPC 2.0 peer, in either role, speaking one message per line.
typedef struct RpcPeer RpcPeer;

// How a call of ours ended.
typedef enum RpcStatus { kRpcOk, kRpcError, kRpcTimeout, kRpcClosed } RpcStatus;

// What the owner gives a peer. Only `write` is required.
typedef struct RpcHandlers {
  void (*write)(void* ctx, const char* data, size_t n);  // one whole line
  // An incoming request; answer now or later with RpcReply or
  // RpcReplyError. NULL: every request gets -32601.
  void (*request)(void* ctx, RpcPeer* p, cJSON* id, const char* method,
                  cJSON* params);
  void (*notify)(void* ctx, const char* method, cJSON* params);    // or NULL
  void (*bad_line)(void* ctx, const char* line, const char* why);  // or NULL
  void* ctx;
} RpcHandlers;

// Called once per call: `value` is the result (kRpcOk), the error object
// (kRpcError) or RpcClose's reason as a string (kRpcClosed; NULL without
// one), borrowed; NULL for kRpcTimeout.
typedef void (*RpcDoneFn)(void* ctx, RpcStatus status, cJSON* value);

// Creates a peer. Lines longer than `max_line` (0: 64 MB) are skipped and
// reported to bad_line. With a `request` handler it also answers a line
// that is not JSON (-32700) and a message that is not valid (-32600).
RpcPeer* RpcNew(const RpcHandlers* h, size_t max_line);

// A DataFn: handles each line that ends in the bytes read so far.
void RpcFeed(void* peer, const char* data, size_t n);

// Sends a request; `params` is consumed (NULL: none). `done` runs once, when
// the response comes or at `timeout` seconds (0: no deadline). Returns its
// id, counting from 1 for each peer, or 0 once the peer is closed.
int64_t RpcCall(RpcPeer* p, const char* method, cJSON* params, double timeout,
                RpcDoneFn done, void* ctx);

// Sends a notification; `params` is consumed (NULL: none).
void RpcNotify(RpcPeer* p, const char* method, cJSON* params);

// Answers request `id` (borrowed; an owner that answers after the request
// handler returned keeps cJSON_Duplicate(id, 1)) with `result` (consumed).
void RpcReply(RpcPeer* p, cJSON* id, cJSON* result);

// Answers `id` (borrowed; NULL: null) with an error; `data` is consumed.
void RpcReplyError(RpcPeer* p, cJSON* id, int code, const char* message,
                   cJSON* data);

// Drops a call that waits; its done never runs, and its response is ignored.
void RpcForget(RpcPeer* p, int64_t id);

// Ends the calls whose deadline is past `now` (Now()) with kRpcTimeout.
// Returns the seconds to the next deadline, or -1 when none waits.
double RpcTick(RpcPeer* p, double now);

// Ends each waiting call with kRpcClosed and `why`; then nothing is sent.
void RpcClose(RpcPeer* p, const char* why);

// The number of calls that wait for a response.
int RpcPending(const RpcPeer* p);

// Frees the peer, or, inside one of its callbacks, when the callback ends.
void RpcFree(RpcPeer* p);

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
