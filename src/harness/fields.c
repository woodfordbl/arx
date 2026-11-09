// fields.c: the field tables of agent.yaml, plugin.yaml and kit.yaml, and
// what each field type accepts. One table drives validation (validate.c) and
// the JSON Schema (schema.c), so adding a key here adds it to both.

#include <stddef.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

const char* const kHookPoints[] = {
    "session_start", "before_model", "after_model", "before_tool",
    "after_tool",    "stop",         NULL};
const char kNameChars[] =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";

static const Field kEndpoint[] = {
    {"base_url", kString, NULL, "OpenAI-compatible base URL"},
    {"api_key_env", kString, NULL, "Env var with the API key (OPENAI_API_KEY)"},
    {"headers", kAnyMap, NULL, "Extra HTTP headers"},
    {"curl", kString, NULL, "curl executable (default: $ARX_CURL or curl)"},
    {"retry_base", kDuration, NULL, "First retry delay (default 2s)"},
    {"retry_max", kDuration, NULL, "Longest retry delay (default 5m)"},
    {"retry_attempts", kInteger, NULL, "Give up after this many (0 = never)"},
    {"credential", kString, NULL,
     "A credentials name or a program path: prints headers and base_url"},
    {"adapter", kString, NULL,
     "An adapters name or a program path: wraps curl to translate calls"},
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
    {"band", kString, NULL, "policy, normal (the default) or final"},
    {"changes", kStringList, NULL, "The fields this hook changes"},
    {NULL, 0, NULL, NULL}};

static const Field kCompaction[] = {
    {"strategy", kString, NULL,
     "mask, summarize, hybrid, restart, a compactors name or a path"},
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
    {"kit", kString, NULL, "The kit: its plugins, in order, and its prompt"},
    {"plugins", kPluginList, NULL,
     "The only plugins to use, in order (default: all installed)"},
    {"enable", kPluginList, NULL, "Plugins to add to the kit or the list"},
    {"disable", kStringList, NULL, "Plugins to leave out"},
    {"compactors", kAnyMap, NULL, "Named compaction programs: name -> path"},
    {"credentials", kAnyMap, NULL, "Named credential programs: name -> path"},
    {"adapters", kAnyMap, NULL, "Named request adapters: name -> path"},
    {"hosts", kStringList, NULL,
     "Network hosts the harness's programs reach, besides the endpoint"},
    {NULL, 0, NULL, NULL}};

const Field kPluginFields[] = {
    {"name", kString, NULL, "Must match the plugin's folder name"},
    {"version", kString, NULL, "The plugin's version"},
    {"description", kString, NULL, "One line about what it adds"},
    {"arx", kString, NULL, "The arx versions it works with, e.g. \">=0.2\""},
    {"requires", kStringList, NULL, "Programs that must be on PATH"},
    {"tools", kDict, kTool, "Options for its tools, or subagent tools"},
    {"hooks", kDict, kHook, "Options for its hooks: band, changes, ..."},
    {"replaces", kStringList, NULL, "Tools it hides on purpose"},
    {"observers", kStringList, NULL, "Commands fed the event stream"},
    {"compactors", kAnyMap, NULL, "Named compaction programs: name -> path"},
    {"credentials", kAnyMap, NULL, "Named credential programs: name -> path"},
    {"adapters", kAnyMap, NULL, "Named request adapters: name -> path"},
    {"hosts", kStringList, NULL, "Network hosts its programs reach"},
    {"instructions", kTextList, NULL, "Text added to the system prompt"},
    {"model_settings", kAnyMap, NULL, "Request fields, below the spec's"},
    {NULL, 0, NULL, NULL}};

const Field kKitFields[] = {
    {"name", kString, NULL, "Must match the kit's folder name"},
    {"version", kString, NULL, "The kit's version"},
    {"description", kString, NULL, "One line about the agent it makes"},
    {"plugins", kPluginList, NULL, "Its plugins, in order: the priority"},
    {"model_settings", kAnyMap, NULL, "Extra request fields"},
    {"prompt", kString, NULL, "The system prompt file, relative to the kit"},
    {"extends", kString, NULL, "A kit this one starts from"},
    {"enable", kPluginList, NULL, "Plugins to add to the kit it extends"},
    {"disable", kStringList, NULL, "Plugins to leave out of it"},
    {NULL, 0, NULL, NULL}};

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

// True for one entry of a plugin list: a name, or {name: {settings}}.
static int IsPluginEntry(const cJSON* v) {
  if (cJSON_IsString(v)) return *v->valuestring != 0;
  return cJSON_IsObject(v) && cJSON_GetArraySize(v) == 1 &&
         (cJSON_IsObject(v->child) || cJSON_IsNull(v->child));
}

// Checks the shape of a value; see harness.h.
int TypeOk(FieldType type, const cJSON* v) {
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
    case kPluginList:
      return AllItems(v, IsPluginEntry);
    default:
      return cJSON_IsObject(v);
  }
}

// Names a type for messages; see harness.h.
const char* TypeName(FieldType type) {
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
    case kPluginList:
      return "a list of plugin names or {name: {settings}}";
    default:
      return "a mapping";
  }
}
