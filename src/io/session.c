// session.c: creates, resumes and records sessions under .arx/sessions/.

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/io/io.h"

// Where sessions live, relative to the working directory.
static const char kRoot[] = ".arx/sessions";

// Opens a file for appending, close-on-exec so tools never inherit it.
static FILE* OpenAppend(const char* path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  return fd < 0 ? NULL : fdopen(fd, "a");
}

// Points .arx/sessions/last at `id`, atomically.
static void LinkLast(const char* id) {
  char* tmp = XAsprintf("%s/.last%d", kRoot, (int)getpid());
  char* last = XAsprintf("%s/last", kRoot);
  unlink(tmp);
  if (symlink(id, tmp) == 0) rename(tmp, last);
  free(tmp);
  free(last);
}

// Ids sort by time: 20261030-221403-a1b2.
int SessionNew(Session* s, int depth) {
  char stamp[32];
  time_t t = time(NULL);
  struct tm tm;
  memset(s, 0, sizeof(*s));
  localtime_r(&t, &tm);
  strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &tm);
  // Microseconds overflow 32 bits; truncate through 64 bits, which is
  // defined (a direct double -> uint32_t conversion is not).
  uint64_t micros = (uint64_t)(Now() * 1e6);
  uint32_t r = (uint32_t)getpid() * 2654435761u ^ (uint32_t)micros;
  s->id = XAsprintf("%s-%04x", stamp, (unsigned)(r & 0xffff));
  char* dir = XAsprintf("%s/%s", kRoot, s->id);
  if (MakeDirs(dir)) {
    free(dir);
    return -1;
  }
  s->dir = realpath(dir, NULL);  // absolute: tools may cd elsewhere
  free(dir);
  if (!s->dir) return -1;
  char* path = XAsprintf("%s/transcript.jsonl", s->dir);
  s->transcript = OpenAppend(path);
  free(path);
  if (depth == 0) LinkLast(s->id);
  return s->transcript ? 0 : -1;
}

// Resolves an id, "last" or a directory.
char* SessionDir(const char* ref) {
  struct stat st;
  char* dir = strchr(ref, '/') ? XStrdup(ref) : XAsprintf("%s/%s", kRoot, ref);
  char* real = NULL;
  if (stat(dir, &st) == 0 && S_ISDIR(st.st_mode)) real = realpath(dir, NULL);
  free(dir);
  return real;
}

// Replays transcript lines; a {"_reset":true} line starts the history over.
static cJSON* LoadTranscript(const char* path) {
  cJSON* messages = cJSON_CreateArray();
  FILE* f = fopen(path, "r");
  char* line = NULL;
  size_t cap = 0;
  while (f && getline(&line, &cap, f) > 0) {
    cJSON* m = cJSON_Parse(line);
    if (!m) continue;
    if (cJSON_IsTrue(cJSON_GetObjectItem(m, "_reset"))) {
      cJSON_Delete(m);
      cJSON_Delete(messages);
      messages = cJSON_CreateArray();
    } else {
      cJSON_AddItemToArray(messages, m);
    }
  }
  free(line);
  if (f) fclose(f);
  return messages;
}

// Restores the counters from meta.json.
static void LoadMeta(Session* s) {
  char* path = XAsprintf("%s/meta.json", s->dir);
  char* text = ReadFile(path, NULL);
  cJSON* meta = text ? cJSON_Parse(text) : NULL;
  s->turns = (int)JsonNum(meta, "turns", 0);
  s->tool_seq = (int)JsonNum(meta, "tool_seq", 0);
  s->call_seq = (int)JsonNum(meta, "call_seq", 0);
  s->calls = cJSON_DetachItemFromObject(meta, "calls");
  s->tokens_in = (int64_t)JsonNum(meta, "tokens_in", 0);
  s->tokens_out = (int64_t)JsonNum(meta, "tokens_out", 0);
  s->cost = JsonNum(meta, "cost", 0);
  cJSON_Delete(meta);
  free(text);
  free(path);
}

// Reopens a session where it left off.
int SessionResume(Session* s, const char* ref, cJSON** messages) {
  memset(s, 0, sizeof(*s));
  s->dir = SessionDir(ref);
  if (!s->dir) return -1;
  s->id = XStrdup(strrchr(s->dir, '/') + 1);
  char* path = XAsprintf("%s/transcript.jsonl", s->dir);
  *messages = LoadTranscript(path);
  s->transcript = OpenAppend(path);
  free(path);
  LoadMeta(s);
  // Commands sent while the session was stopped are stale: skip them.
  struct stat st;
  path = XAsprintf("%s/inbox", s->dir);
  s->inbox_offset = stat(path, &st) == 0 ? (int64_t)st.st_size : 0;
  free(path);
  return s->transcript ? 0 : -1;
}

// One message per line, flushed so a crash loses at most the current turn.
void SessionAppend(Session* s, cJSON* message) {
  if (!s->transcript) return;
  char* text = cJSON_PrintUnformatted(message);
  fputs(text, s->transcript);
  fputc('\n', s->transcript);
  fflush(s->transcript);
  free(text);
}

// A reset marker, then the whole new history.
void SessionReset(Session* s, cJSON* messages) {
  if (!s->transcript) return;
  fputs("{\"_reset\":true}\n", s->transcript);
  for (cJSON* m = messages->child; m; m = m->next) SessionAppend(s, m);
}

// Writes meta.json atomically.
void SessionWriteMeta(Session* s, const char* status) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "id", s->id);
  cJSON_AddStringToObject(m, "status", status);
  cJSON_AddNumberToObject(m, "turns", s->turns);
  cJSON_AddNumberToObject(m, "tool_seq", s->tool_seq);
  cJSON_AddNumberToObject(m, "call_seq", s->call_seq);
  cJSON_AddItemToObject(
      m, "calls",
      s->calls ? cJSON_Duplicate(s->calls, 1) : cJSON_CreateArray());
  cJSON_AddNumberToObject(m, "tokens_in", (double)s->tokens_in);
  cJSON_AddNumberToObject(m, "tokens_out", (double)s->tokens_out);
  cJSON_AddNumberToObject(m, "cost", s->cost);
  char* text = cJSON_Print(m);
  char* path = XAsprintf("%s/meta.json", s->dir);
  WriteFileAtomic(path, text, strlen(text));
  free(text);
  free(path);
  cJSON_Delete(m);
}

// Reads complete new lines from the inbox; a partial line waits for later.
cJSON* SessionReadInbox(Session* s) {
  char* path = XAsprintf("%s/inbox", s->dir);
  cJSON* commands = cJSON_CreateArray();
  // Nothing new is the common case, and a wait asks ten times a second.
  struct stat st;
  size_t n;
  char* text = stat(path, &st) == 0 && (int64_t)st.st_size > s->inbox_offset
                   ? ReadFile(path, &n)
                   : NULL;
  free(path);
  if (!text) return commands;
  size_t off = (size_t)s->inbox_offset;
  while (off < n) {
    char* nl = memchr(text + off, '\n', n - off);
    if (!nl) break;
    *nl = 0;
    cJSON* c = cJSON_Parse(text + off);
    if (c) cJSON_AddItemToArray(commands, c);
    off = (size_t)(nl - text) + 1;
  }
  s->inbox_offset = (int64_t)off;
  free(text);
  return commands;
}

// One line per command or result; O_APPEND keeps concurrent writers whole.
int SessionInboxAppend(Session* s, const cJSON* line) {
  char* json = cJSON_PrintUnformatted(line);
  char* text = XAsprintf("%s\n", json);
  char* path = XAsprintf("%s/inbox", s->dir);
  int failed = AppendFile(path, text, strlen(text));
  free(path);
  free(text);
  free(json);
  return failed ? -1 : 0;
}

// Scans every line, since a resume skips the ones written before it.
cJSON* SessionInboxFind(Session* s, const char* call) {
  char* path = XAsprintf("%s/inbox", s->dir);
  char* text = ReadFile(path, NULL);
  free(path);
  cJSON* found = NULL;
  for (char* line = text; line && *line;) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    cJSON* c = cJSON_Parse(line);
    if (!strcmp(JsonStr(c, "cmd", ""), "result") &&
        !strcmp(JsonStr(c, "call", ""), call)) {
      cJSON_Delete(found);
      found = c;
    } else {
      cJSON_Delete(c);
    }
    line = nl ? nl + 1 : NULL;
  }
  free(text);
  return found;
}

// tool-0001.out, tool-0002.out, ...
char* SessionOutputPath(Session* s) {
  return XAsprintf("%s/tool-%04d.out", s->dir, ++s->tool_seq);
}

// Closes the transcript and frees the strings.
void SessionClose(Session* s) {
  if (s->transcript) fclose(s->transcript);
  cJSON_Delete(s->calls);
  free(s->id);
  free(s->dir);
  memset(s, 0, sizeof(*s));
}
