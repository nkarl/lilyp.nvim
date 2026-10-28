-- libyaml 0.2 public ABI declarations, derived from yaml.h (MIT).
-- Keep complete parser/event layouts: no guessed storage sizes or offsets.
local ffi=require('ffi')
ffi.cdef[[
typedef unsigned char yaml_char_t;
typedef int yaml_encoding_t;
typedef int yaml_error_type_t;
typedef int yaml_event_type_t;
typedef int yaml_scalar_style_t;
typedef int yaml_sequence_style_t;
typedef int yaml_mapping_style_t;
typedef int yaml_parser_state_t;
typedef struct yaml_token_s yaml_token_t;
typedef struct yaml_simple_key_s yaml_simple_key_t;
typedef struct yaml_alias_data_s yaml_alias_data_t;
typedef struct yaml_document_s yaml_document_t;
typedef int yaml_read_handler_t(void *, unsigned char *, size_t, size_t *);
typedef struct yaml_mark_s {
    size_t index;
    size_t line;
    size_t column;
} yaml_mark_t;
typedef struct yaml_version_directive_s {
    int major;
    int minor;
} yaml_version_directive_t;
typedef struct yaml_tag_directive_s {
    yaml_char_t *handle;
    yaml_char_t *prefix;
} yaml_tag_directive_t;
typedef struct yaml_event_s {
    yaml_event_type_t type;
    union {
        struct {
            yaml_encoding_t encoding;
        } stream_start;
        struct {
            yaml_version_directive_t *version_directive;
            struct {
                yaml_tag_directive_t *start;
                yaml_tag_directive_t *end;
            } tag_directives;
            int implicit;
        } document_start;
        struct {
            int implicit;
        } document_end;
        struct {
            yaml_char_t *anchor;
        } alias;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            yaml_char_t *value;
            size_t length;
            int plain_implicit;
            int quoted_implicit;
            yaml_scalar_style_t style;
        } scalar;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            int implicit;
            yaml_sequence_style_t style;
        } sequence_start;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            int implicit;
            yaml_mapping_style_t style;
        } mapping_start;
    } data;
    yaml_mark_t start_mark;
    yaml_mark_t end_mark;
} yaml_event_t;
typedef struct yaml_parser_s {
    yaml_error_type_t error;
    const char *problem;
    size_t problem_offset;
    int problem_value;
    yaml_mark_t problem_mark;
    const char *context;
    yaml_mark_t context_mark;
    yaml_read_handler_t *read_handler;
    void *read_handler_data;
    union {
        struct {
            const unsigned char *start;
            const unsigned char *end;
            const unsigned char *current;
        } string;
        void *file;
    } input;
    int eof;
    struct {
        yaml_char_t *start;
        yaml_char_t *end;
        yaml_char_t *pointer;
        yaml_char_t *last;
    } buffer;
    size_t unread;
    struct {
        unsigned char *start;
        unsigned char *end;
        unsigned char *pointer;
        unsigned char *last;
    } raw_buffer;
    yaml_encoding_t encoding;
    size_t offset;
    yaml_mark_t mark;
    int stream_start_produced;
    int stream_end_produced;
    int flow_level;
    struct {
        yaml_token_t *start;
        yaml_token_t *end;
        yaml_token_t *head;
        yaml_token_t *tail;
    } tokens;
    size_t tokens_parsed;
    int token_available;
    struct {
        int *start;
        int *end;
        int *top;
    } indents;
    int indent;
    int simple_key_allowed;
    struct {
        yaml_simple_key_t *start;
        yaml_simple_key_t *end;
        yaml_simple_key_t *top;
    } simple_keys;
    struct {
        yaml_parser_state_t *start;
        yaml_parser_state_t *end;
        yaml_parser_state_t *top;
    } states;
    yaml_parser_state_t state;
    struct {
        yaml_mark_t *start;
        yaml_mark_t *end;
        yaml_mark_t *top;
    } marks;
    struct {
        yaml_tag_directive_t *start;
        yaml_tag_directive_t *end;
        yaml_tag_directive_t *top;
    } tag_directives;
    struct {
        yaml_alias_data_t *start;
        yaml_alias_data_t *end;
        yaml_alias_data_t *top;
    } aliases;
    yaml_document_t *document;
} yaml_parser_t;
int yaml_parser_initialize(yaml_parser_t *parser);
void yaml_parser_delete(yaml_parser_t *parser);
void yaml_parser_set_input_string(yaml_parser_t *parser, const unsigned char *input, size_t size);
int yaml_parser_parse(yaml_parser_t *parser, yaml_event_t *event);
void yaml_event_delete(yaml_event_t *event);
const char *yaml_get_version_string(void);
]]
local errors={}
for _,name in ipairs({'yaml','yaml-0','libyaml-0.so.2','libyaml.dylib','yaml.dll'}) do
  local ok,lib=pcall(ffi.load,name)
  if ok then
    local version=ffi.string(lib.yaml_get_version_string())
    assert(version:match('^0%.2%.'),'Unsupported libyaml ABI '..version..'; libyaml 0.2 is required')
    return {ffi=ffi,lib=lib,version=version}
  end
  errors[#errors+1]=tostring(lib)
end
error('libyaml is required for project YAML; install libyaml (Linux), libyaml via Homebrew (macOS), or yaml.dll (Windows).\n'..table.concat(errors,'\n'))
