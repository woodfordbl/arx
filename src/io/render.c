// render.c: draws events as short lines on stderr (colored on a terminal,
// plain otherwise, so it also reads well in docker logs and CI), and
// implements `arx watch`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/io/io.h"

static const char kDim[] = "\033[2m";
static const char kRed[] = "\033[31m";
static const char kGreen[] = "\033[32m";
static const char kYellow[] = "\033[33m";
static const char kBlue[] = "\033[34m";
static const char kMagenta[] = "\033[35m";
static const char kCyan[] = "\033[36m";
static const char kBold[] = "\033[1m";

// 1 when the cursor is not at the start of a line.
static int g_mid_line;

// Writes raw text and tracks whether the line is open.
static void Out(const char* s, size_t n) {
  fwrite(s, 1, n, stderr);
  if (n) g_mid_line = s[n - 1] != '\n';
}

// Indents subagent output with one bar per level.
static void Indent(int depth) {
  for (int i = 0; i < depth; i++) Out("│ ", strlen("│ "));
}

// Draws text, indenting each new line by depth.
void RenderText(int depth, const char* text) {
  while (*text) {
    if (!g_mid_line) Indent(depth);
    const char* nl = strchr(text, '\n');
    size_t n = nl ? (size_t)(nl - text + 1) : strlen(text);
    Out(text, n);
    text += n;
  }
}

// Draws one full line in `color`, starting on a fresh line.
static void Line(int depth, const char* color, const char* fmt, ...) {
  Buffer b = {0};
  if (g_mid_line) Out("\n", 1);
  Indent(depth);
  if (color && g_events.color) BufferAppendStr(&b, color);
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(&b, fmt, ap);
  va_end(ap);
  if (color && g_events.color) BufferAppendStr(&b, "\033[0m");
  BufferAppendStr(&b, "\n");
  Out(b.data, b.len);
  BufferFree(&b);
}

// Room for one short number such as "12.3k".
typedef struct Num {
  char text[16];
} Num;

// Formats 1234 as "1.2k".
static const char* Human(double n, Num* out) {
  if (n >= 1e6) {
    snprintf(out->text, sizeof(out->text), "%.1fM", n / 1e6);
  } else if (n >= 1e3) {
    snprintf(out->text, sizeof(out->text), "%.1fk", n / 1e3);
  } else {
    snprintf(out->text, sizeof(out->text), "%.0f", n);
  }
  return out->text;
}

// Draws the model and tool events.
static int RenderWork(cJSON* e, const char* type, int depth) {
  Num a, b;
  if (!strcmp(type, "model.message")) {
    double in = JsonNum(e, "tokens_in", 0), out = JsonNum(e, "tokens_out", 0);
    if (in || out) {
      Line(depth, kDim, "  · %s in · %s out · $%.4f", Human(in, &a),
           Human(out, &b), JsonNum(e, "cost", 0));
    }
  } else if (!strcmp(type, "model.retry")) {
    Line(depth, kYellow, "  ↻ retry %d in %.1fs: %s",
         (int)JsonNum(e, "attempt", 0), JsonNum(e, "wait_s", 0),
         JsonStr(e, "error", ""));
  } else if (!strcmp(type, "tool.start")) {
    Line(depth, kCyan, "  ⏵ %s %s", JsonStr(e, "name", ""),
         JsonStr(e, "preview", ""));
  } else if (!strcmp(type, "tool.end")) {
    Line(depth, cJSON_IsTrue(JsonGet(e, "error")) ? kRed : kDim,
         "    ↳ exit %d · %.1fs · %s B  %s", (int)JsonNum(e, "exit", 0),
         JsonNum(e, "secs", 0), Human(JsonNum(e, "bytes", 0), &a),
         JsonStr(e, "preview", ""));
  } else {
    return 0;
  }
  return 1;
}

// Draws the harness and session events.
static void RenderHarness(cJSON* e, const char* type, int depth) {
  Num a, b;
  if (!strcmp(type, "session.start")) {
    Line(depth, kDim, "● arx %s · %s · %s · session %s", ARX_VERSION,
         JsonStr(e, "name", "agent"), JsonStr(e, "model", "?"),
         JsonStr(e, "session", ""));
  } else if (!strcmp(type, "hook")) {
    const char* error = JsonStr(e, "error", NULL);
    const char* decision = JsonStr(e, "decision", NULL);
    if (error || decision) {
      Line(depth, error ? kRed : kMagenta, "  ⚑ hook %s: %s",
           JsonStr(e, "point", ""), error ? error : decision);
    }
  } else if (!strcmp(type, "harness.reload")) {
    if (cJSON_IsTrue(JsonGet(e, "ok"))) {
      Line(depth, kGreen, "  ↻ harness reloaded (%.1f ms)",
           JsonNum(e, "ms", 0));
    } else {
      Line(depth, kRed,
           "  ✗ harness edit rejected; still using the "
           "previous version:\n%s",
           JsonStr(e, "errors", ""));
    }
  } else if (!strcmp(type, "compact")) {
    Line(depth, kBlue, "  ⇣ compacted (%s): %s → %s tokens",
         JsonStr(e, "strategy", ""), Human(JsonNum(e, "tokens_before", 0), &a),
         Human(JsonNum(e, "tokens_after", 0), &b));
  } else if (!strcmp(type, "note")) {
    Line(depth, kYellow, "  ✎ %s", JsonStr(e, "text", ""));
  } else if (!strcmp(type, "error")) {
    Line(depth, kRed, "  ✗ %s", JsonStr(e, "error", ""));
  } else if (!strcmp(type, "session.end")) {
    Line(depth, kBold, "● %s · %d turns · %s tokens · $%.4f · %.1fs",
         JsonStr(e, "status", ""), (int)JsonNum(e, "turns", 0),
         Human(JsonNum(e, "tokens", 0), &a), JsonNum(e, "cost", 0),
         JsonNum(e, "secs", 0));
  }
}

// Draws one event; see io.h.
void RenderEvent(cJSON* event, int from_log) {
  const char* type = JsonStr(event, "type", "");
  int depth = (int)JsonNum(event, "depth", 0);
  if (!strcmp(type, "model.delta")) {
    if (from_log) RenderText(depth, JsonStr(event, "text", ""));
  } else if (!RenderWork(event, type, depth)) {
    RenderHarness(event, type, depth);
  }
  fflush(stderr);
}

// Handles one complete line in `arx watch`. Returns 1 once the top-level
// session has ended (a later session.start, from a resume, clears it).
static int WatchLine(const char* line, const char* id, int json, int ended) {
  if (json) {
    fputs(line, stdout);
    fflush(stdout);
  }
  cJSON* e = cJSON_Parse(line);
  if (!e) return ended;
  if (!json) RenderEvent(e, 1);
  if (JsonNum(e, "depth", 0) == 0 && !strcmp(JsonStr(e, "session", ""), id)) {
    const char* type = JsonStr(e, "type", "");
    if (!strcmp(type, "session.end")) ended = 1;
    if (!strcmp(type, "session.start")) ended = 0;
  }
  cJSON_Delete(e);
  return ended;
}

// Tails events.jsonl, stopping at end of file once the session has ended.
int WatchMain(const char* ref, int json, int from_start) {
  char* dir = SessionDir(ref ? ref : "last");
  if (!dir) {
    fprintf(stderr, "arx: no session %s\n", ref ? ref : "last");
    return kExitUsage;
  }
  char* path = XAsprintf("%s/events.jsonl", dir);
  const char* id = strrchr(dir, '/') ? strrchr(dir, '/') + 1 : dir;
  FILE* f = fopen(path, "r");
  if (!f) {
    fprintf(stderr, "arx: cannot open %s\n", path);
    free(path);
    free(dir);
    return kExitError;
  }
  if (!from_start) fseek(f, 0, SEEK_END);
  g_events.render = 1;
  g_events.color = isatty(2) && !getenv("NO_COLOR");
  char* chunk = NULL;
  size_t cap = 0;
  Buffer line = {0};
  int ended = 0;
  while (!g_interrupted) {
    ssize_t n = getline(&chunk, &cap, f);
    if (n <= 0) {
      if (ended) break;
      clearerr(f);
      SleepSeconds(0.1);
      continue;
    }
    BufferAppend(&line, chunk, (size_t)n);
    if (line.data[line.len - 1] != '\n') continue;  // the rest is coming
    ended = WatchLine(line.data, id, json, ended);
    line.len = 0;
  }
  free(chunk);
  BufferFree(&line);
  fclose(f);
  free(path);
  free(dir);
  return kExitDone;
}
