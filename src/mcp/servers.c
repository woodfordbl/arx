// servers.c: the life of an MCP server's process. Nothing starts until the
// agent needs a server. A server lives as long as the arx process, restarts
// after a crash, fails for good after three exits in 5 minutes, and stops
// when arx stops. probe.c speaks to it once it runs.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"
#include "src/mcp/mcp.h"

// How long servers get to exit after their stdin closes.
static const double kCloseSeconds = 2;
// Three exits in this many seconds make a server fail.
static const double kCrashWindow = 300;

static struct Agent* g_agent;  // the agent the servers run for

// Sends an mcp.server event; see mcp.h.
void McpAnnounce(const McpServer* s, const char* state, const char* error,
                 int code) {
  cJSON* e = EventNew("mcp.server");
  cJSON_AddStringToObject(e, "server", s->name);
  cJSON_AddStringToObject(e, "state", state);
  if (s->version) {
    cJSON_AddStringToObject(e, "era", s->modern ? "modern" : "legacy");
    cJSON_AddStringToObject(e, "version", s->version);
  }
  if (!strcmp(state, "ready")) {
    cJSON_AddNumberToObject(e, "tools", s->tool_count);
    cJSON_AddNumberToObject(e, "secs", Now() - s->started);
  }
  if (code >= 0) cJSON_AddNumberToObject(e, "code", code);
  if (error) JsonAddTruncated(e, "error", error, 500);
  EventSend(e);
}

// Ends the server's process and its peer; calls in flight end with `why`.
static void Close(McpServer* s, const char* why) {
  if (s->peer) {
    RpcPeer* peer = s->peer;
    s->peer = NULL;
    RpcClose(peer, why);
    RpcFree(peer);
  }
  if (s->child) {
    ProcResult r;
    ProcChild* child = s->child;
    s->child = NULL;
    ProcFinish(child, &r);
  }
  cJSON_Delete(s->listing);
  cJSON_Delete(s->info);
  s->listing = s->info = NULL;
  s->out.len = 0;
  if (s->state != kMcpFailed) s->state = kMcpIdle;
}

// Makes the server failed, with a note for the agent; see mcp.h.
void McpServerFail(McpServer* s, const char* why) {
  if (s->state == kMcpFailed) return;
  s->state = kMcpFailed;
  free(s->error);
  s->error = XStrdup(why);
  McpLog(s, "failed: %s", why);
  McpAnnounce(s, "failed", why, -1);
  if (g_agent) {
    AgentNote(g_agent,
              "The MCP server %s failed: %s. Its tools fail until its entry "
              "in mcp_servers changes.%s%s",
              s->name, why, s->log ? " Its log: " : "", s->log ? s->log : "");
  }
  Close(s, why);
}

// Starts the server's process and the era probe.
static void Start(struct Agent* a, McpServer* s) {
  Buffer err = {0};
  s->started = Now();
  s->ready_by = s->started + JsonDuration(s->entry, "startup_timeout", 60);
  s->child = McpLaunch(a, s, &err);
  if (!s->child) {
    McpServerFail(s, err.data ? err.data : "it did not start");
    BufferFree(&err);
    return;
  }
  BufferFree(&err);
  ProcKeep(s->child);
  s->state = kMcpStarting;
  McpAnnounce(s, "start", NULL, -1);
  McpProbe(s);
}

// Starts a server the agent needs; see mcp.h.
void McpServerNeed(struct Agent* a, McpServer* s) {
  g_agent = a;
  if (s->state == kMcpReady && s->expires > 0 && !s->calls &&
      (double)time(NULL) >= s->expires) {
    McpLog(s, "its credential expired: restarting");
    Close(s, "restarting");
  }
  if (s->state == kMcpIdle && Now() >= s->restart_at) Start(a, s);
}

// The last `count` lines of the server's log (malloc'd).
static char* LogTail(const McpServer* s, int count) {
  size_t len = 0;
  char* text = s->log ? ReadFile(s->log, &len) : NULL;
  if (!text) return XStrdup("");
  size_t at = len;
  while (at && text[at - 1] == '\n') at--;
  text[at] = 0;
  size_t end = at;
  for (; at && count; at--) count -= text[at - 1] == '\n';
  if (!count) at++;                      // past the newline before the tail
  if (end - at > 2000) at = end - 2000;  // one long line: its end
  char* tail = XStrdup(text + at);
  free(text);
  return tail;
}

// Handles the exit of a server's process.
static void Exited(McpServer* s) {
  ProcResult r;
  ProcChild* child = s->child;
  s->child = NULL;
  ProcFinish(child, &r);
  char* tail = LogTail(s, 5);
  char* why = XAsprintf(
      "the MCP server %s exited with code %d\n%s%s[its log: "
      "%s]",
      s->name, r.code, tail, *tail ? "\n" : "", s->log ? s->log : "none");
  McpAnnounce(s, "exit", NULL, r.code);
  memmove(s->exits, s->exits + 1, 2 * sizeof(s->exits[0]));
  s->exits[2] = Now();
  int recent = 0;
  for (int i = 0; i < 3; i++) {
    recent += s->exits[i] > 0 && s->exits[2] - s->exits[i] < kCrashWindow;
  }
  Close(s, why);  // the calls in flight end with the exit, not a later reason
  if (recent >= 3) {
    char* text =
        XAsprintf("it exited 3 times in 5 minutes (last code %d)", r.code);
    McpServerFail(s, text);
    free(text);
  } else {
    s->restart_at = Now() + (recent == 1 ? 0 : recent == 2 ? 2 : 8);
  }
  free(why);
  free(tail);
}

// One round for every server; see mcp.h.
void McpServersPump(struct Agent* a) {
  g_agent = a;
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    if (s->peer && s->out.len) {
      Buffer lines = s->out;  // a callback may stop the server
      memset(&s->out, 0, sizeof(s->out));
      RpcFeed(s->peer, lines.data, lines.len);
      BufferFree(&lines);
    }
    if (s->peer) RpcTick(s->peer, Now());
    if (s->state == kMcpStarting && Now() > s->ready_by) {
      McpServerFail(s, "it did not list its tools within startup_timeout");
    }
    if (s->child && ProcDone(s->child)) Exited(s);
  }
}

// Runs a server until it is ready or failed; see mcp.h.
int McpServerWait(struct Agent* a, McpServer* s) {
  while (s->state != kMcpReady && s->state != kMcpFailed && !g_interrupted) {
    McpServerNeed(a, s);
    ProcPoll(NULL, 0, 0.05);
    McpServersPump(a);
  }
  return s->state == kMcpReady;
}

// Stops one server for good; see mcp.h.
void McpServerDrop(McpServer* s) {
  if (s->child) {
    ProcClose(s->child);
    for (double end = Now() + kCloseSeconds;
         !ProcDone(s->child) && Now() < end;) {
      ProcPoll(NULL, 0, 0.05);
    }
    McpAnnounce(s, "stop", NULL, -1);
  }
  Close(s, "the server stopped");
  BufferFree(&s->out);
  free(s->log);
  free(s->version);
  free(s->error);
  s->log = s->version = s->error = NULL;
  s->state = kMcpIdle;
}

// Stops every server; see mcp.h.
void McpShutdown(void) {
  int running = 0;
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    if (s->child) ProcClose(s->child);
    running += s->child != NULL;
  }
  for (double end = Now() + kCloseSeconds; running && Now() < end;) {
    ProcPoll(NULL, 0, 0.05);
    running = 0;
    for (int i = 0; i < McpServerCount(); i++) {
      McpServer* s = McpServerAt(i);
      running += s->child && !ProcDone(s->child);
    }
  }
  for (int i = 0; i < McpServerCount(); i++) McpServerDrop(McpServerAt(i));
}
