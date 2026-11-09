// text.c: `pick input`, `pick secret` and `pick confirm`: one line you
// type, with the cursor kept in view. See pick.h.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pick/pick.h"

// The byte after the UTF-8 character at `at`.
static size_t NextChar(const Buf* t, size_t at) {
  if (at >= t->len) return t->len;
  at++;
  while (at < t->len && ((unsigned char)t->s[at] & 0xc0) == 0x80) at++;
  return at;
}

// The byte where the UTF-8 character before `at` starts.
static size_t PrevChar(const Buf* t, size_t at) {
  if (!at) return 0;
  at--;
  while (at && ((unsigned char)t->s[at] & 0xc0) == 0x80) at--;
  return at;
}

// Removes bytes [from, to) of t.
static void Cut(Buf* t, size_t from, size_t to) {
  memmove(t->s + from, t->s + to, t->len - to + 1);
  t->len -= to - from;
}

// Draws a text box: the title, then the text (bullets for a secret), cut
// at the start so the cursor stays in view.
static void DrawText(const Opts* o, const Buf* text, size_t pos, int secret) {
  Buf b = {0}, view = {0};
  int col = PutTitle(&b, o->title, (TermCols() - 1) / 2);
  int room = TermCols() - 1 - col;
  size_t at = pos;
  if (secret) {
    for (size_t i = 0; i < text->len; i = NextChar(text, i)) {
      if (i == pos) at = view.len;
      BufStr(&view, g_style.utf8 ? "•" : "*");
    }
    if (pos == text->len) at = view.len;
  } else {
    BufAdd(&view, text->s, text->len);
  }
  if (!text->len && !secret && o->placeholder) {
    BufStr(&b, g_style.dim);
    PutFit(&b, o->placeholder, room);
    BufStr(&b, g_style.reset);
  } else if (view.len) {
    size_t start = 0;
    int before = TextWidth(view.s, at);
    while (before > room - 1 && start < at) {
      size_t next = NextChar(&view, start);
      before -= TextWidth(view.s + start, next - start);
      start = next;
    }
    BufAdd(&b, view.s + start, TextFit(view.s + start, view.len - start, room));
    col += before;
  }
  TermDraw(&b, 1, 0, col);
  free(b.s);
  free(view.s);
}

// `input` and `secret`.
int RunText(const Opts* o, int secret) {
  Buf text = {0}, key = {0};
  BufStr(&text, !secret && o->def ? o->def : "");
  size_t pos = text.len, word;
  int code = -1;
  TermRaw(0);
  TermPaste(1);
  while (code < 0) {
    DrawText(o, &text, pos, secret);
    switch (TermKey(&key)) {
      case kKeyText:
      case kKeyPaste:
        BufAdd(&text, key.s, key.len);  // grows; then move into place
        memmove(text.s + pos + key.len, text.s + pos, text.len - key.len - pos);
        memcpy(text.s + pos, key.s, key.len);
        pos += key.len;
        break;
      case kKeyLeft:
        pos = PrevChar(&text, pos);
        break;
      case kKeyRight:
        pos = NextChar(&text, pos);
        break;
      case kKeyHome:
        pos = 0;
        break;
      case kKeyEnd:
        pos = text.len;
        break;
      case kKeyBackspace:
        word = PrevChar(&text, pos), Cut(&text, word, pos), pos = word;
        break;
      case kKeyDelete:
        Cut(&text, pos, NextChar(&text, pos));
        break;
      case kKeyCtrlU:
        Cut(&text, 0, text.len), pos = 0;
        break;
      case kKeyCtrlW:
        word = pos;
        while (word && text.s[word - 1] == ' ') word--;
        while (word && text.s[word - 1] != ' ') word--;
        Cut(&text, word, pos), pos = word;
        break;
      case kKeyCtrlD:
        if (!text.len) code = kBack;
        break;
      case kKeyEnter:
        code = kAnswered;
        break;
      case kKeyEsc:
        code = kBack;
        break;
      case kKeyCtrlC:
      case kKeyEof:
        code = kCancel;
        break;
      default:
        break;
    }
  }
  if (code == kAnswered && !o->quiet) {
    TermDone(o->title, secret ? "(hidden)" : text.s);
  } else {
    TermClear();
  }
  TermRestore();
  if (code == kAnswered) printf("%s\n", text.s);
  free(text.s);
  free(key.s);
  return code;
}

// `confirm`: y, n, or Enter for the default.
int RunConfirm(const Opts* o) {
  int yes = o->def && !strcmp(o->def, "yes"), code = -1;
  const char* hint = yes ? "(Y/n)" : "(y/N)";
  Buf key = {0};
  TermRaw(0);
  while (code < 0) {
    Buf b = {0};
    int col = PutTitle(&b, o->title, TermCols() - 1 - 6);
    BufFmt(&b, "%s%s%s", g_style.dim, hint, g_style.reset);
    TermDraw(&b, 1, 0, col + 6);
    free(b.s);
    Key k = TermKey(&key);
    char c = k == kKeyText ? key.s[0] : 0;
    if (c == 'y' || c == 'Y') code = kAnswered, yes = 1;
    if (c == 'n' || c == 'N') code = kNo, yes = 0;
    if (k == kKeyEnter) code = yes ? kAnswered : kNo;
    if (k == kKeyEsc) code = kBack;
    if (k == kKeyCtrlC || k == kKeyEof) code = kCancel;
  }
  if ((code == kAnswered || code == kNo) && !o->quiet) {
    TermDone(o->title, yes ? "yes" : "no");
  } else {
    TermClear();
  }
  TermRestore();
  free(key.s);
  return code;
}
