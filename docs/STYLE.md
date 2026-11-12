# Style for the arx sources

These rules apply to the C code in `src/`. `make lint` checks them, and CI runs
it on every push and pull request. They are for building `arx` itself: they are
not part of the binary, and harness files that an agent writes at run time
(`tools/`, `hooks/`, prompts, specs) are not linted.

**Tool versions:**
- **clang-format:** `make lint` requires major version 23, because formatting
  can change between majors. Homebrew's `clang-format` is fine. CI pins
  `clang-format==23.1.3`, which formats identically to 23.1.4.
- **cpplint:** CI pins `cpplint==2.0.2`. Locally, `make lint` uses `cpplint`
  from PATH, or runs it through `uvx`.

## Rules

1. **Google style.** We follow the
   [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html)
   where it applies to C. `clang-format` (see `.clang-format`) does the layout:
   2-space indent, 80 columns, `char* p`. `cpplint` (see `CPPLINT.cfg`) checks the
   rest. Only two cpplint checks are off: C-style casts (C has no other kind)
   and the license header.
2. **Files are at most 400 lines.** Split a module before it grows past that.
3. **Every file starts with a `//` comment** that says what it is for.
4. **Every function has a `//` comment right above it.** In a header, the comment
   says what the function does, what it takes and what it returns. In a `.c`
   file, a static helper gets one line; explain anything that is not obvious.
5. **Comments explain why**, not what the next line does.

## Naming (Google C++ naming, applied to C)

| Kind | Style | Example |
|---|---|---|
| Types (`struct`, `typedef`, `enum`) | `UpperCamelCase` | `Spec`, `ToolSet`, `ExitCode` |
| Functions | `UpperCamelCase` | `SpecLoad()`, `ProcRun()` |
| Variables, parameters, struct fields | `snake_case` | `tool_seq`, `in_len` |
| Global variables | `g_` + `snake_case` | `g_interrupted`, `g_events` |
| Constants and enumerators | `k` + `UpperCamelCase` | `kHookPoints`, `kExitCap` |
| Macros | `UPPER_SNAKE_CASE` | `ARX_VERSION` |
| Files | `snake_case.c` / `.h` | `tool_exec.c` |

## Headers and includes

- `src/` has one folder per layer, and each folder has **one header** named
  after it: `base/base.h`, `io/io.h`, `model/model.h`, `harness/harness.h`,
  `agent/agent.h`. The header opens with a list of the folder's `.c` files
  and what each does, and groups its declarations under a `// ---- file.c`
  line per file. `main.c` sits at the top and has no header.
- A layer only includes headers from layers below it (base < io, model,
  harness < agent < main). The one exception: files that need the `Agent`
  struct include `agent.h` from their `.c` file, and headers refer to it as
  `struct Agent`.
- `src/mcp/` sits beside `harness/`: its header includes `harness.h`, and
  harness, agent and cli files include `mcp.h` from their `.c` files. It
  also uses `model.h`, for credential programs.
- Split a `.c` file when it nears 400 lines; the new file shares the
  folder's header.
- Header guards follow the path: `src/harness/harness.h` uses
  `SRC_HARNESS_HARNESS_H_`.
- Include paths start at the repo root: `#include "src/harness/harness.h"`,
  `#include "vendor/cjson/cJSON.h"`.
- Feature macros (`_GNU_SOURCE`, `_DARWIN_C_SOURCE`) come from the Makefile, not
  from the sources.
- `vendor/` holds third-party code, unmodified and never linted.

## Integers

Use `int` for small counts and `int64_t` / `size_t` for sizes and token counts,
not `long` (cpplint `runtime/int`).
