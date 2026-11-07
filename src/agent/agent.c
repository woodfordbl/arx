// agent.c: everything around the loop: caps, notes, the system prompt and
// its {{templates}} (including the harness description that tells the agent
// how to extend itself), and the session lifecycle in AgentMain.

#include "src/agent/agent.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/io/io.h"

// Used when the spec has no instructions.
static const char kDefaultInstructions[] =
    "You are an autonomous agent working in {{cwd}}. Use the tools to act, "
    "check the results, and keep going until the task is done. A reply "
    "without a tool call ends the task, so never say you will do something "
    "later: do it now. When everything is done, reply with a short summary "
    "and no tool calls.\n\n{{harness}}";

// Parses one --cap; see agent.h.
int CapsParse(Caps* c, const char* key_value) {
  const char* eq = strchr(key_value, '=');
  if (!eq) return -1;
  size_t len = (size_t)(eq - key_value);
  const char* value = eq + 1;
  if (len == 4 && !strncmp(key_value, "wall", 4)) {
    return ParseDuration(value, &c->wall);
  }
  char* end;
  double v = strtod(value, &end);
  if (end == value || *end || v < 0) return -1;
  if (len == 5 && !strncmp(key_value, "turns", 5)) {
    c->turns = (int64_t)v;
  } else if (len == 6 && !strncmp(key_value, "tokens", 6)) {
    c->tokens = v;
  } else if (len == 3 && !strncmp(key_value, "usd", 3)) {
    c->usd = v;
  } else if (len == 5 && !strncmp(key_value, "depth", 5)) {
    c->depth = (int64_t)v;
  } else {
    return -1;
  }
  return 0;
}

// Queues a note for the agent.
void AgentNote(Agent* a, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(&a->notes, fmt, ap);
  va_end(ap);
  if (a->notes.len && a->notes.data[a->notes.len - 1] != '\n') {
    BufferAppendStr(&a->notes, "\n");
  }
}

// Adds a message to the history and the transcript.
void AgentAddMessage(Agent* a, const char* role, const char* content) {
  cJSON* m = cJSON_CreateObject();
  cJSON_AddStringToObject(m, "role", role);
  cJSON_AddStringToObject(m, "content", content);
  cJSON_AddItemToArray(a->messages, m);
  SessionAppend(&a->session, m);
}

// Reads `name` and `description` from SKILL.md front matter.
static void FrontMatter(char* text, const char** name, const char** desc) {
  if (strncmp(text, "---\n", 4)) return;
  for (char* line = text + 4; line && strncmp(line, "---", 3);) {
    char* nl = strchr(line, '\n');
    if (nl) *nl = 0;
    if (!strncmp(line, "name:", 5)) *name = line + 5 + strspn(line + 5, " ");
    if (!strncmp(line, "description:", 12)) {
      *desc = line + 12 + strspn(line + 12, " ");
    }
    line = nl ? nl + 1 : NULL;
  }
}

// True when `seen` already holds the skill folder `name`.
static int Listed(char** seen, int n, const char* name) {
  for (int i = 0; i < n; i++) {
    if (!strcmp(seen[i], name)) return 1;
  }
  return 0;
}

// Lists skills as "- name: description (path)", one per line, from every
// layer; the first folder with a name wins.
static void SkillsIndex(Agent* a, Buffer* out) {
  size_t before = out->len;
  char** seen = NULL;
  int n_seen = 0;
  for (int l = 0; l < a->spec.layer_count; l++) {
    const char* dir = a->spec.layers[l].skills;
    char** names;
    int n = dir ? ListNames(dir, &names) : 0;
    for (int i = 0; i < n; i++) {
      char* path = XAsprintf("%s/%s/SKILL.md", dir, names[i]);
      char* text = Listed(seen, n_seen, names[i]) ? NULL : ReadFile(path, NULL);
      if (text) {
        const char *name = names[i], *desc = "";
        FrontMatter(text, &name, &desc);
        BufferPrintf(out, "- %s: %s (%s)\n", name, desc, path);
        seen = XRealloc(seen, (size_t)(n_seen + 1) * sizeof(*seen));
        seen[n_seen++] = XStrdup(names[i]);
      }
      free(text);
      free(path);
      free(names[i]);
    }
    if (n) free(names);
  }
  for (int i = 0; i < n_seen; i++) free(seen[i]);
  free(seen);
  if (out->len == before) BufferAppendStr(out, "(no skills yet)");
}

// Appends a line about the plugins in use, if there are any.
static void PluginsText(Agent* a, Buffer* out) {
  size_t before = out->len;
  for (int l = 0; l < a->spec.layer_count; l++) {
    const Layer* layer = &a->spec.layers[l];
    if (!layer->plugin) continue;
    BufferPrintf(out, "%s%s (%s)", out->len == before ? "" : ", ",
                 layer->plugin, layer->dir);
  }
  if (out->len == before) return;
  char* list = XStrdup(out->data + before);
  out->len = before;
  out->data[before] = 0;
  BufferPrintf(out,
               "\n- Plugins add tools, hooks and skills below yours: %s. A "
               "tool of yours with the same name wins; hooks all run by band "
               "(policy, normal, final) and then in this order, yours first.",
               list);
  if (a->spec.kit) {
    BufferPrintf(out, " The kit %s (%s) chose them.", a->spec.kit,
                 a->spec.kit_dir);
  }
  free(list);
}

// Tells the agent where its harness lives and how to change it.
static void HarnessText(Agent* a, Buffer* out) {
  const char* skills = JsonStr(a->spec.root, "skills", NULL);
  BufferPrintf(
      out,
      "Your harness is yours to change; edits take effect on your next "
      "turn:\n"
      "- Spec: %s (YAML: model settings, tools, hooks, compaction, limits). "
      "Check edits with `%s check --spec %s`.\n"
      "- Tools: %s/tools/<name>, any executable (chmod +x). `<name> "
      "--schema` prints {\"description\": ..., \"parameters\": <JSON "
      "Schema>}; a call gets its arguments as JSON on stdin; stdout and "
      "stderr are the result; a non-zero exit marks an error.\n"
      "- Hooks: %s/hooks/<point> for session_start, before_model, "
      "after_model, before_tool, after_tool and stop: JSON on stdin; print "
      "the fields to change, or a decision, as JSON on stdout.\n"
      "- Skills: %s%s<name>/SKILL.md with name and description front "
      "matter.\n"
      "- Session files (full tool outputs, transcript): %s",
      a->spec.path, g_self, a->spec.path, a->spec.dir, a->spec.dir,
      skills ? skills : "(set `skills:` in the spec) ", skills ? "/" : "",
      a->session.dir ? a->session.dir : "(none)");
  PluginsText(a, out);
}

// {{file:PATH}}, {{file:PATH:tail=N}} or {{file:PATH:max=SIZE}}.
static void FileVar(const char* spec, Buffer* out) {
  char* path = XStrdup(spec);
  char* option = strchr(path, ':');
  if (option) *option++ = 0;
  size_t n;
  char* text = ReadFile(path, &n);
  if (!text) {
    BufferPrintf(out, "(missing: %s)", path);
    free(path);
    return;
  }
  size_t start = 0, max = 0;
  if (option && !strncmp(option, "tail=", 5)) {
    int lines = atoi(option + 5);
    start = n && text[n - 1] == '\n' ? n - 1 : n;
    while (start > 0 && lines > 0) {
      if (text[--start] == '\n') lines--;
    }
    if (lines == 0) start++;
  } else if (option && !strncmp(option, "max=", 4)) {
    ParseSize(option + 4, &max);
  }
  char* clean = Utf8Clean(text + start, n - start);
  char* cut = max ? Truncate(clean, max) : XStrdup(clean);
  BufferAppendStr(out, cut);
  free(cut);
  free(clean);
  free(text);
  free(path);
}

// Appends the value of one {{name}}.
static void AppendVar(Agent* a, const char* name, Buffer* out) {
  char tmp[4096];
  if (!strcmp(name, "prompt")) {
    BufferAppendStr(out, a->prompt ? a->prompt : "");
  } else if (!strcmp(name, "harness")) {
    HarnessText(a, out);
  } else if (!strcmp(name, "skills")) {
    SkillsIndex(a, out);
  } else if (!strcmp(name, "date")) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(tmp, sizeof(tmp), "%Y-%m-%d", &tm);
    BufferAppendStr(out, tmp);
  } else if (!strcmp(name, "cwd")) {
    BufferAppendStr(out, getcwd(tmp, sizeof(tmp)) ? tmp : ".");
  } else if (!strcmp(name, "session")) {
    BufferAppendStr(out, a->session.id ? a->session.id : "");
  } else if (!strcmp(name, "turn")) {
    BufferPrintf(out, "%d", a->session.turns);
  } else if (!strncmp(name, "file:", 5)) {
    FileVar(name + 5, out);
  } else {
    BufferPrintf(out, "{{%s}}", name);
  }
}

// Expands {{vars}}; see agent.h.
char* RenderTemplate(Agent* a, const char* tmpl) {
  Buffer out = {0};
  BufferAppendStr(&out, "");
  for (const char* p = tmpl; *p;) {
    const char* open = strstr(p, "{{");
    const char* close = open ? strstr(open + 2, "}}") : NULL;
    if (!close) {
      BufferAppendStr(&out, p);
      break;
    }
    BufferAppend(&out, p, (size_t)(open - p));
    char* name = XStrndup(open + 2, (size_t)(close - open - 2));
    char* start = name + strspn(name, " ");
    char* end = start + strlen(start);
    while (end > start && end[-1] == ' ') *--end = 0;
    AppendVar(a, start, &out);
    free(name);
    p = close + 2;
  }
  return BufferTake(&out);
}

// The spec's instructions, or the default, rendered.
char* SystemPrompt(Agent* a) {
  char* text = SpecText(&a->spec, JsonGet(a->spec.root, "instructions"), NULL);
  char* rendered = RenderTemplate(a, text ? text : kDefaultInstructions);
  free(text);
  return rendered;
}

// The first_message template with {{prompt}}, or the prompt itself.
char* FirstMessage(Agent* a, const char* prompt) {
  char* tmpl = SpecText(&a->spec, JsonGet(a->spec.root, "first_message"), NULL);
  if (!tmpl) return XStrdup(prompt);
  const char* saved = a->prompt;
  a->prompt = prompt;
  char* rendered = RenderTemplate(a, tmpl);
  a->prompt = saved;
  free(tmpl);
  return rendered;
}
