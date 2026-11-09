#!/usr/bin/env bash
# wasm-imports.sh: checks that arx.wasm imports only what the host interface
# allows: ABI v1 from module "arx" and the WASI preview1 functions that
# arx.js implements (plans/0.2.0/wasm.md, "The host interface"). It also
# checks that the module exports memory, _initialize, arx_main and arx_abi.
# Any other import fails the build: it would be a call that no browser can
# answer, such as a process call outside src/base/proc.c.
#
#   scripts/wasm-imports.sh arx.wasm
set -euo pipefail

wasm=${1:?usage: scripts/wasm-imports.sh arx.wasm}

python3 - "$wasm" <<'EOF'
import sys

ALLOWED = {
    "arx": {"http_open", "task_start", "poll", "read", "write", "status",
            "close", "runnable", "sleep"},
    "wasi_snapshot_preview1": {
        "args_get", "args_sizes_get", "environ_get", "environ_sizes_get",
        "clock_time_get", "random_get", "fd_close", "fd_fdstat_get",
        "fd_fdstat_set_flags", "fd_filestat_get", "fd_prestat_get",
        "fd_prestat_dir_name", "fd_read", "fd_readdir", "fd_seek",
        "fd_write", "path_create_directory", "path_filestat_get",
        "path_open", "path_readlink", "path_remove_directory",
        "path_rename", "path_symlink", "path_unlink_file", "poll_oneoff",
        "proc_exit"},
}
EXPORTS = {"memory", "_initialize", "arx_main", "arx_abi"}

data = open(sys.argv[1], "rb").read()
if data[:4] != b"\0asm":
    sys.exit(f"{sys.argv[1]}: not a WebAssembly module")


def leb(at):
    """Reads an unsigned LEB128 number; returns it and the next offset."""
    value, shift = 0, 0
    while True:
        byte = data[at]
        value |= (byte & 0x7F) << shift
        at += 1
        shift += 7
        if not byte & 0x80:
            return value, at


def name(at):
    """Reads a name; returns it and the next offset."""
    n, at = leb(at)
    return data[at:at + n].decode(), at + n


def limits(at):
    """Skips a limits field (table and memory types)."""
    flags, at = leb(at)
    _, at = leb(at)
    if flags & 1:
        _, at = leb(at)
    return at


imports, exports = [], set()
at = 8
while at < len(data):
    section, at = data[at], at + 1
    size, at = leb(at)
    end = at + size
    if section == 2:  # imports
        count, p = leb(at)
        for _ in range(count):
            module, p = name(p)
            field, p = name(p)
            kind, p = data[p], p + 1
            if kind == 0:  # function: a type index
                _, p = leb(p)
            elif kind == 1:  # table: a reference type, then limits
                p = limits(p + 1)
            elif kind == 2:  # memory
                p = limits(p)
            else:  # global: a value type and mutability
                p += 2
            imports.append((module, field))
    elif section == 7:  # exports
        count, p = leb(at)
        for _ in range(count):
            field, p = name(p)
            p += 1
            _, p = leb(p)
            exports.add(field)
    at = end

bad = [f"{m}.{f}" for m, f in imports if f not in ALLOWED.get(m, set())]
missing = sorted(EXPORTS - exports)
for b in bad:
    print(f"wasm-imports: {sys.argv[1]} imports {b}, which the host interface does not have")
for m in missing:
    print(f"wasm-imports: {sys.argv[1]} does not export {m}")
if bad or missing:
    sys.exit(1)
print(f"wasm-imports: ok ({len(imports)} imports, all in ABI v1 or WASI preview1)")
EOF
