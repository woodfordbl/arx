// search.c: what mcp_search and mcp_select do. The search is a lexical
// BM25F score over the catalog, computed on each call with no index: 2,000
// tools take about a millisecond. A tool is a document with weighted
// fields: its own name x3, its title x2, the server's name x2, the
// server's description, the tool's description and the argument names x1,
// and the argument descriptions x0.5.

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "src/agent/agent.h"
#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/mcp/mcp.h"

#define MAX_QUERY 16

static const double kK1 = 1.2, kB = 0.75;
static const char* const kStopwords[] = {
    "a",   "an", "the",  "to", "of",   "for", "in", "on",
    "and", "or", "with", "by", "from", "is",  "it", NULL};

// The tokens of a query, each once.
typedef struct Query {
  char token[MAX_QUERY][32];
  int n;
} Query;

// What one document has of the query's tokens.
typedef struct Match {
  const Query* query;
  double weight;          // of the field being read
  double tf[MAX_QUERY];   // weighted count of each token
  double pre[MAX_QUERY];  // the same for tokens it only starts
  double len;             // weighted length
} Match;

// One ranked tool.
typedef struct Hit {
  McpServer* server;
  McpTool* tool;
  Match match;
  double score;
  int order;
} Hit;

// Cuts a plural or verb ending off a word of more than 4 letters.
static void Stem(char* w) {
  size_t n = strlen(w);
  if (n <= 4) return;
  if (!strcmp(w + n - 3, "ies")) {
    memcpy(w + n - 3, "y", 2);
  } else if (!strcmp(w + n - 2, "es") && strchr("sxzh", w[n - 3])) {
    w[n - 2] = 0;
  } else if (w[n - 1] == 's' && w[n - 2] != 's') {
    w[n - 1] = 0;
  } else if (!strcmp(w + n - 3, "ing")) {
    w[n - 3] = 0;
  } else if (!strcmp(w + n - 2, "ed")) {
    w[n - 2] = 0;
  }
}

// Calls `emit` for each token of `text`: lower case, split at anything
// that is not a letter or digit and at camelCase and digit boundaries,
// without stopwords, and stemmed.
static void Tokens(const char* text, void (*emit)(void*, const char*),
                   void* ctx) {
  char word[32];
  size_t n = 0;
  for (const unsigned char* p = (const unsigned char*)text;; p++) {
    int c = *p, alnum = c < 128 && isalnum(c), split = !alnum;
    if (alnum && n) {
      int prev = p[-1];
      split = (isdigit(c) != 0) != (isdigit(prev) != 0) ||
              (isupper(c) && islower(prev)) ||
              (isupper(c) && isupper(prev) && islower(p[1]));
    }
    if (split && n) {
      word[n] = 0;
      n = 0;
      int stop = 0;
      for (const char* const* s = kStopwords; *s; s++)
        stop |= !strcmp(*s, word);
      Stem(word);
      if (!stop) emit(ctx, word);
    }
    if (alnum && n < sizeof(word) - 1) word[n++] = (char)tolower(c);
    if (!c) break;
  }
}

// Token callback: adds a query token, once.
static void AddQueryToken(void* ctx, const char* word) {
  Query* q = ctx;
  for (int i = 0; i < q->n; i++) {
    if (!strcmp(q->token[i], word)) return;
  }
  if (q->n < MAX_QUERY) {
    snprintf(q->token[q->n++], sizeof(q->token[0]), "%s", word);
  }
}

// Token callback: counts a document token against the query.
static void CountToken(void* ctx, const char* word) {
  Match* m = ctx;
  m->len += m->weight;
  for (int i = 0; i < m->query->n; i++) {
    const char* t = m->query->token[i];
    size_t n = strlen(t);
    if (!strcmp(t, word)) {
      m->tf[i] += m->weight;
    } else if (n >= 3 && !strncmp(t, word, n)) {
      m->pre[i] += m->weight;
    }
  }
}

// Reads one field of a document.
static void ReadField(Match* m, double weight, const char* text) {
  m->weight = weight;
  if (text) Tokens(text, CountToken, m);
}

// Reads the document of one tool.
static void ReadTool(Match* m, const McpServer* s, const char* about,
                     const McpTool* tool) {
  cJSON* def = tool->def;
  ReadField(m, 3, JsonStr(def, "name", NULL));
  ReadField(m, 2, JsonStr(def, "title", NULL));
  ReadField(m, 2, s->name);
  ReadField(m, 1, about);
  ReadField(m, 1, JsonStr(def, "description", NULL));
  cJSON* arg;
  cJSON_ArrayForEach(arg, JsonGet(def, "inputSchema.properties")) {
    ReadField(m, 1, arg->string);
    ReadField(m, 0.5, JsonStr(arg, "description", NULL));
  }
}

// qsort comparator: the best score first, then the catalog's order.
static int CompareHits(const void* a, const void* b) {
  const Hit *x = a, *y = b;
  if (x->score != y->score) return x->score < y->score ? 1 : -1;
  return x->order - y->order;
}

// Ranks the catalog (of one server, when `server` is not NULL) for
// `query`. Returns the tools with a score above 0, the best first, in
// `*hits` (free it), and sets `*total` to the number of tools searched.
static int Rank(const char* query, const char* server, Hit** hits, int* total) {
  Query q = {.n = 0};
  Tokens(query, AddQueryToken, &q);
  int n = 0, cap = 0, df[MAX_QUERY] = {0};
  double length = 0;
  Hit* all = NULL;
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    if (server && *server && strcmp(server, s->name)) continue;
    char* about = McpServerAbout(s);
    for (int t = 0; t < s->tool_count; t++) {
      if (n == cap) all = XRealloc(all, (size_t)(cap += 64) * sizeof(*all));
      Hit* h = &all[n];
      memset(h, 0, sizeof(*h));
      h->server = s;
      h->tool = &s->tools[t];
      h->order = n++;
      h->match.query = &q;
      ReadTool(&h->match, s, about, h->tool);
      length += h->match.len;
      for (int k = 0; k < q.n; k++) {
        df[k] += h->match.tf[k] > 0 || h->match.pre[k] > 0;
      }
    }
    free(about);
  }
  *total = n;
  double average = n ? length / n : 1;
  int found = 0;
  for (int i = 0; i < n; i++) {
    Hit* h = &all[i];
    int matched = 0;
    for (int k = 0; k < q.n; k++) {
      // A token the document only starts counts at half weight.
      double half = h->match.tf[k] > 0 ? 1 : 0.5;
      double tf = h->match.tf[k] > 0 ? h->match.tf[k] : h->match.pre[k];
      if (tf <= 0) continue;
      double idf = log(1 + (n - df[k] + 0.5) / (df[k] + 0.5));
      double norm = 1 - kB + kB * h->match.len / (average > 0 ? average : 1);
      h->score += half * idf * tf * (kK1 + 1) / (tf + kK1 * norm);
      matched++;
    }
    if (q.n) h->score *= 1 + (double)matched / q.n;
    if (!strcasecmp(query, h->tool->name) ||
        !strcasecmp(query, JsonStr(h->tool->def, "name", ""))) {
      h->score = 1e9;  // the exact name ranks first
    }
    found += h->score > 0;
  }
  if (n) qsort(all, (size_t)n, sizeof(*all), CompareHits);
  *hits = all;
  return found;
}

// True when the tool is in the tool set now: selected or preloaded.
static int InToolSet(const struct Agent* a, const char* name) {
  for (int i = 0; i < a->tools.count; i++) {
    const Tool* t = &a->tools.items[i];
    if (t->kind == kToolMcp && !strcmp(t->name, name)) return 1;
  }
  return 0;
}

// Appends the first sentence of `text`, at most 160 bytes.
static void AppendSentence(Buffer* out, const char* text) {
  size_t n = strcspn(text, "\n");
  const char* stop = strstr(text, ". ");
  if (stop && (size_t)(stop - text) < n) n = (size_t)(stop - text) + 1;
  char* sentence = XStrndup(text, n);
  char* cut = Truncate(sentence, 160);
  BufferAppendStr(out, cut);
  free(cut);
  free(sentence);
}

// Appends one result line: name, first sentence, arguments.
static void AppendHit(const struct Agent* a, Buffer* out, const Hit* h) {
  cJSON* schema = JsonGet(h->tool->def, "inputSchema");
  cJSON* required = JsonGet(schema, "required");
  BufferPrintf(out, "%s: ", h->tool->name);
  AppendSentence(out, JsonStr(h->tool->def, "description", ""));
  BufferAppendStr(out, " (");
  int shown = 0;
  cJSON* arg;
  cJSON_ArrayForEach(arg, JsonGet(schema, "properties")) {
    if (shown == 6) {
      BufferAppendStr(out, ", …");
      break;
    }
    int needed = 0;
    cJSON* r;
    cJSON_ArrayForEach(r, required) {
      needed |= cJSON_IsString(r) && !strcmp(r->valuestring, arg->string);
    }
    BufferPrintf(out, "%s%s%s", shown++ ? ", " : "", arg->string,
                 needed ? "" : "?");
  }
  BufferPrintf(out, ")%s\n", InToolSet(a, h->tool->name) ? " [selected]" : "");
}

// Appends each server with its description and tool count.
static void AppendServers(Buffer* out) {
  for (int i = 0; i < McpServerCount(); i++) {
    McpServer* s = McpServerAt(i);
    char* about = McpServerAbout(s);
    BufferPrintf(out, "%s: %s%s", s->name, about, *about ? " (" : "");
    if (s->error) {
      BufferPrintf(out, "failed: %s", s->error);
    } else if (s->cache) {
      BufferPrintf(out, "%d tools", s->tool_count);
    } else {
      BufferAppendStr(out, "not listed yet");
    }
    BufferPrintf(out, "%s\n", *about ? ")" : "");
    free(about);
  }
  BufferAppendStr(out, "Search with words for the action you need.\n");
}

// What mcp_search prints; see mcp.h.
void McpSearchText(const struct Agent* a, const char* query, const char* server,
                   int limit, Buffer* out) {
  if (limit <= 0) limit = 8;
  if (limit > 25) limit = 25;
  if (!query || !query[strspn(query, " \t\n")]) {
    AppendServers(out);
    return;
  }
  if (server && *server && !McpServerFind(server)) {
    BufferPrintf(out, "No MCP server is called \"%s\". The servers:\n", server);
    AppendServers(out);
    return;
  }
  Hit* hits = NULL;
  int total = 0, found = Rank(query, server, &hits, &total);
  if (!found) {
    BufferPrintf(out,
                 "No tool of %d matches \"%s\". Try other words, or an empty "
                 "query to list the servers.\n",
                 total, query);
  } else {
    BufferPrintf(out, "%d of %d tools match \"%s\"", found, total, query);
    if (found > limit) BufferPrintf(out, "; the best %d", limit);
    BufferAppendStr(out, ":\n");
    for (int i = 0; i < found && i < limit; i++) AppendHit(a, out, &hits[i]);
    BufferAppendStr(out, "Call mcp_select with the names you want.\n");
  }
  free(hits);
}

// Appends the 3 names closest to `name`.
static void AppendClosest(Buffer* out, const char* name) {
  Hit* hits = NULL;
  int total = 0, found = Rank(name, NULL, &hits, &total);
  for (int i = 0; i < found && i < 3; i++) {
    BufferPrintf(out, "%s%s", i ? ", " : " Closest: ", hits[i].tool->name);
  }
  if (found) BufferAppendStr(out, ".");
  free(hits);
}

// Appends " a, b" for the string array `names` after `label`, if any.
static void AppendNames(Buffer* out, const char* label, cJSON* names) {
  cJSON* n;
  cJSON_ArrayForEach(n, names) {
    BufferPrintf(out, "%s%s", n == names->child ? label : ", ", n->valuestring);
  }
  if (cJSON_GetArraySize(names)) BufferAppendStr(out, ". ");
}

// True when the string array has `name`.
static int Has(cJSON* list, const char* name) {
  cJSON* n;
  cJSON_ArrayForEach(n, list) {
    if (cJSON_IsString(n) && !strcmp(n->valuestring, name)) return 1;
  }
  return 0;
}

// What mcp_select does; see mcp.h.
char* McpSelectApply(struct Agent* a, cJSON* names, cJSON* drop,
                     int* is_error) {
  cJSON* next = cJSON_CreateArray();
  cJSON* added = cJSON_CreateArray();
  cJSON* dropped = cJSON_CreateArray();
  Buffer out = {0}, unknown = {0};
  cJSON* n;
  cJSON_ArrayForEach(n, McpSelection()) {
    if (Has(drop, n->valuestring)) {
      cJSON_AddItemToArray(dropped, cJSON_Duplicate(n, 1));
    } else {
      cJSON_AddItemToArray(next, cJSON_Duplicate(n, 1));
    }
  }
  cJSON_ArrayForEach(n, names) {
    if (!cJSON_IsString(n) || Has(next, n->valuestring)) continue;
    if (!McpFindTool(n->valuestring, NULL)) {
      BufferPrintf(&unknown, "No MCP tool is called \"%s\".", n->valuestring);
      AppendClosest(&unknown, n->valuestring);
      BufferAppendStr(&unknown, " ");
    } else if (!InToolSet(a, n->valuestring)) {  // preloaded tools stay as is
      cJSON_AddItemToArray(next, cJSON_Duplicate(n, 1));
      cJSON_AddItemToArray(added, cJSON_Duplicate(n, 1));
    }
  }
  int count = cJSON_GetArraySize(next);
  *is_error = unknown.len > 0 || count > MCP_MAX_SELECTED;
  if (count > MCP_MAX_SELECTED) {
    BufferPrintf(&out,
                 "At most %d MCP tools are selected at once, and this makes "
                 "%d. Nothing changed. Drop some with `drop` first",
                 MCP_MAX_SELECTED, count);
    AppendNames(&out, ". Selected now: ", McpSelection());
    cJSON_Delete(next);
  } else {
    AppendNames(&out, "Selected ", added);
    AppendNames(&out, "Dropped ", dropped);
    if (unknown.len) BufferAppendStr(&out, unknown.data);
    BufferPrintf(&out, "%d MCP tool%s selected.", count,
                 count == 1 ? " is" : "s are");
    if (cJSON_GetArraySize(added)) {
      BufferAppendStr(&out,
                      " Their schemas are in your tools from your "
                      "next turn.");
    }
    McpSelectionSet(a, next);
  }
  cJSON_Delete(added);
  cJSON_Delete(dropped);
  BufferFree(&unknown);
  return BufferTake(&out);
}
