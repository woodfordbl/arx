// validate.c: the agent.yaml field table, and validation against it. One
// table drives validation (with line numbers and "did you mean" hints, so an
// agent editing its own spec can fix it from the message alone) and the JSON
// Schema in schema.c. Adding a key to the table adds it to both.

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

const char* const kHookPoints[] = {"session_start", "before_tool", "after_tool",
                                   "stop", NULL};
const char kNameChars[] =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
static const char* const kStrategies[] = {"mask", "summarize", "hybrid",
                                          "restart", NULL};
static const char* const kTemplateVars[] = {
    "prompt", "harness", "skills", "date", "cwd", "session", "turn", NULL};

static const Field kEndpoint[] = {
    {"base_url", kString, NULL, "OpenAI-compatible base URL"},
    {"api_key_env", kString, NULL, "Env var with the API key (OPENAI_API_KEY)"},
    {"headers", kAnyMap, NULL, "Extra HTTP headers"},
    {"curl", kString, NULL, "curl executable (default: $ARX_CURL or curl)"},
    {"retry_base", kDuration, NULL, "First retry delay (default 2s)"},
    {"retry_max", kDuration, NULL, "Longest retry delay (default 5m)"},
    {"retry_attempts", kInteger, NULL, "Give up after this many (0 = never)"},
    {NULL, 0, NULL, NULL}};

static const Field kTool[] = {
    {"timeout", kDuration, NULL, "Seconds or 10s/5m/1h"},
    {"agent", kString, NULL, "Spec path: makes this tool a subagent"},
    {"description", kString, NULL, "Description shown to the model"},
    {"enabled", kBoolean, NULL, "false hides the tool"},
    {NULL, 0, NULL, NULL}};

static const Field kToolOutput[] = {
    {"head", kSize, NULL, "Bytes kept from the start of output (2kb)"},
    {"tail", kSize, NULL, "Bytes kept from the end of output (6kb)"},
    {NULL, 0, NULL, NULL}};

static const Field kHook[] = {
    {"timeout", kDuration, NULL, "Default 10s"},
    {"fail", kString, NULL, "open (ignore failures) or closed"},
    {NULL, 0, NULL, NULL}};

static const Field kCompaction[] = {
    {"strategy", kString, NULL, "mask, summarize, hybrid, restart or a path"},
    {"trigger", kNumber, NULL, "Fraction of context_window (default 0.7)"},
    {"keep", kInteger, NULL, "Recent outputs or turns kept intact (5)"},
    {"exclude_tools", kStringList, NULL, "Tools whose outputs stay"},
    {"clear_inputs", kBoolean, NULL, "Also clear old tool-call arguments"},
    {"prompt", kText, NULL, "Instructions for summarize"},
    {NULL, 0, NULL, NULL}};

static const Field kLimits[] = {
    {"max_turns", kInteger, NULL, "Model calls per session (200)"},
    {"turn_timeout", kDuration, NULL, "Longest single model call (10m)"},
    {NULL, 0, NULL, NULL}};

static const Field kPrices[] = {
    {"input", kNumber, NULL, "USD per 1M input tokens"},
    {"output", kNumber, NULL, "USD per 1M output tokens"},
    {NULL, 0, NULL, NULL}};

const Field kTopFields[] = {
    {"name", kString, NULL, "Agent name"},
    {"model", kString, NULL, "Model id your endpoint accepts"},
    {"endpoint", kMap, kEndpoint, "Where requests go"},
    {"model_settings", kAnyMap, NULL, "Extra request fields; null removes"},
    {"context_window", kInteger, NULL, "Context size in tokens (128000)"},
    {"instructions", kTextList, NULL, "System prompt; {{vars}} allowed"},
    {"first_message", kText, NULL,
     "First user message; {{prompt}} is the task"},
    {"tools", kDict, kTool, "Options per tool, or subagent tools"},
    {"tool_output", kMap, kToolOutput, "How much tool output the model sees"},
    {"hooks", kDict, kHook, "Options per hook point (hooks/<point>)"},
    {"compaction", kMap, kCompaction, "How the context stays in the window"},
    {"skills", kString, NULL, "Directory of <name>/SKILL.md files"},
    {"limits", kMap, kLimits, "Per-session limits"},
    {"observers", kStringList, NULL, "Commands fed the event stream on stdin"},
    {"prices", kMap, kPrices, "Token prices for cost tracking"},
    {NULL, 0, NULL, NULL}};

// Edit distance between two short strings, for "did you mean" hints.
static int EditDistance(const char* a, const char* b) {
  size_t n = strlen(a), m = strlen(b);
  int d[33][33];
  if (n > 32 || m > 32) return 99;
  for (size_t i = 0; i <= n; i++) d[i][0] = (int)i;
  for (size_t j = 0; j <= m; j++) d[0][j] = (int)j;
  for (size_t i = 1; i <= n; i++) {
    for (size_t j = 1; j <= m; j++) {
      int best = d[i - 1][j - 1] + (a[i - 1] != b[j - 1]);
      if (d[i - 1][j] + 1 < best) best = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < best) best = d[i][j - 1] + 1;
      d[i][j] = best;
    }
  }
  return d[n][m];
}

// Appends "file:line: path: message" for the key at `path`.
static void Problem(const Spec* spec, Buffer* err, const char* path,
                    const char* fmt, ...) {
  cJSON* line = cJSON_GetObjectItemCaseSensitive(spec->lines, path);
  if (cJSON_IsNumber(line)) {
    BufferPrintf(err, "%s:%d: %s: ", spec->path, line->valueint, path);
  } else if (cJSON_IsString(line)) {  // from the user's defaults
    BufferPrintf(err, "%s: %s: ", line->valuestring, path);
  } else {
    BufferPrintf(err, "%s: %s: ", spec->path, path);
  }
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(err, fmt, ap);
  va_end(ap);
  BufferAppendStr(err, "\n");
}

// True for a string or {file: path}.
static int IsText(const cJSON* v) {
  return cJSON_IsString(v) ||
         (cJSON_IsObject(v) && cJSON_GetArraySize(v) == 1 &&
          cJSON_IsString(cJSON_GetObjectItemCaseSensitive(v, "file")));
}

// True when `v` is an array whose items all pass `check`.
static int AllItems(const cJSON* v, int (*check)(const cJSON*)) {
  if (!cJSON_IsArray(v)) return 0;
  for (cJSON* c = v->child; c; c = c->next) {
    if (!check(c)) return 0;
  }
  return 1;
}

// True when `v` has the shape that `type` needs.
static int TypeOk(FieldType type, const cJSON* v) {
  double secs;
  size_t bytes;
  switch (type) {
    case kString:
      return cJSON_IsString(v);
    case kNumber:
      return cJSON_IsNumber(v);
    case kInteger:
      return cJSON_IsNumber(v) &&
             v->valuedouble == (double)(int64_t)v->valuedouble;
    case kBoolean:
      return cJSON_IsBool(v);
    case kDuration:
      return cJSON_IsNumber(v) ||
             (cJSON_IsString(v) && ParseDuration(v->valuestring, &secs) == 0);
    case kSize:
      return cJSON_IsNumber(v) ||
             (cJSON_IsString(v) && ParseSize(v->valuestring, &bytes) == 0);
    case kText:
      return IsText(v);
    case kTextList:
      return IsText(v) || AllItems(v, IsText);
    case kStringList:
      return AllItems(v, cJSON_IsString);
    default:
      return cJSON_IsObject(v);
  }
}

// Describes a type for error messages.
static const char* TypeName(FieldType type) {
  switch (type) {
    case kString:
      return "a string";
    case kNumber:
      return "a number";
    case kInteger:
      return "a whole number";
    case kBoolean:
      return "true or false";
    case kDuration:
      return "a duration (30, 10s, 5m, 1h)";
    case kSize:
      return "a size (2048, 2kb, 1mb)";
    case kText:
      return "text or {file: path}";
    case kTextList:
      return "text, {file: path} or a list of them";
    case kStringList:
      return "a list of strings";
    default:
      return "a mapping";
  }
}

// Reports an unknown key, suggesting the closest known one.
static void UnknownKey(const Spec* spec, Buffer* err, const char* path,
                       const char* key, const Field* fields) {
  const Field* best = NULL;
  int best_distance = 3;
  Buffer known = {0};
  for (const Field* f = fields; f->key; f++) {
    int d = EditDistance(key, f->key);
    if (d < best_distance) {
      best_distance = d;
      best = f;
    }
    BufferPrintf(&known, "%s%s", f == fields ? "" : ", ", f->key);
  }
  if (best) {
    Problem(spec, err, path, "unknown key (did you mean \"%s\"?)", best->key);
  } else {
    Problem(spec, err, path, "unknown key (known: %s)", known.data);
  }
  BufferFree(&known);
}

// Checks the entries of a kDict: each value is a mapping of `fields`.
static void ValidateDict(const Spec* spec, cJSON* dict, const Field* fields,
                         const char* path, Buffer* err);

// Checks every key of `node` against `fields`, recursing into mappings.
static void ValidateNode(const Spec* spec, cJSON* node, const Field* fields,
                         const char* path, Buffer* err) {
  for (cJSON* c = node->child; c; c = c->next) {
    char* child_path =
        *path ? XAsprintf("%s.%s", path, c->string) : XStrdup(c->string);
    const Field* f = fields;
    while (f->key && strcmp(f->key, c->string)) f++;
    if (!f->key) {
      UnknownKey(spec, err, child_path, c->string, fields);
    } else if (!TypeOk(f->type, c)) {
      Problem(spec, err, child_path, "must be %s", TypeName(f->type));
    } else if (f->type == kMap) {
      ValidateNode(spec, c, f->sub, child_path, err);
    } else if (f->type == kDict) {
      ValidateDict(spec, c, f->sub, child_path, err);
    }
    free(child_path);
  }
}

// Each entry is a mapping of options, or empty.
static void ValidateDict(const Spec* spec, cJSON* dict, const Field* fields,
                         const char* path, Buffer* err) {
  for (cJSON* e = dict->child; e; e = e->next) {
    char* entry = XAsprintf("%s.%s", path, e->string);
    if (cJSON_IsObject(e)) {
      ValidateNode(spec, e, fields, entry, err);
    } else if (!cJSON_IsNull(e)) {
      Problem(spec, err, entry, "must be a mapping of options (or empty)");
    }
    free(entry);
  }
}

// True when `s` is in the NULL-terminated list.
static int InList(const char* const* list, const char* s) {
  for (; *list; list++) {
    if (!strcmp(*list, s)) return 1;
  }
  return 0;
}

// Reports {{names}} in `text` that are not template variables.
static void CheckTemplate(const Spec* spec, const char* where, const char* text,
                          Buffer* err) {
  for (const char* p = text; (p = strstr(p, "{{"));) {
    const char* close = strstr(p + 2, "}}");
    if (!close) break;
    char* name = XStrndup(p + 2, (size_t)(close - p - 2));
    char* start = name + strspn(name, " ");
    char* end = start + strlen(start);
    while (end > start && end[-1] == ' ') *--end = 0;
    if (!InList(kTemplateVars, start) && strncmp(start, "file:", 5)) {
      Problem(spec, err, where,
              "unknown template variable {{%s}} (known: prompt, harness, "
              "skills, date, cwd, session, turn, file:PATH)",
              start);
    }
    free(name);
    p = close + 2;
  }
}

// Checks the names of hook points and tools.
static void ValidateNames(const Spec* spec, Buffer* err) {
  cJSON* c;
  cJSON_ArrayForEach(c, JsonGet(spec->root, "hooks")) {
    if (InList(kHookPoints, c->string)) continue;
    char* path = XAsprintf("hooks.%s", c->string);
    Problem(spec, err, path,
            "unknown hook point (known: session_start, before_tool, "
            "after_tool, stop)");
    free(path);
  }
  cJSON_ArrayForEach(c, JsonGet(spec->root, "tools")) {
    size_t len = strlen(c->string);
    if (len && len <= 64 && strspn(c->string, kNameChars) == len) continue;
    char* path = XAsprintf("tools.%s", c->string);
    Problem(spec, err, path,
            "tool names use letters, digits, _ and - (64 max)");
    free(path);
  }
}

// Rules the table cannot express: required keys, ranges and templates.
static void ValidateRules(const Spec* spec, Buffer* err) {
  cJSON* root = spec->root;
  if (!JsonStr(root, "model", NULL)) Problem(spec, err, "model", "required");
  if (!JsonStr(root, "endpoint.base_url", NULL)) {
    Problem(spec, err, "endpoint.base_url", "required");
  }
  const char* strategy = JsonStr(root, "compaction.strategy", NULL);
  if (strategy && !InList(kStrategies, strategy)) {
    char* path = PathJoin(spec->dir, strategy);
    if (access(path, X_OK)) {
      Problem(spec, err, "compaction.strategy",
              "not a built-in strategy, and %s is not executable", path);
    }
    free(path);
  }
  double trigger = JsonNum(root, "compaction.trigger", 0.7);
  if (trigger <= 0 || trigger > 1) {
    Problem(spec, err, "compaction.trigger", "must be between 0 and 1");
  }
  const char* texts[] = {"instructions", "first_message", "compaction.prompt"};
  for (size_t i = 0; i < sizeof(texts) / sizeof(texts[0]); i++) {
    char* text = SpecText(spec, JsonGet(root, texts[i]), err);
    if (text) CheckTemplate(spec, texts[i], text, err);
    free(text);
  }
}

// Validates the whole spec; see harness.h.
void SpecValidate(const Spec* spec, Buffer* err) {
  if (!cJSON_IsObject(spec->root)) {
    BufferPrintf(err, "%s: the spec must be a YAML mapping\n", spec->path);
    return;
  }
  ValidateNode(spec, spec->root, kTopFields, "", err);
  ValidateNames(spec, err);
  ValidateRules(spec, err);
}
