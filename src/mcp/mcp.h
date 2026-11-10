// mcp.h: the MCP client. arx runs the MCP servers the spec names and gives
// the model their tools. It sits beside the harness layer, outside the turn
// loop: harness and agent files include this header from their `.c` files.
//   spec.c     the `mcp_servers` key: its rules, a plugin's servers, hosts

#ifndef SRC_MCP_MCP_H_
#define SRC_MCP_MCP_H_

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

// Appends " name (stdio) name (http)" for the enabled servers, for `arx
// check`, and to `warnings` a line for each `http:` URL that is not loopback.
void McpCheck(const Spec* spec, Buffer* line, Buffer* warnings);

// Expands ${NAME} and ${NAME:-default} in `text` from the environment.
// Returns a malloc'd string, or NULL with the unset variable's name in
// `err`.
char* McpExpand(const char* text, Buffer* err);

#endif  // SRC_MCP_MCP_H_
