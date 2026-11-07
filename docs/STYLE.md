# Style for the arx sources

These rules apply to the Zig code in `src/` and `build.zig`. `make lint` checks
them, and CI runs it on every push and pull request. They are for building
`arx` itself: they are not part of the binary, and harness files that an agent
writes at run time (`tools/`, `hooks/`, prompts, specs) are not linted.

**Tool version:** arx builds with exactly one Zig release, 0.17.0 (`ZIG_VERSION`
in the Makefile, `minimum_zig_version` in `build.zig.zon`, and a check in
`build.zig`). `zig fmt` output can change between releases, so `make lint`
refuses any other version. To upgrade Zig, change all three in one commit,
fix what the new standard library breaks, and run `make test bench lint`.

## Rules

1. **`zig fmt`.** Run `make format` before committing.
2. **Files are at most 400 lines.** Split a module before it grows past that.
3. **Every file starts with a `//!` comment** that says what it is for.
4. **Every function, and every `pub` declaration, has a `///` comment** right
   above it. For a `pub` function, say what it does, what it takes and what
   it returns, and who owns returned memory. A private helper gets one line.
   Functions in `test` blocks, and `pub const` lines that only re-export,
   are exempt.
5. **Comments explain why**, not what the next line does.

## Naming (Zig's own)

| Kind | Style | Example |
|---|---|---|
| Types | `PascalCase` | `Spec`, `ToolSet`, `Exit` |
| Functions | `camelCase` | `load()`, `runTurns()` |
| Variables, parameters, fields | `snake_case` | `tool_seq`, `head_max` |
| Constants | `snake_case` | `max_observers`, `hook_points` |
| Files | `snake_case.zig` | `tool_exec.zig` |

Keep `pub` to what other files use.

## Memory and errors

- **Allocators are passed explicitly**, from `Context.gpa`. There is no global
  allocator.
- **Arenas for trees.** A JSON tree lives in one arena, owned by whatever owns
  the tree: a `Spec`, a `ToolSet`, a `Message`, an `Event`. Free the arena, not
  the pieces. An arena whose values hold `std.json.Array`s must not move
  (those arrays remember their allocator), so such arenas are heap-allocated.
- **Say who owns returned memory** in the doc comment ("Caller owns the
  result").
- **Return errors; do not panic** on runtime conditions. `error.OutOfMemory`
  propagates to `main`, which prints it and exits 1. Other failures (a file
  that cannot be read, a hook that crashes) become messages for the agent or
  the user. `@panic` and `unreachable` are for programmer bugs.
- The debug build reports leaks at exit, and the end-to-end tests fail on one.

## I/O

- Files, folders and time go through `std.Io` (`Context.io`).
- Processes start with `std.process.spawn` and are driven by `base/proc.zig`,
  which owns the pipes, the poll loop, process groups and timeouts.
- What `std.Io` lacks (append-mode files, non-blocking pipes, `waitpid`
  without blocking, local time) lives in `base/sys.zig`, nowhere else.

## Standard library (Zig 0.17)

Prefer the current names over deprecated ones: `allocator.print` (not
`std.fmt.allocPrint`), `std.mem.print` (not `std.fmt.bufPrint`),
`std.mem.find*` (not `indexOf*`), `trimStart`/`trimEnd`, `std.ArrayList(T)`
initialized with `.empty`, and `std.lang.Optimize` in `build.zig`.

## Layers

- `src/` has one folder per layer: `base` < `io`, `model`, `harness` < `agent`
  < `cli` < `main.zig`. A file only imports files from its own layer or below.
  The one exception: harness and model files import `agent/agent.zig` for the
  `Agent` they work for.
- Split a file when it nears 400 lines.
- `vendor/` holds third-party code (libyaml), unmodified and never linted.

## Tests

- Unit tests go in the file they test, in `test "..."` blocks; `src/main.zig`
  imports every file so `zig build test` finds them.
- Behavior the user sees gets an end-to-end check in `tests/*.sh`, against
  `tests/fake-curl`.
