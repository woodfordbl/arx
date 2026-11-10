// spec.c: loads agent.yaml with libyaml into a cJSON tree (remembering the
// line of every key), merges the user's defaults, and applies --set
// overrides. Validation lives in validate.c; plugins and the fingerprint for
// hot reload live in plugins.c.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "vendor/libyaml/include/yaml.h"

#include "src/base/base.h"
#include "src/harness/harness.h"
#include "src/harness/trust.h"

// Deeper YAML than this is rejected, which also stops alias bombs.
static const int kMaxYamlDepth = 64;

// Converts any YAML node to JSON, recording "path.key" -> line in `lines`.
// Declared here because the sequence and mapping converters recurse into it.
static cJSON* ConvertNode(yaml_document_t* doc, yaml_node_t* node, Buffer* path,
                          cJSON* lines, Buffer* err, int depth);

// Truncates the path buffer back to `len` bytes.
static void ResetPath(Buffer* path, size_t len) {
  path->len = len;
  path->data[len] = 0;
}

// Converts a sequence node into a JSON array.
static cJSON* ConvertSequence(yaml_document_t* doc, yaml_node_t* node,
                              Buffer* path, cJSON* lines, Buffer* err,
                              int depth) {
  cJSON* array = cJSON_CreateArray();
  size_t base = path->len;
  int i = 0;
  for (yaml_node_item_t* it = node->data.sequence.items.start;
       it < node->data.sequence.items.top; it++, i++) {
    BufferPrintf(path, "[%d]", i);
    yaml_node_t* child = yaml_document_get_node(doc, *it);
    cJSON_AddItemToArray(array,
                         ConvertNode(doc, child, path, lines, err, depth + 1));
    ResetPath(path, base);
  }
  return array;
}

// Converts a mapping node into a JSON object; keys must be plain scalars.
static cJSON* ConvertMapping(yaml_document_t* doc, yaml_node_t* node,
                             Buffer* path, cJSON* lines, Buffer* err,
                             int depth) {
  cJSON* object = cJSON_CreateObject();
  size_t base = path->len;
  for (yaml_node_pair_t* pair = node->data.mapping.pairs.start;
       pair < node->data.mapping.pairs.top; pair++) {
    yaml_node_t* key_node = yaml_document_get_node(doc, pair->key);
    if (!key_node || key_node->type != YAML_SCALAR_NODE) {
      BufferPrintf(err, "line %d: mapping keys must be plain strings\n",
                   (int)node->start_mark.line + 1);
      continue;
    }
    const char* key = (const char*)key_node->data.scalar.value;
    int line = (int)key_node->start_mark.line + 1;
    if (base) BufferAppendStr(path, ".");
    BufferAppendStr(path, key);
    if (cJSON_GetObjectItemCaseSensitive(object, key)) {
      BufferPrintf(err, "line %d: %s: duplicate key\n", line, path->data);
    } else {
      cJSON_AddNumberToObject(lines, path->data, line);
      yaml_node_t* value = yaml_document_get_node(doc, pair->value);
      cJSON_AddItemToObject(
          object, key, ConvertNode(doc, value, path, lines, err, depth + 1));
    }
    ResetPath(path, base);
  }
  return object;
}

// Dispatches on the node type.
static cJSON* ConvertNode(yaml_document_t* doc, yaml_node_t* node, Buffer* path,
                          cJSON* lines, Buffer* err, int depth) {
  if (!node || depth > kMaxYamlDepth) return cJSON_CreateNull();
  switch (node->type) {
    case YAML_SCALAR_NODE:
      return JsonScalar((const char*)node->data.scalar.value,
                        node->data.scalar.style == YAML_PLAIN_SCALAR_STYLE);
    case YAML_SEQUENCE_NODE:
      return ConvertSequence(doc, node, path, lines, err, depth);
    case YAML_MAPPING_NODE:
      return ConvertMapping(doc, node, path, lines, err, depth);
    default:
      return cJSON_CreateNull();
  }
}

// Parses a YAML file without validating it; see harness.h.
int SpecParse(const char* path, Spec* spec, Buffer* err) {
  FILE* f = fopen(path, "rb");
  if (!f) {
    BufferPrintf(err, "%s: %s\n", path, strerror(errno));
    return -1;
  }
  yaml_parser_t parser;
  yaml_document_t doc;
  yaml_parser_initialize(&parser);
  yaml_parser_set_input_file(&parser, f);
  int ok = yaml_parser_load(&parser, &doc);
  if (!ok) {
    BufferPrintf(err, "%s:%d:%d: %s\n", path, (int)parser.problem_mark.line + 1,
                 (int)parser.problem_mark.column + 1,
                 parser.problem ? parser.problem : "YAML error");
  } else {
    Buffer key_path = {0};
    BufferAppendStr(&key_path, "");
    spec->lines = cJSON_CreateObject();
    yaml_node_t* root = yaml_document_get_root_node(&doc);
    spec->root = root ? ConvertNode(&doc, root, &key_path, spec->lines, err, 0)
                      : cJSON_CreateObject();
    BufferFree(&key_path);
    yaml_document_delete(&doc);
  }
  yaml_parser_delete(&parser);
  fclose(f);
  return ok ? 0 : -1;
}

// Copies the line numbers of `prefix` and everything under it from `from`
// into `lines`, as "file:line" strings.
static void CopyLines(cJSON* lines, cJSON* from, const char* prefix,
                      const char* file) {
  size_t n = strlen(prefix);
  for (cJSON* l = from->child; l; l = l->next) {
    if (strncmp(l->string, prefix, n)) continue;  // also ensures length >= n
    char next = l->string[n];
    if (next && next != '.' && next != '[') continue;
    char* where = XAsprintf("%s:%d", file, l->valueint);
    cJSON_AddStringToObject(lines, l->string, where);
    free(where);
  }
}

// Moves every key of `defaults` that `target` lacks into `target`,
// recursing into mappings that both have, so the project spec wins.
static void MergeDefaults(cJSON* target, cJSON* defaults, const char* path,
                          Spec* spec, const Spec* config) {
  for (cJSON* d = defaults->child; d;) {
    cJSON* next = d->next;
    char* p = *path ? XAsprintf("%s.%s", path, d->string) : XStrdup(d->string);
    cJSON* t = cJSON_GetObjectItemCaseSensitive(target, d->string);
    if (!t) {
      cJSON* moved = cJSON_DetachItemViaPointer(defaults, d);
      cJSON_AddItemToObject(target, moved->string, moved);
      CopyLines(spec->lines, config->lines, p, config->path);
    } else if (cJSON_IsObject(t) && cJSON_IsObject(d)) {
      MergeDefaults(t, d, p, spec, config);
    }
    free(p);
    d = next;
  }
}

// Merges `from` under `spec`; see harness.h.
void SpecMergeUnder(Spec* spec, Spec* from) {
  if (cJSON_IsObject(spec->root) && cJSON_IsObject(from->root)) {
    MergeDefaults(spec->root, from->root, "", spec, from);
  }
}

// Reads the user's defaults (config.yaml in ConfigDir) into `config`.
// Returns 1 if they exist, 0 if not, and -1 on a YAML error.
static int LoadDefaults(Spec* config, Buffer* err) {
  char* dir = ConfigDir();
  char* path = XAsprintf("%s/config.yaml", dir);
  memset(config, 0, sizeof(*config));
  int found = access(path, R_OK) == 0;
  if (found && SpecParse(path, config, err)) found = -1;
  if (found > 0) {
    config->path = path;
    config->dir = dir;
  } else {
    free(path);
    free(dir);
  }
  return found;
}

// Merges `from` over `target`; see harness.h.
void JsonMergeOver(cJSON* target, const cJSON* from) {
  for (cJSON* f = from ? from->child : NULL; f; f = f->next) {
    cJSON* t = cJSON_GetObjectItemCaseSensitive(target, f->string);
    if (t && cJSON_IsObject(t) && cJSON_IsObject(f)) {
      JsonMergeOver(t, f);
    } else if (t) {
      cJSON_ReplaceItemViaPointer(target, t, cJSON_Duplicate(f, 1));
    } else {
      cJSON_AddItemToObject(target, f->string, cJSON_Duplicate(f, 1));
    }
  }
}

// Merges the kit's spec values (`kit_root`, consumed) between the user's
// defaults and the spec: the spec wins over the kit, the kit over config.
static void MergeKit(Spec* spec, cJSON* kit_root, int spec_is_config) {
  if (!kit_root) return;
  if (spec_is_config) {
    JsonMergeOver(spec->root, kit_root);
  } else {
    Spec kit = {.root = kit_root, .lines = cJSON_CreateObject()};
    kit.path = XAsprintf("%s/kit.yaml", spec->kit_dir);
    SpecMergeUnder(spec, &kit);
    SpecFree(&kit);
    return;
  }
  cJSON_Delete(kit_root);
}

// Builds the active list from config.yaml (`config`, may be empty), the
// spec (when it is not the defaults) and `sets`, and merges the kit. Notes
// where the base prompt comes from so far: the spec's own instructions win
// over the kit's, which win over config.yaml's.
static int BuildList(Spec* spec, Spec* config, int spec_is_config, cJSON* sets,
                     Buffer* err) {
  cJSON* kit_root = NULL;
  int rc =
      ActiveBuild(spec, spec_is_config ? spec->root : config->root,
                  spec_is_config ? NULL : spec->root, sets, &kit_root, err);
  int own = JsonGet(spec->root, "instructions") != NULL;
  if (JsonGet(kit_root, "instructions") && (spec_is_config || !own)) {
    spec->prompt_from = XAsprintf("kit %s", spec->kit);
  } else if (own) {
    spec->prompt_from = XStrdup(spec_is_config ? "config.yaml" : "agent.yaml");
  }
  MergeKit(spec, kit_root, spec_is_config);
  return rc;
}

// Loads, merges, overrides, validates and fingerprints; see harness.h.
int SpecLoad(const char* path, cJSON* sets, cJSON* policy, Spec* spec,
             Buffer* err) {
  Spec config;
  memset(spec, 0, sizeof(*spec));
  size_t errors_before = err->len;
  int have_defaults = LoadDefaults(&config, err);
  if (have_defaults < 0) return -1;
  if (!path && !have_defaults) {
    BufferAppendStr(
        err,
        "no agent.yaml here and no saved defaults: run `arx "
        "setup`, or `arx init` to start a harness in this folder\n");
    return -1;
  }
  int listed = 0;
  if (!path) {
    *spec = config;  // the defaults are the whole spec
    spec->config = XStrdup(spec->path);
    listed =
        cJSON_IsObject(spec->root) ? BuildList(spec, NULL, 1, sets, err) : 0;
  } else if (SpecParse(path, spec, err)) {
    SpecFree(&config);
    return -1;
  } else {
    spec->path = XStrdup(path);
    spec->dir = DirName(path);
    if (cJSON_IsObject(spec->root)) {
      listed = BuildList(spec, &config, 0, sets, err);
    }
    if (have_defaults && cJSON_IsObject(spec->root) &&
        cJSON_IsObject(config.root)) {
      if (!spec->prompt_from && JsonGet(config.root, "instructions")) {
        spec->prompt_from = XStrdup("config.yaml");
      }
      MergeDefaults(spec->root, config.root, "", spec, &config);
      spec->config = XStrdup(config.path);
    }
    SpecFree(&config);
  }
  if (listed == 0 && cJSON_IsObject(spec->root)) {
    for (cJSON* kv = sets ? sets->child : NULL; kv; kv = kv->next) {
      JsonSet(spec->root, kv->string, cJSON_Duplicate(kv, 1));
    }
    if (cJSON_GetObjectItemCaseSensitive(sets, "instructions")) {
      free(spec->prompt_from);
      spec->prompt_from = XStrdup("--set");
    } else if (!spec->prompt_from) {
      spec->prompt_from = XStrdup("default");
    }
    spec->policy = cJSON_Duplicate(policy, 1);
    PluginsLoad(spec);
  }
  if (listed == 0) SpecValidate(spec, err);
  spec->sig = SpecSignature(spec);
  if (err->len > errors_before) {
    SpecFree(spec);
    return -1;
  }
  return 0;
}

// Releases everything SpecLoad allocated.
void SpecFree(Spec* spec) {
  cJSON_Delete(spec->root);
  cJSON_Delete(spec->lines);
  free(spec->path);
  free(spec->dir);
  free(spec->config);
  LayersFree(spec);
  BufferFree(&spec->problems);
  cJSON_Delete(spec->active);
  cJSON_Delete(spec->off);
  cJSON_Delete(spec->settings);
  free(spec->kit);
  free(spec->kit_dir);
  free(spec->kit_from);
  cJSON_Delete(spec->rows);
  cJSON_Delete(spec->setting_from);
  BufferFree(&spec->warnings);
  free(spec->prompt_from);
  cJSON_Delete(spec->policy);
  memset(spec, 0, sizeof(*spec));
}

// Stores "key=value" in `sets`, with the value parsed like a YAML scalar.
int SpecAddSet(cJSON* sets, const char* key_value) {
  const char* eq = strchr(key_value, '=');
  if (!eq || eq == key_value) return -1;
  char* key = XStrndup(key_value, (size_t)(eq - key_value));
  const char* value = eq + 1;
  cJSON* json = *value == '[' || *value == '{' ? cJSON_Parse(value) : NULL;
  cJSON_DeleteItemFromObjectCaseSensitive(sets, key);
  cJSON_AddItemToObject(sets, key, json ? json : JsonScalar(value, 1));
  free(key);
  return 0;
}

// Resolves a text node: string, {file}, or a list of them.
char* SpecText(const Spec* spec, cJSON* node, Buffer* err) {
  if (!node || cJSON_IsNull(node)) return NULL;
  if (cJSON_IsString(node)) return XStrdup(node->valuestring);
  if (cJSON_IsArray(node)) {
    Buffer joined = {0};
    for (cJSON* c = node->child; c; c = c->next) {
      char* part = SpecText(spec, c, err);
      if (!part) continue;
      if (joined.len) BufferAppendStr(&joined, "\n\n");
      BufferAppendStr(&joined, part);
      free(part);
    }
    return BufferTake(&joined);
  }
  const char* file = JsonStr(node, "file", NULL);
  if (!file) return NULL;
  char* path = PathJoin(spec->dir, file);
  char* text = ReadFile(path, NULL);
  if (!text && err) {
    BufferPrintf(err, "%s: cannot read %s: %s\n", spec->path, path,
                 strerror(errno));
  }
  free(path);
  return text;
}
