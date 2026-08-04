#ifndef PG_QUERY_H
#define PG_QUERY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    char* message;
    char* funcname;
    char* filename;
    int lineno;
    int cursorpos;
    char* context;
} PgQueryError;

typedef struct {
    size_t len;
    char* data;
} PgQueryProtobuf;

typedef struct {
    PgQueryProtobuf parse_tree;
    char* stderr_buffer;
    PgQueryError* error;
} PgQueryProtobufParseResult;

typedef enum {
    PG_QUERY_PARSE_DEFAULT = 0,
    PG_QUERY_PARSE_TYPE_NAME,
    PG_QUERY_PARSE_PLPGSQL_EXPR,
    PG_QUERY_PARSE_PLPGSQL_ASSIGN1,
    PG_QUERY_PARSE_PLPGSQL_ASSIGN2,
    PG_QUERY_PARSE_PLPGSQL_ASSIGN3
} PgQueryParseMode;

#define PG_QUERY_PARSE_MODE_BITS 4
#define PG_QUERY_PARSE_MODE_BITMASK ((1 << PG_QUERY_PARSE_MODE_BITS) - 1)
#define PG_QUERY_DISABLE_BACKSLASH_QUOTE 16
#define PG_QUERY_DISABLE_STANDARD_CONFORMING_STRINGS 32
#define PG_QUERY_DISABLE_ESCAPE_STRING_WARNING 64

#ifdef __cplusplus
extern "C" {
#endif

PgQueryProtobufParseResult pg_query_parse_protobuf(const char* input);
void pg_query_free_protobuf_parse_result(PgQueryProtobufParseResult result);
void pg_query_exit(void);
void pg_query_init(void);

#define PG_MAJORVERSION "14"
#define PG_VERSION "14.6"
#define PG_VERSION_NUM 140006

#ifdef __cplusplus
}
#endif

#endif
