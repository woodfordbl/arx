// fields.c: the field tables of agent.yaml, plugin.yaml and kit.yaml. One
// table drives validation (validate.c) and the JSON Schema (schema.c), so
// adding a key here adds it to both.

#include <stddef.h>

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
