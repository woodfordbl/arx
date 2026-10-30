// schema.c: generates the JSON Schema for agent.yaml (`arx schema`)
// from the field table, for editor autocompletion and validation.

#include <stdlib.h>

#include "src/base/base.h"
#include "src/harness/harness.h"

// The schema of a text node: a string or {file: path}.
static const char kTextSchema[] =
    "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"object\",\"properties\":"
    "{\"file\":{\"type\":\"string\"}},\"required\":[\"file\"],"
    "\"additionalProperties\":false}]}";

// Builds the schema object for a list of fields.
static cJSON* SchemaFields(const Field* fields);

// Builds the schema for one field type.
static cJSON* SchemaType(FieldType type, const Field* sub) {
  static const char* const kJsonTypes[] = {"", "string", "number", "integer",
                                           "boolean"};
  if (type == kMap) return SchemaFields(sub);
  if (type == kText) return cJSON_Parse(kTextSchema);
  cJSON* o = cJSON_CreateObject();
  if (type <= kBoolean) {
    cJSON_AddStringToObject(o, "type", kJsonTypes[type]);
  } else if (type == kDuration || type == kSize) {
    const char* either[] = {"string", "number"};
    cJSON_AddItemToObject(o, "type", cJSON_CreateStringArray(either, 2));
  } else if (type == kTextList) {
    cJSON* any = cJSON_AddArrayToObject(o, "anyOf");
    cJSON* list = cJSON_CreateObject();
    cJSON_AddStringToObject(list, "type", "array");
    cJSON_AddItemToObject(list, "items", cJSON_Parse(kTextSchema));
    cJSON_AddItemToArray(any, cJSON_Parse(kTextSchema));
    cJSON_AddItemToArray(any, list);
  } else if (type == kStringList) {
    cJSON_AddStringToObject(o, "type", "array");
    cJSON* items = cJSON_AddObjectToObject(o, "items");
    cJSON_AddStringToObject(items, "type", "string");
  } else {
    cJSON_AddStringToObject(o, "type", "object");
    if (type == kDict) {
      cJSON_AddItemToObject(o, "additionalProperties", SchemaFields(sub));
    }
  }
  return o;
}

// One "properties" entry per field; unknown keys are not allowed.
static cJSON* SchemaFields(const Field* fields) {
  cJSON* o = cJSON_CreateObject();
  cJSON_AddStringToObject(o, "type", "object");
  cJSON* props = cJSON_AddObjectToObject(o, "properties");
  for (const Field* f = fields; f->key; f++) {
    cJSON* p = SchemaType(f->type, f->sub);
    cJSON_AddStringToObject(p, "description", f->doc);
    cJSON_AddItemToObject(props, f->key, p);
  }
  cJSON_AddFalseToObject(o, "additionalProperties");
  return o;
}

// Prints the whole schema; see harness.h.
void SpecSchema(Buffer* out) {
  const char* required[] = {"model", "endpoint"};
  const char* endpoint_required[] = {"base_url"};
  cJSON* s = SchemaFields(kTopFields);
  cJSON_AddStringToObject(s, "$schema",
                          "https://json-schema.org/draft/2020-12/schema");
  cJSON_AddStringToObject(s, "title", "arx agent spec");
  cJSON_AddItemToObject(s, "required", cJSON_CreateStringArray(required, 2));
  cJSON_AddItemToObject(JsonGet(s, "properties.endpoint"), "required",
                        cJSON_CreateStringArray(endpoint_required, 1));
  char* text = cJSON_Print(s);
  BufferAppendStr(out, text);
  BufferAppendStr(out, "\n");
  free(text);
  cJSON_Delete(s);
}
