// mcp.h: the MCP client. arx runs the MCP servers the spec names and gives
// the model their tools. It sits beside the harness layer, outside the turn
// loop: harness and agent files include this header from their `.c` files.
//   spec.c     the `mcp_servers` key: its rules, a plugin's servers, hosts
//   catalog.c  the servers of the spec, their cached tool lists, tool names
//   toolset.c  the selection, and the MCP tools of the tool set
//   search.c   mcp_search's ranking (BM25F) and what mcp_select does

#ifndef SRC_MCP_MCP_H_
#define SRC_MCP_MCP_H_

#include <stdint.h>

#include "vendor/cjson/cJSON.h"

#include "src/base/base.h"
#include "src/harness/harness.h"

// Defined in agent.h.
struct Agent;

// ---- spec.c ----

// Checks `mcp_servers` beyond its field table: names, exactly one of
// `command` and `url`, `type`, and what each key needs. With `plugin` set
// the map is a plugin.yaml's, whose `credential` may name a program of the
// spec, so that key is checked after the merge. Appends problems to `err`.
void McpValidate(const Spec* spec, int plugin, Buffer* err);

// Adopt's part for a plugin's servers (`servers` may be NULL): a `command`
// with a slash and `cwd` become absolute in the plugin folder `dir`, and
// each server's `env` gains ARX_PLUGIN_DIR.
void McpAdopt(cJSON* servers, const char* dir);

// True when the entry is a server arx may start: an object with a
// `command` or a `url`, not `enabled: false`.
int McpEnabled(const cJSON* entry);

// Adds the host of each enabled server's `url` to the string array `hosts`,
// each once.
void McpHosts(const Spec* spec, cJSON* hosts);

// Appends " name (stdio, 41 tools cached) name (http, not listed)" for the
// enabled servers, for `arx check`, and to `warnings` a line for each
// `http:` URL that is not loopback.
void McpCheck(const Spec* spec, Buffer* line, Buffer* warnings);

// Expands ${NAME} and ${NAME:-default} in `text` from the environment.
// Returns a malloc'd string, or NULL with the unset variable's name in
// `err`.
char* McpExpand(const char* text, Buffer* err);

// ---- catalog.c ----

// The most tools mcp_select keeps selected at once.
#define MCP_MAX_SELECTED 32

// One tool of a server.
typedef struct McpTool {
  char* name;  // as the model sees it: <server>__<tool>
  cJSON* def;  // as the server listed it; belongs to the server's cache
} McpTool;

// Where a server is in its life (servers.c).
typedef enum McpState {
  kMcpIdle,
  kMcpStarting,
  kMcpReady,
  kMcpFailed
} McpState;

// One enabled server of the spec, with its cached tool list.
typedef struct McpServer {
  char* name;
  cJSON* entry;    // its mcp_servers entry (a copy)
  uint64_t hash;   // McpHash(entry): a changed entry is a new server
  cJSON* cache;    // .arx/mcp/<name>.json when it is for this entry, or NULL
  McpTool* tools;  // the cache's tools, less include, exclude and disabled
  int tool_count;
  int fresh;    // the list is from this process, or younger than its ttl
  char* error;  // why it failed, or NULL (servers.c)
} McpServer;

// The servers of the current spec, in its order.
int McpServerCount(void);

// Server `i`, or NULL.
McpServer* McpServerAt(int i);

// The server called `name`, or NULL.
McpServer* McpServerFind(const char* name);

// A fingerprint of a server entry.
uint64_t McpHash(const cJSON* entry);

// The number of tools in the cache file of server `name` when the file is
// for `entry`, or -1.
int McpCachedCount(const char* name, const cJSON* entry);

// True when `name` is `<server>__<tool>` for a server in `root`'s
// mcp_servers, so a `tools.<name>` entry needs no file.
int McpOwns(cJSON* root, const char* name);

// Makes the servers match a->spec after a load or reload: a new entry is a
// new server, a changed one drops its cache, a removed one goes. Then reads
// the selection and calls McpTools.
void McpSync(struct Agent* a);

// Replaces the MCP tools at the end of a->tools: mcp_search and mcp_select
// when a server is enabled, then the preloaded and the selected tools, in
// that order. A tool of the same name from a layer wins.
void McpTools(struct Agent* a);

// Keeps a tool list for `s` (`tools` is consumed) with its era ("modern" or
// "legacy"), protocol version, instructions and ttl in ms (0: none), and
// writes .arx/mcp/<name>.json.
void McpCacheStore(McpServer* s, cJSON* tools, const char* era,
                   const char* version, const char* instructions, double ttl);

// The catalog tool the model calls `name` and its server, or NULL.
McpTool* McpFindTool(const char* name, McpServer** server);

// The server whose name starts the model's name `name` (<server>__<tool>),
// or NULL.
McpServer* McpOwnerOf(const char* name);

// ---- toolset.c ----

// The selection: an array of tool names, in selection order.
cJSON* McpSelection(void);

// Replaces the selection with `names` (consumed) and writes
// $ARX_SESSION_DIR/mcp/selected.json.
void McpSelectionSet(struct Agent* a, cJSON* names);

// Reads selected.json again when its modification time changed. Returns 1
// when the selection changed.
int McpSelectionLoad(struct Agent* a);

// ToolFind's fallback: when `name` is a catalog tool that is not selected,
// or `<server>__<tool>` for a server whose tools are not listed yet, selects
// it and returns its tool in a->tools. Returns NULL for any other name.
Tool* McpToolFor(struct Agent* a, const char* name);

// One line about a server for mcp_search: its `description`, else the
// first sentence of its instructions, else "" (malloc'd).
char* McpServerAbout(const McpServer* s);

// ---- search.c ----

// Appends what mcp_search prints for `query`: the best `limit` tools (0:
// 8, at most 25) of every server, or of `server` when it is not NULL or
// empty, one per line. An empty query lists the servers.
void McpSearchText(const struct Agent* a, const char* query, const char* server,
                   int limit, Buffer* out);

// What mcp_select does: selects `names` and drops `drop` (arrays of the
// model's names, or NULL). Returns what it did (malloc'd) and sets
// `*is_error` for an unknown name, with the 3 closest names, and for a
// selection over MCP_MAX_SELECTED, which changes nothing.
char* McpSelectApply(struct Agent* a, cJSON* names, cJSON* drop, int* is_error);

#endif  // SRC_MCP_MCP_H_
