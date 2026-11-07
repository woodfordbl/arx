//! fields.zig: the field tables of agent.yaml, plugin.yaml and kit.yaml.
//! One table drives validation (validate.zig) and the JSON Schema
//! (schema.zig), so adding a key here adds it to both.

/// The type of one key.
pub const FieldType = enum {
    string,
    number,
    integer,
    boolean,
    /// Seconds, or "10s", "5m", "1h".
    duration,
    /// Bytes, or "2kb", "1mb".
    size,
    /// A string or {file: path}.
    text,
    /// Text or a list of them.
    text_list,
    string_list,
    /// A mapping with any keys.
    any_map,
    /// A mapping with the keys in `sub`.
    map,
    /// A mapping whose values each have the keys in `sub`.
    dict,
    /// A list of plugin names or {name: {settings}}.
    plugin_list,
};

/// One key: its name, type, sub-fields (for map and dict) and a short
/// description for the JSON Schema.
pub const Field = struct {
    key: []const u8,
    type: FieldType,
    sub: []const Field = &.{},
    doc: []const u8,
};

/// The hook points.
pub const hook_points = [_][]const u8{ "session_start", "before_model", "after_model", "before_tool", "after_tool", "stop" };

/// The characters allowed in tool, plugin and kit names.
pub const name_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";

const endpoint_fields = [_]Field{
    .{ .key = "base_url", .type = .string, .doc = "OpenAI-compatible base URL" },
    .{ .key = "api_key_env", .type = .string, .doc = "Env var with the API key (OPENAI_API_KEY)" },
    .{ .key = "headers", .type = .any_map, .doc = "Extra HTTP headers" },
    .{ .key = "curl", .type = .string, .doc = "curl executable (default: $ARX_CURL or curl)" },
    .{ .key = "retry_base", .type = .duration, .doc = "First retry delay (default 2s)" },
    .{ .key = "retry_max", .type = .duration, .doc = "Longest retry delay (default 5m)" },
    .{ .key = "retry_attempts", .type = .integer, .doc = "Give up after this many (0 = never)" },
};

const tool_fields = [_]Field{
    .{ .key = "timeout", .type = .duration, .doc = "Seconds or 10s/5m/1h" },
    .{ .key = "agent", .type = .string, .doc = "Spec path: makes this tool a subagent" },
    .{ .key = "description", .type = .string, .doc = "Description shown to the model" },
    .{ .key = "enabled", .type = .boolean, .doc = "false hides the tool" },
};

const tool_output_fields = [_]Field{
    .{ .key = "head", .type = .size, .doc = "Bytes kept from the start of output (2kb)" },
    .{ .key = "tail", .type = .size, .doc = "Bytes kept from the end of output (6kb)" },
};

const hook_fields = [_]Field{
    .{ .key = "timeout", .type = .duration, .doc = "Default 10s" },
    .{ .key = "fail", .type = .string, .doc = "open (ignore failures) or closed" },
    .{ .key = "band", .type = .string, .doc = "policy, normal (the default) or final" },
    .{ .key = "changes", .type = .string_list, .doc = "The fields this hook changes" },
};

const compaction_fields = [_]Field{
    .{ .key = "strategy", .type = .string, .doc = "mask, summarize, hybrid, restart, a compactors name or a path" },
    .{ .key = "trigger", .type = .number, .doc = "Fraction of context_window (default 0.7)" },
    .{ .key = "keep", .type = .integer, .doc = "Recent outputs or turns kept intact (5)" },
    .{ .key = "exclude_tools", .type = .string_list, .doc = "Tools whose outputs stay" },
    .{ .key = "clear_inputs", .type = .boolean, .doc = "Also clear old tool-call arguments" },
    .{ .key = "prompt", .type = .text, .doc = "Instructions for summarize" },
};

const limits_fields = [_]Field{
    .{ .key = "max_turns", .type = .integer, .doc = "Model calls per session (200)" },
    .{ .key = "turn_timeout", .type = .duration, .doc = "Longest single model call (10m)" },
};

const prices_fields = [_]Field{
    .{ .key = "input", .type = .number, .doc = "USD per 1M input tokens" },
    .{ .key = "output", .type = .number, .doc = "USD per 1M output tokens" },
};

/// The top-level keys of agent.yaml.
pub const top_fields = [_]Field{
    .{ .key = "name", .type = .string, .doc = "Agent name" },
    .{ .key = "model", .type = .string, .doc = "Model id your endpoint accepts" },
    .{ .key = "endpoint", .type = .map, .sub = &endpoint_fields, .doc = "Where requests go" },
    .{ .key = "model_settings", .type = .any_map, .doc = "Extra request fields; null removes" },
    .{ .key = "context_window", .type = .integer, .doc = "Context size in tokens (128000)" },
    .{ .key = "instructions", .type = .text_list, .doc = "System prompt; {{vars}} allowed" },
    .{ .key = "first_message", .type = .text, .doc = "First user message; {{prompt}} is the task" },
    .{ .key = "tools", .type = .dict, .sub = &tool_fields, .doc = "Options per tool, or subagent tools" },
    .{ .key = "tool_output", .type = .map, .sub = &tool_output_fields, .doc = "How much tool output the model sees" },
    .{ .key = "hooks", .type = .dict, .sub = &hook_fields, .doc = "Options per hook point (hooks/<point>)" },
    .{ .key = "compaction", .type = .map, .sub = &compaction_fields, .doc = "How the context stays in the window" },
    .{ .key = "skills", .type = .string, .doc = "Directory of <name>/SKILL.md files" },
    .{ .key = "limits", .type = .map, .sub = &limits_fields, .doc = "Per-session limits" },
    .{ .key = "observers", .type = .string_list, .doc = "Commands fed the event stream on stdin" },
    .{ .key = "prices", .type = .map, .sub = &prices_fields, .doc = "Token prices for cost tracking" },
    .{ .key = "kit", .type = .string, .doc = "The kit: its plugins, in order, and its prompt" },
    .{ .key = "plugins", .type = .plugin_list, .doc = "The only plugins to use, in order (default: all installed)" },
    .{ .key = "enable", .type = .plugin_list, .doc = "Plugins to add to the kit or the list" },
    .{ .key = "disable", .type = .string_list, .doc = "Plugins to leave out" },
    .{ .key = "compactors", .type = .any_map, .doc = "Named compaction programs: name -> path" },
};

/// The keys of plugin.yaml.
pub const plugin_fields = [_]Field{
    .{ .key = "name", .type = .string, .doc = "Must match the plugin's folder name" },
    .{ .key = "version", .type = .string, .doc = "The plugin's version" },
    .{ .key = "description", .type = .string, .doc = "One line about what it adds" },
    .{ .key = "arx", .type = .string, .doc = "The arx versions it works with, e.g. \">=0.2\"" },
    .{ .key = "requires", .type = .string_list, .doc = "Programs that must be on PATH" },
    .{ .key = "tools", .type = .dict, .sub = &tool_fields, .doc = "Options for its tools, or subagent tools" },
    .{ .key = "hooks", .type = .dict, .sub = &hook_fields, .doc = "Options for its hooks: band, changes, ..." },
    .{ .key = "replaces", .type = .string_list, .doc = "Tools it hides on purpose" },
    .{ .key = "observers", .type = .string_list, .doc = "Commands fed the event stream" },
    .{ .key = "compactors", .type = .any_map, .doc = "Named compaction programs: name -> path" },
};

/// The keys of kit.yaml.
pub const kit_fields = [_]Field{
    .{ .key = "name", .type = .string, .doc = "Must match the kit's folder name" },
    .{ .key = "version", .type = .string, .doc = "The kit's version" },
    .{ .key = "description", .type = .string, .doc = "One line about the agent it makes" },
    .{ .key = "plugins", .type = .plugin_list, .doc = "Its plugins, in order: the priority" },
    .{ .key = "model_settings", .type = .any_map, .doc = "Extra request fields" },
    .{ .key = "prompt", .type = .string, .doc = "The system prompt file, relative to the kit" },
    .{ .key = "extends", .type = .string, .doc = "A kit this one starts from" },
    .{ .key = "enable", .type = .plugin_list, .doc = "Plugins to add to the kit it extends" },
    .{ .key = "disable", .type = .string_list, .doc = "Plugins to leave out of it" },
};
