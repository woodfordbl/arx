#!/usr/bin/env python3
"""pty.py: runs a command on a new pseudo-terminal and types keys into it.

For tests/ui.sh: pick and arx setup read keys from /dev/tty, so a test
needs a real terminal. The child gets the pty as its controlling terminal
(and as stdin and stderr unless told otherwise); its stdout is captured
apart from the screen bytes.

  pty.py [options] -- COMMAND [ARG...]
    --rows N, --cols N   the terminal size (24 x 80)
    --stdin FILE         stdin from FILE instead of the terminal
    --out FILE           the command's stdout (default: this script's)
    --err FILE           the command's stderr (default: the terminal)
    --screen FILE        everything drawn on the terminal
    --stty FILE          "same" or "changed": the terminal settings after
                         the command, compared with before
    --keys SPEC          keys to type, see below
    --pause SECS         the pause after each key (0.05)
    --timeout SECS       kill the command after this long (20); exit 124
    --no-tty             no controlling terminal at all (setsid only)
    --env NAME=VALUE     set a variable (TERM defaults to xterm-256color)

SPEC is text with <key> tokens: up down left right home end pgup pgdn
enter esc space tab bs del c-c c-d c-u c-w, <paste:TEXT> (bracketed),
<sleep:SECS>, <signal:NAME>, and <wait:TEXT>, which waits until TEXT
shows on the screen after the previous wait. Typing starts once the
command has drawn something, or after a second. The exit code is the
command's (128 + N for signal N).
"""
import fcntl
import os
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

KEYS = {
    "up": b"\x1b[A", "down": b"\x1b[B", "right": b"\x1b[C", "left": b"\x1b[D",
    "home": b"\x1b[H", "end": b"\x1b[F", "pgup": b"\x1b[5~",
    "pgdn": b"\x1b[6~", "enter": b"\r", "esc": b"\x1b", "space": b" ",
    "tab": b"\t", "bs": b"\x7f", "del": b"\x1b[3~", "c-c": b"\x03",
    "c-d": b"\x04", "c-u": b"\x15", "c-w": b"\x17", "c-z": b"\x1a",
}
ESCAPES = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-Za-z]|\x1b.")


def parse_keys(spec):
    """Splits SPEC into (kind, value) tokens."""
    tokens = [("wait", "")]
    for part in re.split(r"(<[a-z-]+(?::[^>]*)?>)", spec):
        if not part:
            continue
        m = re.fullmatch(r"<([a-z-]+)(?::([^>]*))?>", part)
        if not m:
            tokens.append(("send", part.encode()))
        elif m.group(1) == "paste":
            data = m.group(2).encode().replace(b"\\n", b"\n")
            tokens.append(("send", b"\x1b[200~" + data + b"\x1b[201~"))
        elif m.group(1) in ("wait", "sleep", "signal"):
            tokens.append((m.group(1), m.group(2) or ""))
        elif m.group(1) in KEYS:
            tokens.append(("send", KEYS[m.group(1)]))
        else:
            sys.exit("pty.py: unknown key <%s>" % m.group(1))
    return tokens


def parse_args(argv):
    """Returns the options as a dict and the command."""
    opts = {"rows": 24, "cols": 80, "keys": "", "pause": 0.05,
            "timeout": 20.0, "env": {}, "no_tty": False}
    i = 0
    while i < len(argv) and argv[i] != "--":
        name = argv[i][2:].replace("-", "_")
        if name == "no_tty":
            opts["no_tty"] = True
            i += 1
            continue
        value = argv[i + 1]
        if name == "env":
            k, _, v = value.partition("=")
            opts["env"][k] = v
        elif name in ("rows", "cols"):
            opts[name] = int(value)
        elif name in ("pause", "timeout"):
            opts[name] = float(value)
        else:
            opts[name] = value
        i += 2
    return opts, argv[i + 1:]


def main():
    opts, cmd = parse_args(sys.argv[1:])
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", opts["rows"], opts["cols"], 0, 0))
    before = termios.tcgetattr(slave)
    env = dict(os.environ)
    env.setdefault("TERM", "xterm-256color")
    env.update(opts["env"])

    def controlling_tty():
        if not opts["no_tty"]:
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    tty = None if opts["no_tty"] else slave
    stdin = open(opts["stdin"], "rb") if "stdin" in opts else (
        tty if tty is not None else subprocess.DEVNULL)
    stderr = subprocess.PIPE if "err" in opts else tty
    proc = subprocess.Popen(cmd, stdin=stdin, stdout=subprocess.PIPE,
                            stderr=stderr, env=env, start_new_session=True,
                            preexec_fn=controlling_tty)
    bufs = {master: bytearray(), proc.stdout.fileno(): bytearray()}
    if proc.stderr:
        bufs[proc.stderr.fileno()] = bytearray()
    open_fds = set(bufs)

    def pump(wait):
        ready, _, _ = select.select(list(open_fds), [], [], wait)
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if data:
                bufs[fd].extend(data)
            elif fd != master:
                open_fds.discard(fd)
        return bool(ready)

    tokens = parse_keys(opts["keys"])
    first_wait = time.time() + 1.0  # the implicit first wait gives up here
    seen = 0  # where the next <wait:> looks from, in the stripped screen
    next_at = 0.0
    deadline = time.time() + opts["timeout"]
    code = None
    while proc.poll() is None:
        now = time.time()
        if now > deadline:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            code = 124
            break
        if tokens and now >= next_at:
            kind, value = tokens[0]
            if kind == "wait":
                text = ESCAPES.sub(b"", bytes(bufs[master])).decode("utf-8",
                                                                   "replace")
                at = text.find(value, seen) if value else (
                    0 if text or now > first_wait else -1)
                if at < 0:
                    pump(0.01)
                    continue
                seen = at + len(value)
                tokens.pop(0)
                next_at = now + opts["pause"]
                continue
            tokens.pop(0)
            if kind == "sleep":
                next_at = now + float(value)
                continue
            if kind == "signal":
                os.kill(proc.pid, getattr(signal, "SIG" + value))
            else:
                os.write(master, value)
            soon = tokens and tokens[0][0] == "sleep"
            next_at = now + (0 if soon else opts["pause"])
        pump(0.01)
    while pump(0.1):
        pass
    if code is None:
        code = proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
    after = termios.tcgetattr(slave)
    if "screen" in opts:
        with open(opts["screen"], "wb") as f:
            f.write(bufs[master])
    if "stty" in opts:
        with open(opts["stty"], "w") as f:
            f.write("same\n" if before == after else "changed\n")
    out = bytes(bufs[proc.stdout.fileno()])
    if "out" in opts:
        with open(opts["out"], "wb") as f:
            f.write(out)
    else:
        sys.stdout.buffer.write(out)
    if proc.stderr:
        with open(opts["err"], "wb") as f:
            f.write(bufs[proc.stderr.fileno()])
    sys.exit(code)


if __name__ == "__main__":
    main()
