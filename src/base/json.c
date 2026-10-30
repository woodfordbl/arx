// json.c: dotted-path lookups and scalar parsing on top of cJSON.

#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"

// Copies the next path segment of `dotted` into `key` and returns a pointer
// to the rest of the path (or NULL at the end). Returns `dotted` unchanged
// when the segment does not fit.
static const char* NextKey(const char* dotted, char* key, size_t size) {
  const char* dot = strchr(dotted, '.');
  size_t n = dot ? (size_t)(dot - dotted) : strlen(dotted);
  if (n >= size) return dotted;
  memcpy(key, dotted, n);
  key[n] = 0;
  return dot ? dot + 1 : NULL;
}

// Walks the dotted path one object at a time.
cJSON* JsonGet(cJSON* o, const char* dotted) {
  char key[128];
  while (o && dotted && *dotted) {
    const char* rest = NextKey(dotted, key, sizeof(key));
    if (rest == dotted) return NULL;
    o = cJSON_IsObject(o) ? cJSON_GetObjectItemCaseSensitive(o, key) : NULL;
    dotted = rest;
  }
  return o;
}

// String lookup with a default.
const char* JsonStr(cJSON* o, const char* dotted, const char* def) {
  cJSON* v = JsonGet(o, dotted);
  return cJSON_IsString(v) ? v->valuestring : def;
}

// Number lookup with a default.
double JsonNum(cJSON* o, const char* dotted, double def) {
  cJSON* v = JsonGet(o, dotted);
  return cJSON_IsNumber(v) ? v->valuedouble : def;
}

// Boolean lookup with a default.
int JsonBool(cJSON* o, const char* dotted, int def) {
  cJSON* v = JsonGet(o, dotted);
  return cJSON_IsBool(v) ? cJSON_IsTrue(v) : def;
}

// Duration lookup: numbers are seconds, strings take a suffix.
double JsonDuration(cJSON* o, const char* dotted, double def) {
  cJSON* v = JsonGet(o, dotted);
  double secs;
  if (cJSON_IsNumber(v)) return v->valuedouble;
  if (cJSON_IsString(v) && ParseDuration(v->valuestring, &secs) == 0) {
    return secs;
  }
  return def;
}

// Size lookup: numbers are bytes, strings take a suffix.
size_t JsonSize(cJSON* o, const char* dotted, size_t def) {
  cJSON* v = JsonGet(o, dotted);
  size_t bytes;
  if (cJSON_IsNumber(v) && v->valuedouble >= 0) return (size_t)v->valuedouble;
  if (cJSON_IsString(v) && ParseSize(v->valuestring, &bytes) == 0) {
    return bytes;
  }
  return def;
}

// Creates intermediate objects as needed and replaces the final key.
void JsonSet(cJSON* o, const char* dotted, cJSON* value) {
  char key[128];
  for (;;) {
    const char* rest = NextKey(dotted, key, sizeof(key));
    if (rest == dotted) {
      cJSON_Delete(value);
      return;
    }
    if (!rest) {
      cJSON_DeleteItemFromObjectCaseSensitive(o, key);
      cJSON_AddItemToObject(o, key, value);
      return;
    }
    cJSON* child = cJSON_GetObjectItemCaseSensitive(o, key);
    if (!cJSON_IsObject(child)) {
      cJSON_DeleteItemFromObjectCaseSensitive(o, key);
      child = cJSON_AddObjectToObject(o, key);
    }
    o = child;
    dotted = rest;
  }
}

// Plain YAML scalars become typed values; quoted ones stay strings. Only
// decimal numbers count, so "0x10", "inf" and "1e" stay strings.
cJSON* JsonScalar(const char* text, int plain) {
  if (plain) {
    if (!strcmp(text, "true")) return cJSON_CreateTrue();
    if (!strcmp(text, "false")) return cJSON_CreateFalse();
    if (!*text || !strcmp(text, "null") || !strcmp(text, "~")) {
      return cJSON_CreateNull();
    }
    char* end;
    double d = strtod(text, &end);
    if (!*end && strspn(text, "0123456789+-.eE") == strlen(text)) {
      return cJSON_CreateNumber(d);
    }
  }
  return cJSON_CreateString(text);
}

// Adds a string field, cut to `max` bytes.
void JsonAddTruncated(cJSON* o, const char* key, const char* s, size_t max) {
  char* cut = Truncate(s ? s : "", max);
  cJSON_AddStringToObject(o, key, cut);
  free(cut);
}
