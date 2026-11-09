// list.c: `pick select` and `pick multi`: a list you move through with the
// arrow keys, filtered as you type with --filter. See pick.h.

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pick/pick.h"

// The state of one list.
typedef struct List {
  const Opts* o;
  Item* items;
  int n, multi;
  int* shown;  // indexes of the items that match the filter
  int n_shown, cur, top, label_width, warn;
  Buf filter;
} List;

// True when `needle` is in `hay`, ignoring ASCII case.
static int Contains(const char* hay, const char* needle) {
  size_t n = strlen(needle);
  for (; *hay; hay++) {
    size_t i = 0;
    while (i < n && hay[i] &&
           tolower((unsigned char)hay[i]) == tolower((unsigned char)needle[i]))
      i++;
    if (i == n) return 1;
  }
  return !n;
}

// Moves the cursor to the first item it can choose, from `from` on.
static void FirstOn(List* l, int from) {
  l->cur = 0;
  for (int i = from; i < l->n_shown; i++) {
    if (!l->items[l->shown[i]].off) {
      l->cur = i;
      return;
    }
  }
}

// Rebuilds the shown items from the filter.
static void Refilter(List* l) {
  l->n_shown = 0;
  for (int i = 0; i < l->n; i++) {
    const char* f = l->filter.s ? l->filter.s : "";
    if (Contains(l->items[i].value, f) || Contains(l->items[i].label, f))
      l->shown[l->n_shown++] = i;
  }
  l->top = 0;
  FirstOn(l, 0);
}

// How many rows of items fit.
static int Visible(const List* l) {
  int rows = TermRows() - 4;
  int vis = l->o->height < rows ? l->o->height : rows;
  if (vis > l->n_shown) vis = l->n_shown;
  return vis < 1 ? 1 : vis;
}

// Appends a "↑ 3 more" or "↓ 12 more" line.
static void PutMore(Buf* b, const char* glyph, int count, int cols) {
  char text[64];
  snprintf(text, sizeof(text), "%s %d more", glyph, count);
  BufFmt(b, "\r\n%s  ", g_style.dim);
  PutFit(b, text, cols - 2);
  BufStr(b, g_style.reset);
}

// Appends one item row.
static void PutItem(const List* l, Buf* b, int index, int cols) {
  const Item* it = &l->items[l->shown[index]];
  const Style* s = &g_style;
  int at = index == l->cur, room = cols;
  BufStr(b, "\r\n");
  if (at) BufFmt(b, "%s%s%s ", s->accent, s->cursor, s->reset);
  if (!at) BufAdd(b, "  ", 2);
  room -= 2;
  if (l->multi) {
    const char* mark = it->checked ? s->on : s->off;
    BufFmt(b, "%s%s%s ", it->checked ? s->accent : "", mark, s->reset);
    room -= TextWidth(mark, strlen(mark)) + 1;
  }
  char label[4200];
  snprintf(label, sizeof(label), "%s%s", it->label,
           it->off && !*s->dim ? " (off)" : "");
  int notes = cols >= 50 && *it->note;
  int width = notes ? (l->label_width < room ? l->label_width : room) : room;
  BufStr(b, it->off ? s->dim : at ? s->accent : "");
  if (notes) {
    PutPad(b, label, width);
  } else {
    PutFit(b, label, width);
  }
  BufStr(b, s->reset);
  room -= width + 2;
  if (notes && room > 0) {
    BufFmt(b, "  %s", s->dim);
    PutFit(b, it->note, room);
    BufStr(b, s->reset);
  }
}

// Draws the list.
static void Draw(List* l) {
  const Style* s = &g_style;
  int cols = TermCols() - 1, vis = Visible(l), lines = 1, col;
  Buf b = {0};
  if (l->cur < l->top) l->top = l->cur;
  if (l->cur >= l->top + vis) l->top = l->cur - vis + 1;
  col = PutTitle(&b, l->o->title, cols / 2);
  if (l->o->filter && l->filter.len) {
    PutFit(&b, l->filter.s, cols - col);
    col +=
        TextWidth(l->filter.s, TextFit(l->filter.s, l->filter.len, cols - col));
  } else if (cols >= 50) {
    const char* hint =
        l->multi ? (s->utf8 ? "↑↓ move · Space on/off · Enter done · Esc back"
                            : "up/down move, Space on/off, Enter done")
        : l->o->filter ? (s->utf8 ? "type to filter · ↑↓ move · Enter choose"
                                  : "type to filter, Enter choose")
                       : (s->utf8 ? "↑↓ move · Enter choose · Esc back"
                                  : "up/down move, Enter choose, Esc back");
    BufStr(&b, s->dim);
    PutFit(&b, hint, cols - col);
    BufStr(&b, s->reset);
  }
  if (l->top > 0) PutMore(&b, s->up, l->top, cols), lines++;
  for (int i = l->top; i < l->top + vis && i < l->n_shown; i++, lines++)
    PutItem(l, &b, i, cols);
  if (l->top + vis < l->n_shown)
    PutMore(&b, s->down, l->n_shown - l->top - vis, cols), lines++;
  if (!l->n_shown) {
    BufFmt(&b, "\r\n  %s", s->dim);
    PutFit(&b,
           l->o->custom ? "no match; Enter uses what you typed" : "no match",
           cols - 2);
    BufStr(&b, s->reset);
    lines++;
  }
  if (l->warn) {
    char text[64];
    snprintf(text, sizeof(text), "choose at least %d", l->o->min);
    BufFmt(&b, "\r\n  %s", s->red);
    PutFit(&b, text, cols - 2);
    BufStr(&b, s->reset);
    lines++;
  }
  TermDraw(&b, lines, l->o->filter ? 0 : -1, col);
  free(b.s);
}

// Moves the cursor by `delta` rows, skipping nothing; `wrap` wraps around.
static void Move(List* l, int delta, int wrap) {
  if (!l->n_shown) return;
  int to = l->cur + delta;
  if (wrap) to = (to % l->n_shown + l->n_shown) % l->n_shown;
  if (to < 0) to = 0;
  if (to >= l->n_shown) to = l->n_shown - 1;
  l->cur = to;
}

// Deletes the last word of the filter.
static void DeleteWord(Buf* b) {
  while (b->len && b->s[b->len - 1] == ' ') BufPop(b);
  while (b->len && b->s[b->len - 1] != ' ') BufPop(b);
}

// Finishes a list: the answered line, the restore, the answer on stdout.
static int Answer(List* l) {
  Buf labels = {0}, out = {0};
  const char* sep = "";
  if (!l->multi && l->n_shown) {
    const Item* it = &l->items[l->shown[l->cur]];
    BufStr(&labels, it->label);
    BufFmt(&out, "%s\n", it->value);
  } else if (!l->multi) {
    BufStr(&labels, l->filter.s);
    BufFmt(&out, "%s\n", l->filter.s);
  }
  for (int i = 0; l->multi && i < l->n; i++) {
    if (!l->items[i].checked) continue;
    BufFmt(&labels, "%s%s", sep, l->items[i].label);
    BufFmt(&out, "%s\n", l->items[i].value);
    sep = ", ";
  }
  if (l->o->quiet) {
    TermClear();
  } else {
    TermDone(l->o->title, labels.len ? labels.s : "none");
  }
  TermRestore();
  if (out.len) fwrite(out.s, 1, out.len, stdout);
  free(labels.s);
  free(out.s);
  return kAnswered;
}

// Handles Enter. Returns 1 when the list is answered.
static int Enter(List* l) {
  if (l->multi) {
    int on = 0;
    for (int i = 0; i < l->n; i++) on += l->items[i].checked;
    l->warn = on < l->o->min;
    return !l->warn;
  }
  if (!l->n_shown) return l->o->custom && l->filter.len;
  return !l->items[l->shown[l->cur]].off;
}

// Runs the list; see pick.h.
int RunList(const Opts* o, Item* items, int n, int multi) {
  List l = {.o = o, .items = items, .n = n, .multi = multi};
  l.shown = malloc(sizeof(int) * (size_t)(n ? n : 1));
  Buf text = {0};
  if (!l.shown) return kUsage;
  BufStr(&l.filter, "");
  for (int i = 0; i < n; i++) {
    int w = TextWidth(items[i].label, strlen(items[i].label));
    if (w > l.label_width) l.label_width = w;
  }
  if (l.label_width > (TermCols() - 1) / 2)
    l.label_width = (TermCols() - 1) / 2;
  Refilter(&l);
  for (int i = 0; o->def && i < l.n_shown; i++) {
    if (!strcmp(items[l.shown[i]].value, o->def) && !items[l.shown[i]].off)
      l.cur = i;
  }
  TermRaw(0);
  int code = -1;
  while (code < 0) {
    Draw(&l);
    Key k = TermKey(&text);
    int vis = Visible(&l);
    if (k == kKeyText && !o->filter && !strcmp(text.s, "j")) k = kKeyDown;
    if (k == kKeyText && !o->filter && !strcmp(text.s, "k")) k = kKeyUp;
    if (k == kKeyText && !o->filter && !strcmp(text.s, "q")) k = kKeyEsc;
    if (k == kKeyText && multi && !strcmp(text.s, " ")) {
      Item* it = l.n_shown ? &items[l.shown[l.cur]] : NULL;
      if (it && !it->off) it->checked = !it->checked;
      l.warn = 0;
      continue;
    }
    switch (k) {
      case kKeyUp:
        Move(&l, -1, 1);
        break;
      case kKeyDown:
        Move(&l, 1, 1);
        break;
      case kKeyPgUp:
        Move(&l, -vis, 0);
        break;
      case kKeyPgDn:
        Move(&l, vis, 0);
        break;
      case kKeyHome:
        Move(&l, -l.n_shown, 0);
        break;
      case kKeyEnd:
        Move(&l, l.n_shown, 0);
        break;
      case kKeyEnter:
        if (Enter(&l)) code = Answer(&l);
        break;
      case kKeyEsc:
        code = kBack;
        break;
      case kKeyCtrlC:
      case kKeyEof:
        code = kCancel;
        break;
      case kKeyText:
      case kKeyPaste:
        if (o->filter) BufStr(&l.filter, text.s), Refilter(&l);
        break;
      case kKeyBackspace:
        BufPop(&l.filter), Refilter(&l);
        break;
      case kKeyCtrlU:
        l.filter.len = 0, l.filter.s[0] = 0, Refilter(&l);
        break;
      case kKeyCtrlW:
        DeleteWord(&l.filter), Refilter(&l);
        break;
      default:
        break;
    }
  }
  if (code != kAnswered) {
    TermClear();
    TermRestore();
  }
  free(text.s);
  free(l.filter.s);
  free(l.shown);
  return code;
}
