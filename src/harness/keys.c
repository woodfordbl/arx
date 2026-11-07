// keys.c: the keys of a tool call. A key works as a lock: calls that share
// a key run one at a time, "*" runs alone, and [] runs with anything. A
// tool declares key templates in its schema, filled in from the arguments
// of each call.

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// True when `keys` is an array of strings; see harness.h.
int KeysValid(cJSON* keys) {
  if (!cJSON_IsArray(keys)) return 0;
  cJSON* k;
  cJSON_ArrayForEach(k, keys) {
    if (!cJSON_IsString(k)) return 0;
  }
  return 1;
}

// Appends the host of a URL (or of a bare host name): no scheme, user,
// port or path, in lower case.
static void AppendHost(Buffer* b, const char* url) {
  const char* p = strstr(url, "://");
  p = p ? p + 3 : url;
  size_t end = strcspn(p, "/?#");
  const char* at = memchr(p, '@', end);
  if (at) {
    end -= (size_t)(at + 1 - p);
    p = at + 1;
  }
  size_t n = end;
  if (*p == '[') {  // an IPv6 address keeps its brackets
    const char* close = memchr(p, ']', end);
    if (close) n = (size_t)(close - p) + 1;
  } else {
    const char* colon = memchr(p, ':', end);
    if (colon) n = (size_t)(colon - p);
  }
  for (size_t i = 0; i < n; i++) {
    char c = (char)tolower((unsigned char)p[i]);
    BufferAppend(b, &c, 1);
  }
}

// Appends the value of the argument `name` (`len` bytes) as text.
static void AppendArg(Buffer* b, cJSON* args, const char* name, size_t len,
                      int host) {
  char* key = XStrndup(name, len);
  cJSON* v = cJSON_GetObjectItemCaseSensitive(args, key);
  free(key);
  char* text = cJSON_IsString(v) ? XStrdup(v->valuestring)
               : v               ? cJSON_PrintUnformatted(v)
                                 : XStrdup("");
  if (host) {
    AppendHost(b, text);
  } else {
    BufferAppendStr(b, text);
  }
  free(text);
}

// Fills in one key template.
static char* Expand(const char* tmpl, cJSON* args) {
  int host = !strncmp(tmpl, "host:", 5);
  Buffer b = {0};
  BufferAppendStr(&b, "");
  for (const char* p = tmpl; *p;) {
    const char* open = strchr(p, '{');
    const char* close = open ? strchr(open, '}') : NULL;
    if (!close) {
      BufferAppendStr(&b, p);
      break;
    }
    BufferAppend(&b, p, (size_t)(open - p));
    AppendArg(&b, args, open + 1, (size_t)(close - open - 1), host);
    p = close + 1;
  }
  return BufferTake(&b);
}

// The keys of one call; see harness.h.
cJSON* KeysFor(const Tool* tool, cJSON* args) {
  cJSON* keys = cJSON_CreateArray();
  if (tool && !tool->keys) {
    cJSON_AddItemToArray(keys, cJSON_CreateString("*"));
  } else if (tool) {
    cJSON* t;
    cJSON_ArrayForEach(t, tool->keys) {
      char* key = Expand(t->valuestring, args);
      cJSON_AddItemToArray(keys, cJSON_CreateString(key));
      free(key);
    }
  }
  return keys;
}

// True when the list has the key "*".
static int HasStar(cJSON* keys) {
  cJSON* k;
  cJSON_ArrayForEach(k, keys) {
    if (!strcmp(k->valuestring, "*")) return 1;
  }
  return 0;
}

// True when the calls may not run together; see harness.h.
int KeysConflict(cJSON* a, cJSON* b) {
  if (HasStar(a) || HasStar(b)) return 1;
  cJSON *x, *y;
  cJSON_ArrayForEach(x, a) {
    cJSON_ArrayForEach(y, b) {
      if (!strcmp(x->valuestring, y->valuestring)) return 1;
    }
  }
  return 0;
}
