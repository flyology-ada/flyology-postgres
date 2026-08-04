# Flyology PostgreSQL SQL

`flyology_postgres_sql` is a versioned binding to PostgreSQL's real raw SQL
parser for PostgreSQL 14 through 18. Each major has an isolated native parser,
a generated Ada 2022 syntax-tree API, and generated built-in type metadata.
Consumer builds use checked-in source and do not access the network.

## Shallow Ada syntax trees

`Syntax_Tree` is limited and owns a flat Ada arena. The public version packages
(`Flyology.Postgres.SQL.V14` through `V18`) expose three kinds of values:

- opaque `*_Reference` values for protobuf messages;
- public shallow record views, with the protobuf message name; and
- opaque `Sequence_Of_*` handles for repeated fields.

`View (Tree, Reference)` materializes one shallow record. Scalars and enums are
ordinary Ada values, and strings are owned `Unbounded_String` values. Child
messages remain opaque references, so recursive and mutually recursive
PostgreSQL nodes never become a heap-allocated Ada object graph.

Every non-repeated field has a definite discriminated `Optional_*` wrapper.
Consequently an omitted wire field remains different from an explicitly
encoded field whose value equals the protobuf default. Proto3 fields omitted
by the native serializer are necessarily absent because that distinction is
not present in the wire stream. Repeated fields appear directly as typed
sequence components.

```ada
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.V18;

declare
   package SQL renames Flyology.Postgres.SQL;
   package V18 renames Flyology.Postgres.SQL.V18;

   Tree : SQL.Syntax_Tree;
begin
   SQL.Parse ("select id, payload from events", SQL.PostgreSQL_18, Tree);

   if SQL.Is_Valid (Tree) then
      declare
         Item : constant V18.Node_Reference :=
           V18.Statement
             (Tree,
              V18.Element
                (Tree, V18.Statements (Tree, V18.Root (Tree)), 1));
         Select_Ref : constant V18.Select_Stmt_Reference :=
           V18.As_Select_Stmt (Tree, Item);
         Statement : constant V18.Select_Stmt :=
           V18.View (Tree, Select_Ref);
         Targets : constant V18.Sequence_Of_Node := Statement.Target_List;
      begin
         for Index in 1 .. V18.Length (Tree, Targets) loop
            declare
               Target : constant V18.Node_Reference :=
                 V18.Element (Tree, Targets, Index);
            begin
               --  Inspect V18.Kind, convert with As_*, then call View.
               null;
            end;
         end loop;
      end;
   else
      --  SQL.Message and SQL.Cursor_Position retain PostgreSQL's diagnostic.
      null;
   end if;
end;
```

### Reference lifetime

A reference or sequence is meaningful only with the exact `Syntax_Tree` that
created it. Calling `Parse` again on that tree resets its arena and invalidates
all earlier references and sequence handles. Destroying the tree does the same.
Passing a handle to another tree is erroneous application logic and is not a
supported operation. Scalar, enum, and owned text components already copied
into a view remain ordinary Ada values, but references and sequences contained
in that view retain the tree lifetime rule.

## Version and option behavior

Pass the required `Major_Version` to `Parse`, then use the matching `V14`–`V18`
package. The version precondition on `Root` prevents accidental cross-version
interpretation. PostgreSQL 15–18 support the parser-mode and lexer-GUC fields in
`Parse_Options`. The PostgreSQL 14 extraction predates that upstream API;
`Supports_Parse_Options` reports this, and non-default options raise
`Unsupported_Parse_Options` instead of being silently ignored.

The native boundary keeps PostgreSQL's protobuf buffer alive only while the
generated, schema-aware Ada decoder copies it into the flat arena. Cleanup is
exception-safe. Protobuf bytes, C pointers, native ownership, and arena
identifiers are not part of the public API.

## Catalog types

`Flyology.Postgres.Types` provides version-dispatched lookup by OID or catalog
name. `Types.V14` through `Types.V18` provide generated OID constants. A
`Type_Descriptor` exposes kind, category, storage, alignment, passing mode,
length form, preferred status, element OID, and array OID.

The catalog inputs are the current supported PostgreSQL releases used by this
repository: 14.23, 15.18, 16.14, 17.10, and 18.4. Their official source archive
SHA-256 values and source URLs are recorded under `catalog/v*/UPSTREAM.toml`.

## Reproducible generation

The generated `V14`–`V18` specs and bodies are never edited by hand.
`tools/generate_ada.py` reads each checked-in `pg_query.proto`, computes every
message and enum reachable from `ParseResult` and `Node`, and emits both the
public references/views/optionals/sequences and the private protobuf decoder.
The schema model retains wire field numbers, scalar encodings, repetitions,
oneof membership, message edges, enum numbers, and JSON field names. The type generator reads
checked-in `pg_type.dat`.

```sh
python3 tools/generate_ada.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output src

python3 tools/generate_types.py \
  --major 18 \
  --catalog catalog/v18/pg_type.dat \
  --output src
```

Both generators accept `--check`; the test action checks deterministic output
for all five versions before compiling and running the traversal tests.

`tools/import_upstream.py` imports a pinned `libpg_query` release, removes
unrelated entry points, adds the version-prefixed wrapper, and records source
and archive provenance. `tools/import_catalog.py` verifies PostgreSQL's
published SHA-256 before extracting catalog definitions. The PostgreSQL and
`libpg_query` license files are retained with each imported backend.

## Testing

```sh
cd tests
alr -n test
```

The tests cover every protobuf scalar encoding, malformed wire data, all five
typed roots, field notation, optionals, sequences, nested references, enum
fields, diagnostics, Unicode and quoted SQL, version-specific syntax, catalog
metadata, and representative SELECT, CTE, join, expression, MERGE, DDL, and
utility nodes. The SQL crate and generated units compile with strict Ada 2022
switches. The one-time JSON/protobuf migration differential and its corpus are
recorded in `tests/PROTOBUF_MIGRATION.md`.
