// term.c: the terminal side of pick: raw mode and its restore on every
// exit, signals, keys and the redraw. See pick.h.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "pick/pick.h"

static int g_fd = -1;                   // /dev/tty
static struct termios g_saved;          // the terminal as pick found it
static volatile sig_atomic_t g_raw;     // 1 raw, 2 raw with ISIG
static volatile sig_atomic_t g_paste;   // bracketed paste is on
static volatile sig_atomic_t g_hidden;  // the cursor is hidden
static volatile sig_atomic_t g_row;     // the cursor's row in the block
static volatile sig_atomic_t g_redraw;  // a wakeup came mid-key
static int g_wake[2] = {-1, -1};        // signal handlers write here
static unsigned char g_in[512];         // bytes read, not yet decoded
static size_t g_in_len;

// Writes all of s, from normal code or a signal handler.
static void Put(int fd, const char* s, size_t n) {
  while (n) {
    ssize_t w = write(fd, s, n);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return;
    s += w;
    n -= (size_t)w;
  }
}

// Erases the drawn block, from normal code or a signal handler.
static void EraseNow(void) {
  char seq[32] = "\r\033[";
  size_t n = 3;
  if (g_row > 0) {
    char digits[12];
    int i = sizeof(digits), row = g_row;
    do {
      digits[--i] = (char)('0' + row % 10);
    } while ((row /= 10) && i);
    memcpy(seq + n, digits + i, sizeof(digits) - (size_t)i);
    n += sizeof(digits) - (size_t)i;
    memcpy(seq + n, "A\033[", 3);
    n += 3;
  }
  seq[n++] = 'J';
  Put(g_fd, seq, n);
  g_row = 0;
}

// Restores the terminal; `erase` also erases the block. Signal-safe.
static void RestoreNow(int erase) {
  if (g_fd < 0) return;
  if (erase) EraseNow();
  if (g_paste) Put(g_fd, "\033[?2004l", 8);
  if (g_hidden) Put(g_fd, "\033[?25h", 6);
  if (g_raw) tcsetattr(g_fd, TCSADRAIN, &g_saved);
  g_paste = g_hidden = g_raw = 0;
}

// Sets raw mode; signal-safe.
static void RawNow(int isig) {
  struct termios t = g_saved;
  t.c_lflag &= ~(tcflag_t)(ICANON | ECHO | IEXTEN | (isig ? 0 : ISIG));
  t.c_iflag &= ~(tcflag_t)(ICRNL | IXON);
  t.c_cc[VMIN] = 1;
  t.c_cc[VTIME] = 0;
  tcsetattr(g_fd, TCSADRAIN, &t);
  g_raw = isig ? 2 : 1;
}

// Makes the main loop redraw.
static void Wake(void) {
  if (g_wake[1] >= 0) Put(g_wake[1], "w", 1);
}

// SIGTERM, SIGHUP, SIGQUIT, SIGINT: restore, then die of the signal.
static void OnFatal(int sig) {
  RestoreNow(1);
  signal(sig, SIG_DFL);
  raise(sig);  // delivered when the handler returns
}

// SIGTSTP (and Ctrl-Z): restore, stop, and on SIGCONT take the terminal
// back and redraw.
static void OnStop(int sig) {
  int saved_errno = errno, raw = g_raw, paste = g_paste, hidden = g_hidden;
  RestoreNow(1);
  signal(sig, SIG_DFL);
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, sig);
  sigprocmask(SIG_UNBLOCK, &set, NULL);
  raise(sig);  // stops here until SIGCONT
  signal(sig, OnStop);
  if (raw) RawNow(raw == 2);
  if (paste) Put(g_fd, "\033[?2004h", 8);
  if (hidden) Put(g_fd, "\033[?25l", 6);
  g_paste = paste;
  g_hidden = hidden;
  Wake();
  errno = saved_errno;
}

// SIGWINCH: redraw at the new size.
static void OnResize(int sig) {
  int saved_errno = errno;
  (void)sig;
  Wake();
  errno = saved_errno;
}

// Installs `handler` for `sig`, unless the signal was ignored when pick
// started (as in a background job).
static void Catch(int sig, void (*handler)(int)) {
  struct sigaction sa, old;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = handler;
  sigemptyset(&sa.sa_mask);
  if (sigaction(sig, NULL, &old) == 0 && old.sa_handler == SIG_IGN) return;
  sigaction(sig, &sa, NULL);
}

// Opens the terminal; see pick.h.
int TermOpen(void) {
  const char* term = getenv("TERM");
  if (!term || !*term || !strcmp(term, "dumb")) return kNoTerminal;
  int fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0) return kNoTerminal;
  if (!isatty(fd) || tcgetattr(fd, &g_saved)) {
    close(fd);
    return kNoTerminal;
  }
  g_fd = fd;
  if (TermCols() < 20) {
    g_fd = -1;
    close(fd);
    return kNoTerminal;
  }
  if (pipe(g_wake) == 0) {
    for (int i = 0; i < 2; i++) {
      fcntl(g_wake[i], F_SETFL, fcntl(g_wake[i], F_GETFL) | O_NONBLOCK);
      fcntl(g_wake[i], F_SETFD, FD_CLOEXEC);
    }
  }
  int fatal[] = {SIGTERM, SIGHUP, SIGQUIT, SIGINT};
  for (size_t i = 0; i < sizeof(fatal) / sizeof(*fatal); i++)
    Catch(fatal[i], OnFatal);
  Catch(SIGTSTP, OnStop);
  Catch(SIGWINCH, OnResize);
  return 0;
}

// Enters raw mode; see pick.h.
void TermRaw(int isig) { RawNow(isig); }

// Bracketed paste; see pick.h.
void TermPaste(int on) {
  Put(g_fd, on ? "\033[?2004h" : "\033[?2004l", 8);
  g_paste = on;
}

// Restores the terminal; see pick.h.
void TermRestore(void) { RestoreNow(0); }

// Columns; see pick.h.
int TermCols(void) {
  struct winsize ws;
  if (g_fd >= 0 && !ioctl(g_fd, TIOCGWINSZ, &ws) && ws.ws_col) return ws.ws_col;
  const char* env = getenv("COLUMNS");
  int n = env ? atoi(env) : 0;
  return n > 0 ? n : 80;
}

// Rows; see pick.h.
int TermRows(void) {
  struct winsize ws;
  if (g_fd >= 0 && !ioctl(g_fd, TIOCGWINSZ, &ws) && ws.ws_row) return ws.ws_row;
  const char* env = getenv("LINES");
  int n = env ? atoi(env) : 0;
  return n > 0 ? n : 24;
}

// Reads more input, waiting up to `ms` (forever when negative). Returns 1
// when bytes came, 0 on a timeout, -1 when the terminal is gone, and 2 for
// a wakeup while waiting forever (one mid-key sets g_redraw instead).
static int Fill(int ms) {
  for (;;) {
    struct pollfd p[2] = {{g_fd, POLLIN, 0}, {g_wake[0], POLLIN, 0}};
    int r = poll(p, g_wake[0] >= 0 ? 2 : 1, ms);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return r;
    if (p[1].revents & POLLIN) {
      char drain[64];
      while (read(g_wake[0], drain, sizeof(drain)) > 0) continue;
      if (ms < 0) return 2;
      g_redraw = 1;
    }
    if (!p[0].revents) continue;
    ssize_t n = read(g_fd, g_in + g_in_len, sizeof(g_in) - g_in_len);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
    if (n <= 0) return -1;
    g_in_len += (size_t)n;
    return 1;
  }
}

// Drops n decoded bytes.
static void Consume(size_t n) {
  if (n > g_in_len) n = g_in_len;
  memmove(g_in, g_in + n, g_in_len - n);
  g_in_len -= n;
}

// Reads a bracketed paste up to ESC [ 201 ~, without its control
// characters (newlines included); tabs become spaces.
static Key Paste(Buf* text) {
  static const char kEnd[] = "\033[201~";
  for (;;) {
    size_t i = 0;
    for (; i < g_in_len && g_in[i] != 0x1b; i++) {
      char c = g_in[i] == '\t' ? ' ' : (char)g_in[i];
      if ((unsigned char)c >= 0x20 && c != 0x7f && text->len < 65536)
        BufAdd(text, &c, 1);
    }
    Consume(i);
    size_t have = g_in_len < 6 ? g_in_len : 6;
    if (have && memcmp(g_in, kEnd, have)) {
      Consume(1);  // a stray ESC
    } else if (have == 6) {
      Consume(6);
      return kKeyPaste;
    } else if (Fill(1000) <= 0) {
      Consume(g_in_len);
      return kKeyPaste;
    }
  }
}

// Decodes an escape sequence at the start of the input.
static Key Escape(Buf* text) {
  if (g_in_len == 1) Fill(50);  // a lone ESC is Esc after 50 ms
  if (g_in_len == 1 || (g_in[1] != '[' && g_in[1] != 'O')) {
    Consume(1);
    return kKeyEsc;
  }
  size_t i = 2;
  for (;;) {
    while (i >= g_in_len) {
      if (Fill(50) <= 0) {
        Consume(g_in_len);
        return kKeyNone;
      }
    }
    unsigned char c = g_in[i++];
    if (c >= 0x40 && c <= 0x7e) break;
    if (i > 16) {
      Consume(i);
      return kKeyNone;
    }
  }
  // ESC [ X and ESC O X, then ESC [ N ~ for N up to 8.
  static const char kFinals[] = "ABCDHF";
  static const Key kFinalKeys[] = {kKeyUp,   kKeyDown, kKeyRight,
                                   kKeyLeft, kKeyHome, kKeyEnd};
  static const Key kTilde[] = {kKeyNone,   kKeyHome, kKeyNone,
                               kKeyDelete, kKeyEnd,  kKeyPgUp,
                               kKeyPgDn,   kKeyHome, kKeyEnd};
  unsigned char final = g_in[i - 1];
  int num = atoi((const char*)g_in + 2);
  Consume(i);
  const char* at = strchr(kFinals, final);
  if (at) return kFinalKeys[at - kFinals];
  if (final != '~') return kKeyNone;
  if (num == 200) return Paste(text);
  return num >= 0 && num <= 8 ? kTilde[num] : kKeyNone;
}

// Waits for and decodes one key; see pick.h.
Key TermKey(Buf* text) {
  text->len = 0;
  if (text->s) text->s[0] = 0;
  if (g_redraw) {
    g_redraw = 0;
    return kKeyRedraw;
  }
  if (!g_in_len) {
    int r = Fill(-1);
    if (r == 2) return kKeyRedraw;
    if (r <= 0) return kKeyEof;
  }
  // Control keys; Backspace is DEL (127) or Ctrl-H.
  static const Key kControl[32] = {
      [1] = kKeyHome,      [3] = kKeyCtrlC,  [4] = kKeyCtrlD,  [5] = kKeyEnd,
      [8] = kKeyBackspace, [10] = kKeyEnter, [13] = kKeyEnter, [14] = kKeyDown,
      [16] = kKeyUp,       [21] = kKeyCtrlU, [23] = kKeyCtrlW};
  unsigned char c = g_in[0];
  if (c == 0x1b) return Escape(text);
  if (c < 0x20 || c == 0x7f) {
    Consume(1);
    if (c == 0x1a) kill(0, SIGTSTP);  // Ctrl-Z: OnStop restores, then stops
    return c == 0x1a ? kKeyRedraw : c == 0x7f ? kKeyBackspace : kControl[c];
  }
  size_t need = c < 0xc0 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
  while (g_in_len < need && Fill(50) > 0) continue;
  if (need > g_in_len) need = g_in_len;
  BufAdd(text, (const char*)g_in, need);
  Consume(need);
  return kKeyText;
}

// Replaces the block; see pick.h.
void TermDraw(const Buf* frame, int lines, int row, int col) {
  Buf out = {0};
  BufStr(&out, "\033[?25l\r");
  if (g_row > 0) BufFmt(&out, "\033[%dA", (int)g_row);
  BufStr(&out, "\033[J");
  if (frame->len) BufAdd(&out, frame->s, frame->len);
  if (row >= 0) {
    BufStr(&out, "\r");
    if (lines - 1 - row > 0) BufFmt(&out, "\033[%dA", lines - 1 - row);
    if (col > 0) BufFmt(&out, "\033[%dC", col);
    BufStr(&out, "\033[?25h");
  }
  g_hidden = row < 0;
  TermWrite(out.s, out.len);
  g_row = row < 0 ? lines - 1 : row;
  free(out.s);
}

// Erases the block; see pick.h.
void TermClear(void) {
  if (g_fd >= 0) EraseNow();
}

// Writes to the terminal; see pick.h.
void TermWrite(const char* s, size_t n) {
  if (g_fd >= 0) Put(g_fd, s, n);
}
