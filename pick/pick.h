// pick.h: pick, the small menu program that arx's commands call.
//   term.c  the terminal: raw mode and its restore on every exit, signals,
//           keys and the redraw
//   draw.c  strings, glyphs and colors, display width, the answered line
//   list.c  `select` and `multi`: a list you move through, with a filter
//   text.c  `input`, `secret` and `confirm`
//   pick.c  arguments, items on stdin, `spin`, and the exit codes
// pick draws inline below the cursor on /dev/tty and prints only the answer
// on stdout, so `$(pick select ...)` works. It links only libc.

#ifndef PICK_PICK_H_
#define PICK_PICK_H_

#include <stddef.h>

// Exit codes; `spin -- COMMAND` exits with the command's own code.
enum {
  kAnswered = 0,    // answered (`confirm`: yes)
  kNo = 1,          // `confirm`: no
  kUsage = 2,       // usage error
  kNoTerminal = 3,  // no terminal: plain prompts instead
  kBack = 4,        // Esc: go back one step
  kCancel = 130,    // Ctrl-C: cancel
};

// One item of a list: "VALUE<TAB>LABEL<TAB>NOTE<TAB>FLAGS" on stdin.
typedef struct Item {
  char *value, *label, *note;
  int checked, off;
} Item;

// The command line.
typedef struct Opts {
  const char *verb, *title, *def, *placeholder;
  int filter, custom, quiet, height, min, pid;
  char** cmd;  // spin -- COMMAND [ARG...]
} Opts;

// ---- term.c ----

// One key press. kKeyText and kKeyPaste carry their bytes.
typedef enum Key {
  kKeyNone,
  kKeyText,
  kKeyPaste,
  kKeyEnter,
  kKeyEsc,
  kKeyUp,
  kKeyDown,
  kKeyLeft,
  kKeyRight,
  kKeyHome,
  kKeyEnd,
  kKeyPgUp,
  kKeyPgDn,
  kKeyBackspace,
  kKeyDelete,
  kKeyCtrlC,
  kKeyCtrlD,
  kKeyCtrlU,
  kKeyCtrlW,
  kKeyRedraw,  // the size changed, or pick came back from Ctrl-Z
  kKeyEof,     // the terminal went away
} Key;

// A growable string. Zero-initialize; free `s` when done.
typedef struct Buf {
  char* s;
  size_t len, cap;
} Buf;

// Opens /dev/tty and installs the signal handlers that restore it.
// Returns 0, or kNoTerminal when there is no usable terminal: no
// /dev/tty, TERM unset or dumb, or under 20 columns.
int TermOpen(void);

// Enters raw mode. With `isig`, Ctrl-C and Ctrl-Z still send signals.
void TermRaw(int isig);

// Turns bracketed paste on or off.
void TermPaste(int on);

// Restores the terminal as pick found it. Safe to call more than once.
void TermRestore(void);

// The terminal's columns (TIOCGWINSZ, then COLUMNS, then 80).
int TermCols(void);

// The terminal's rows (TIOCGWINSZ, then LINES, then 24).
int TermRows(void);

// Waits for the next key. `text` receives the bytes of kKeyText and
// kKeyPaste.
Key TermKey(Buf* text);

// Replaces the drawn block with `frame` (`lines` lines joined by "\r\n"),
// then puts the cursor at `row`, `col` of it; a negative `row` hides it.
void TermDraw(const Buf* frame, int lines, int row, int col);

// Erases the drawn block.
void TermClear(void);

// Writes bytes to the terminal.
void TermWrite(const char* s, size_t n);

// ---- draw.c ----

// Colors and glyphs, chosen once by StyleInit.
typedef struct Style {
  int utf8;
  const char *accent, *dim, *bold, *green, *red, *reset;
  const char *ask, *cursor, *on, *off, *done, *up, *down, *ellipsis;
  const char* const* spin;
  int n_spin;
} Style;

// The style in use.
extern Style g_style;

// Chooses glyphs from the locale (Unicode when it is UTF-8) and colors from
// NO_COLOR (none when it is set and not empty).
void StyleInit(void);

// Appends n bytes.
void BufAdd(Buf* b, const char* s, size_t n);

// Appends a string.
void BufStr(Buf* b, const char* s);

// Appends printf-style text.
void BufFmt(Buf* b, const char* fmt, ...);

// Drops the last UTF-8 character, if any.
void BufPop(Buf* b);

// Display width of n bytes of text.
int TextWidth(const char* s, size_t n);

// Byte length of the longest prefix of s (n bytes) that fits in `width`.
size_t TextFit(const char* s, size_t n, int width);

// Appends s, cut with an ellipsis to at most `width` columns.
void PutFit(Buf* b, const char* s, int width);

// Like PutFit, then pads with spaces to `width` columns.
void PutPad(Buf* b, const char* s, int width);

// Appends the title line's start, "? TITLE  ", and returns its width.
int PutTitle(Buf* b, const char* title);

// Writes the answered line, "✓ TITLE  TEXT", in place of the block.
void TermDone(const char* title, const char* text);

// ---- list.c and text.c ----

// Runs `select` (multi = 0) or `multi` on an open terminal and prints the
// answer. Returns an exit code.
int RunList(const Opts* o, Item* items, int n, int multi);

// Runs `input` (secret = 0) or `secret` and prints the text.
int RunText(const Opts* o, int secret);

// Runs `confirm`.
int RunConfirm(const Opts* o);

#endif  // PICK_PICK_H_
