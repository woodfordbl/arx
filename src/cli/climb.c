// climb.c: `arx check --climb FILE`, the only reader of climb.yaml. It
// parses the file with SpecParse, checks it against its field table, fills
// in the defaults, turns durations into seconds and prints one JSON object,
// so `arx climb` (a bash script) never parses YAML.

#include <math.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/base/base.h"
#include "src/cli/cli.h"
#include "src/harness/harness.h"

// A field that takes a number or a percent ("0.1%"); checked by a rule.
#define NUMBER_OR_PERCENT ((FieldType)0)

// The default score line: "score: 5.41".
static const char kPattern[] = "^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$";

static const Field kAgent[] = {
    {"spec", kString, NULL, "--spec for every round"},
    {"kit", kString, NULL, "--kit for every round"},
    {"set", kAnyMap, NULL, "--set KEY=VALUE for every round"},
    {NULL, 0, NULL, NULL}};

static const Field kEval[] = {
    {"command", kString, NULL, "The scorer, run with sh -c in an export"},
    {"files", kStringList, NULL, "Paths taken from eval.ref, never the tree"},
    {"ref", kString, NULL, "The commit the eval files come from (HEAD)"},
    {"goal", kString, NULL, "min or max"},
    {"pattern", kString, NULL, "An extended regex whose group is the score"},
    {"timeout", kDuration, NULL, "Longest one run may take (10m)"},
    {"repeats", kInteger, NULL, "Runs for every candidate (1)"},
    {"confirm", kInteger, NULL, "More runs for a likely winner (0)"},
    {"min_delta", NUMBER_OR_PERCENT, NULL, "How much better: 0.01 or 0.1%"},
    {"rescore", kInteger, NULL, "Score the best again every N rounds"},
    {"compare", kString, NULL, "A program that decides keep or revert"},
    {"show", kInteger, NULL, "Output lines the agent sees after a crash"},
    {NULL, 0, NULL, NULL}};

static const Field kHoldout[] = {
    {"command", kString, NULL, "A second scorer the agent never sees"},
    {"when", kString, NULL, "end (baseline and final best) or keep"},
    {NULL, 0, NULL, NULL}};

static const Field kBudget[] = {
    {"usd", kNumber, NULL, "Spend of the agent's session"},
    {"tokens", kInteger, NULL, "Input and output tokens of the session"},
    {"wall", kDuration, NULL, "Time since the climb started"},
    {"rounds", kInteger, NULL, "Rounds started"},
    {"patience", kInteger, NULL, "Rounds in a row without a keep"},
    {"target", kNumber, NULL, "Stop once the best reaches it"},
    {NULL, 0, NULL, NULL}};

static const Field kRound[] = {
    {"turns", kInteger, NULL, "Turns in one round (40)"},
    {"wall", kDuration, NULL, "Time for one round (30m)"},
    {NULL, 0, NULL, NULL}};

static const Field kClimbFields[] = {
    {"task", kText, NULL, "The first round's message"},
    {"agent", kMap, kAgent, "How every round runs arx"},
    {"change", kStringList, NULL, "The paths that are scored"},
    {"eval", kMap, kEval, "The official evaluation"},
    {"holdout", kMap, kHoldout, "A scorer whose results the agent never sees"},
    {"budget", kMap, kBudget, "When the climb stops"},
    {"round", kMap, kRound, "Limits for one round"},
    {NULL, 0, NULL, NULL}};

// Appends "FILE:LINE: KEY: message".
static void Problem(const Spec* c, Buffer* err, const char* key,
                    const char* fmt, ...) {
  cJSON* line = cJSON_GetObjectItemCaseSensitive(c->lines, key);
  if (cJSON_IsNumber(line)) {
    BufferPrintf(err, "%s:%d: %s: ", c->path, line->valueint, key);
  } else {
    BufferPrintf(err, "%s: %s: ", c->path, key);
  }
  va_list ap;
  va_start(ap, fmt);
  BufferVprintf(err, fmt, ap);
  va_end(ap);
  BufferAppendStr(err, "\n");
}

// True when `v` has the shape `type` needs; min_delta takes "0.1%" too.
static int ClimbTypeOk(FieldType type, const cJSON* v) {
  if (type == NUMBER_OR_PERCENT) return cJSON_IsNumber(v) || cJSON_IsString(v);
  return TypeOk(type, v);
}

// Checks every key of `node` against `fields`, recursing into mappings.
static void CheckNode(const Spec* c, cJSON* node, const Field* fields,
                      const char* path, Buffer* err) {
  for (cJSON* v = node->child; v; v = v->next) {
    char* key =
        *path ? XAsprintf("%s.%s", path, v->string) : XStrdup(v->string);
    const Field* f = fields;
    while (f->key && strcmp(f->key, v->string)) f++;
    if (!f->key) {
      Buffer known = {0};
      for (f = fields; f->key; f++) {
        BufferPrintf(&known, "%s%s", f == fields ? "" : ", ", f->key);
      }
      Problem(c, err, key, "unknown key (known: %s)", known.data);
      BufferFree(&known);
    } else if (!ClimbTypeOk(f->type, v)) {
      Problem(c, err, key, "must be %s", TypeName(f->type));
    } else if (f->type == kMap) {
      CheckNode(c, v, f->sub, key, err);
    }
    free(key);
  }
}

// Reports `key` when it is set and below `min` (at or below, if `strict`).
static void Range(const Spec* c, Buffer* err, const char* key, double min,
                  int strict) {
  double x = JsonDuration(c->root, key, NAN);  // numbers and durations
  if (isnan(x) || (strict ? x > min : x >= min)) return;
  Problem(c, err, key, "must be %s %g", strict ? "more than" : "at least", min);
}

// Change and eval paths stay inside the project.
static void CheckPaths(const Spec* c, Buffer* err, const char* key) {
  cJSON* p;
  cJSON_ArrayForEach(p, JsonGet(c->root, key)) {
    const char* s = cJSON_IsString(p) ? p->valuestring : "";
    char* padded = XAsprintf("/%s/", s);
    if (!*s || *s == '/' || strstr(padded, "/../")) {
      Problem(c, err, key, "\"%s\" must be a path inside the project", s);
    }
    free(padded);
  }
}

// The rules the table cannot express: required keys, choices and ranges.
static void CheckRules(const Spec* c, Buffer* err) {
  cJSON* root = c->root;
  cJSON* change = JsonGet(root, "change");
  if (!change || (cJSON_IsArray(change) && !cJSON_GetArraySize(change))) {
    Problem(c, err, "change", "required: the paths that are scored ([work/])");
  }
  if (!JsonGet(root, "eval.command")) {
    Problem(c, err, "eval.command", "required: the scorer, run with sh -c");
  }
  CheckPaths(c, err, "change");
  CheckPaths(c, err, "eval.files");
  const char* goal = JsonStr(root, "eval.goal", "min");
  if (strcmp(goal, "min") && strcmp(goal, "max")) {
    Problem(c, err, "eval.goal", "must be min or max");
  }
  const char* when = JsonStr(root, "holdout.when", "end");
  if (strcmp(when, "end") && strcmp(when, "keep")) {
    Problem(c, err, "holdout.when", "must be end or keep");
  }
  const char* ones[] = {"eval.repeats",    "budget.tokens", "budget.rounds",
                        "budget.patience", "round.turns",   NULL};
  for (const char** k = ones; *k; k++) Range(c, err, *k, 1, 0);
  const char* zeros[] = {"eval.confirm", "eval.rescore", "eval.show", NULL};
  for (const char** k = zeros; *k; k++) Range(c, err, *k, 0, 0);
  const char* positive[] = {"eval.timeout", "budget.usd", "budget.wall",
                            "round.wall", NULL};
  for (const char** k = positive; *k; k++) Range(c, err, *k, 0, 1);
  cJSON* delta = JsonGet(root, "eval.min_delta");
  int bad_delta = JsonNum(root, "eval.min_delta", 0) < 0;
  if (cJSON_IsString(delta)) {
    char* end;
    double d = strtod(delta->valuestring, &end);
    bad_delta = end == delta->valuestring || strcmp(end, "%") || d < 0;
  }
  if (bad_delta) {
    Problem(c, err, "eval.min_delta",
            "must be a number or a percent of the best (0.1%%), not negative");
  }
  regex_t re;
  const char* pattern = JsonStr(root, "eval.pattern", kPattern);
  int bad = regcomp(&re, pattern, REG_EXTENDED);
  if (bad || re.re_nsub < 1) {
    Problem(c, err, "eval.pattern",
            "must be an extended regular expression with one group");
  }
  if (!bad) regfree(&re);
}

// Adds the string at `path` as `key`, or `def` (null when NULL).
static void AddStr(cJSON* o, const char* key, cJSON* root, const char* path,
                   const char* def) {
  const char* s = JsonStr(root, path, def);
  cJSON_AddItemToObject(o, key, s ? cJSON_CreateString(s) : cJSON_CreateNull());
}

// Adds a number or a duration in seconds, or `def` (null when NaN).
static void AddNum(cJSON* o, const char* key, cJSON* root, const char* path,
                   double def) {
  double x = JsonDuration(root, path, def);
  cJSON_AddItemToObject(o, key,
                        isnan(x) ? cJSON_CreateNull() : cJSON_CreateNumber(x));
}

// A copy of the list at `path`, or [].
static cJSON* List(cJSON* root, const char* path) {
  cJSON* v = JsonGet(root, path);
  return v ? cJSON_Duplicate(v, 1) : cJSON_CreateArray();
}

// The whole configuration, with every default filled in.
static cJSON* Resolve(const Spec* c, Buffer* err) {
  cJSON *root = c->root, *out = cJSON_CreateObject();
  char* task = SpecText(c, JsonGet(root, "task"), err);
  if (!task) {
    Buffer paths = {0};
    cJSON* p;
    cJSON_ArrayForEach(p, JsonGet(root, "change")) {
      BufferPrintf(&paths, "%s%s", paths.len ? ", " : "", p->valuestring);
    }
    task = XAsprintf(
        "Make one change to %s that improves the score, then end your turn.",
        paths.data ? paths.data : "");
    BufferFree(&paths);
  }
  cJSON_AddStringToObject(out, "task", task);
  free(task);
  cJSON* agent = cJSON_AddObjectToObject(out, "agent");
  AddStr(agent, "spec", root, "agent.spec", NULL);
  AddStr(agent, "kit", root, "agent.kit", NULL);
  cJSON* set = JsonGet(root, "agent.set");
  cJSON_AddItemToObject(agent, "set",
                        set ? cJSON_Duplicate(set, 1) : cJSON_CreateObject());
  cJSON_AddItemToObject(out, "change", List(root, "change"));
  cJSON* e = cJSON_AddObjectToObject(out, "eval");
  AddStr(e, "command", root, "eval.command", NULL);
  cJSON_AddItemToObject(e, "files", List(root, "eval.files"));
  AddStr(e, "ref", root, "eval.ref", "HEAD");
  AddStr(e, "goal", root, "eval.goal", "min");
  AddStr(e, "pattern", root, "eval.pattern", kPattern);
  AddNum(e, "timeout", root, "eval.timeout", 600);
  AddNum(e, "repeats", root, "eval.repeats", 1);
  AddNum(e, "confirm", root, "eval.confirm", 0);
  cJSON* delta = JsonGet(root, "eval.min_delta");
  int percent = cJSON_IsString(delta);
  cJSON_AddNumberToObject(e, "min_delta",
                          percent ? strtod(delta->valuestring, NULL)
                                  : JsonNum(root, "eval.min_delta", 0));
  cJSON_AddBoolToObject(e, "min_delta_percent", percent);
  AddNum(e, "rescore", root, "eval.rescore", 0);
  AddStr(e, "compare", root, "eval.compare", NULL);
  AddNum(e, "show", root, "eval.show", 20);
  cJSON* h = cJSON_AddObjectToObject(out, "holdout");
  AddStr(h, "command", root, "holdout.command", NULL);
  AddStr(h, "when", root, "holdout.when", "end");
  cJSON* b = cJSON_AddObjectToObject(out, "budget");
  const char* budget[] = {"usd",      "tokens", "wall", "rounds",
                          "patience", "target", NULL};
  for (const char** k = budget; *k; k++) {
    char* path = XAsprintf("budget.%s", *k);
    AddNum(b, *k, root, path, NAN);
    free(path);
  }
  cJSON* r = cJSON_AddObjectToObject(out, "round");
  AddNum(r, "turns", root, "round.turns", 40);
  AddNum(r, "wall", root, "round.wall", 1800);
  return out;
}

// Checks climb.yaml and prints it as JSON; see cli.h.
int ClimbDescribe(const char* path, Buffer* out, Buffer* err) {
  Spec c;
  memset(&c, 0, sizeof(c));
  c.path = XStrdup(path);
  c.dir = DirName(path);
  size_t before = err->len;
  if (SpecParse(path, &c, err) == 0) {
    if (cJSON_IsObject(c.root)) {
      CheckNode(&c, c.root, kClimbFields, "", err);
      CheckRules(&c, err);
    } else {
      BufferPrintf(err, "%s: climb.yaml must be a YAML mapping\n", path);
    }
  }
  if (err->len == before) {
    cJSON* resolved = Resolve(&c, err);
    char* text = cJSON_PrintUnformatted(resolved);
    if (err->len == before) BufferPrintf(out, "%s\n", text);
    free(text);
    cJSON_Delete(resolved);
  }
  SpecFree(&c);
  return err->len == before ? 0 : -1;
}
