// command.c: `arx mcp`, a built-in command, since it needs the C client.

#include <string.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/mcp/mcp.h"

// `arx mcp`; see mcp.h.
int McpCommand(int argc, char** argv, struct Agent* a) {
  (void)a;
  if (argc == 3 && !strcmp(argv[2], "http")) return McpHttpMain();
  return UsageError("usage: arx mcp http", argc > 2 ? argv[2] : NULL);
}
