// draw.c: what pick draws with: growable strings, glyphs and colors,
// display width (cut by columns, never inside a UTF-8 sequence), and the
// answered line. See pick.h.

#include <langinfo.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <wchar.h>

#include "pick/pick.h"

Style g_style;

// Appends n bytes; see pick.h.
void BufAdd(Buf* b, const char* s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 128;
    while (cap < b->len + n + 1) cap *= 2;
    char* grown = realloc(b->s, cap);
    if (!grown) {
      TermRestore();
      fputs("pick: out of memory\n", stderr);
      exit(kUsage);
    }
    b->s = grown;
    b->cap = cap;
  }
  memcpy(b->s + b->len, s, n);
  b->len += n;
  b->s[b->len] = 0;
}

// Appends a string; see pick.h.
void BufStr(Buf* b, const char* s) { BufAdd(b, s, strlen(s)); }

// Appends printf-style text; see pick.h.
void BufFmt(Buf* b, const char* fmt, ...) {
  char small[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(small, sizeof(small), fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if ((size_t)n < sizeof(small)) {
    BufAdd(b, small, (size_t)n);
    return;
  }
  char* big = malloc((size_t)n + 1);
  if (!big) return;
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  BufAdd(b, big, (size_t)n);
  free(big);
}

// Drops the last UTF-8 character; see pick.h.
void BufPop(Buf* b) {
  while (b->len && ((unsigned char)b->s[b->len - 1] & 0xc0) == 0x80) b->len--;
  if (b->len) b->len--;
  if (b->s) b->s[b->len] = 0;
}

// Chooses glyphs and colors; see pick.h.
void StyleInit(void) {
  static const char* const kBraille[] = {"⠋", "⠙", "⠹", "⠸", "⠼",
                                         "⠴", "⠦", "⠧", "⠇", "⠏"};
  static const char* const kAscii[] = {"|", "/", "-", "\\"};
  const char* set = nl_langinfo(CODESET);
  const char* no_color = getenv("NO_COLOR");
  int color = !(no_color && *no_color);
  Style s = {0};
  s.utf8 = set && (!strcasecmp(set, "UTF-8") || !strcasecmp(set, "utf8"));
  s.accent = color ? "\033[36m" : "";
  s.dim = color ? "\033[2m" : "";
  s.bold = color ? "\033[1m" : "";
  s.green = color ? "\033[32m" : "";
  s.red = color ? "\033[31m" : "";
  s.reset = color ? "\033[0m" : "";
  s.ask = "?";
  s.cursor = s.utf8 ? "›" : ">";
  s.on = s.utf8 ? "●" : "[x]";
  s.off = s.utf8 ? "○" : "[ ]";
  s.done = s.utf8 ? "✓" : "+";
  s.up = s.utf8 ? "↑" : "^";
  s.down = s.utf8 ? "↓" : "v";
  s.ellipsis = s.utf8 ? "…" : "...";
  s.spin = s.utf8 ? kBraille : kAscii;
  s.n_spin = s.utf8 ? 10 : 4;
  g_style = s;
}

// The width of the character at s (n bytes left); sets *len to its bytes.
static int CharWidth(const char* s, size_t n, size_t* len) {
  *len = 1;
  if ((unsigned char)*s < 0x80 || !g_style.utf8) return 1;
  wchar_t wc;
  mbstate_t st;
  memset(&st, 0, sizeof(st));
  size_t r = mbrtowc(&wc, s, n, &st);
  if (r == (size_t)-1 || r == (size_t)-2 || r == 0) return 1;
  *len = r;
  int w = wcwidth(wc);
  return w < 0 ? 1 : w;
}

// Display width; see pick.h.
int TextWidth(const char* s, size_t n) {
  int width = 0;
  for (size_t i = 0, len; i < n; i += len)
    width += CharWidth(s + i, n - i, &len);
  return width;
}

// The prefix that fits; see pick.h.
size_t TextFit(const char* s, size_t n, int width) {
  size_t i = 0, len;
  for (int used = 0; i < n; i += len) {
    used += CharWidth(s + i, n - i, &len);
    if (used > width) break;
  }
  return i;
}

// Appends s cut to `width`; see pick.h.
void PutFit(Buf* b, const char* s, int width) {
  size_t n = strlen(s);
  if (width <= 0) return;
  if (TextWidth(s, n) <= width) {
    BufAdd(b, s, n);
    return;
  }
  int ell = TextWidth(g_style.ellipsis, strlen(g_style.ellipsis));
  if (width <= ell) {
    BufAdd(b, s, TextFit(s, n, width));
    return;
  }
  BufAdd(b, s, TextFit(s, n, width - ell));
  BufStr(b, g_style.ellipsis);
}

// Appends s cut and padded to `width`; see pick.h.
void PutPad(Buf* b, const char* s, int width) {
  size_t start = b->len;
  PutFit(b, s, width);
  for (int w = TextWidth(b->s + start, b->len - start); w < width; w++)
    BufAdd(b, " ", 1);
}

// Appends "? TITLE  "; see pick.h.
int PutTitle(Buf* b, const char* title, int max) {
  int width = 2;
  BufFmt(b, "%s%s%s ", g_style.accent, g_style.ask, g_style.reset);
  if (*title) {
    BufFmt(b, "%s%s", g_style.accent, g_style.bold);
    size_t start = b->len;
    PutFit(b, title, max - width - 2);
    width += TextWidth(b->s + start, b->len - start) + 2;
    BufFmt(b, "%s  ", g_style.reset);
  }
  return width;
}

// Writes the answered line; see pick.h.
void TermDone(const char* title, const char* text) {
  Buf b = {0};
  int room = TermCols() - 1 - TextWidth(g_style.done, strlen(g_style.done));
  BufFmt(&b, "%s%s%s ", g_style.green, g_style.done, g_style.reset);
  room--;
  if (*title) {
    int width = TextWidth(title, strlen(title));
    width = width < 8 ? 8 : width;
    width = width < room ? width : room;
    BufStr(&b, g_style.bold);
    PutPad(&b, title, width);
    BufStr(&b, g_style.reset);
    room -= width + 2;
    if (room > 0) BufStr(&b, "  ");
  }
  PutFit(&b, text, room);
  BufStr(&b, "\r\n");
  TermClear();
  TermWrite(b.s, b.len);
  free(b.s);
}
