# Flyology PostgreSQL SQL

`flyology_postgres_sql` contains a native Ada implementation of PostgreSQL's
raw SQL parser for PostgreSQL 14 through 18. Each major has generated scanner
tables, parser tables, semantic reductions, schema metadata, an Ada 2022
syntax-tree API, and built-in type metadata. Consumer builds use checked-in
source and do not access the network.

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

## Fully owned Ada ASTs

`Flyology.Postgres.SQL.AST.V14` through `AST.V18` provide a second output from
the same native parser. These packages materialize the shallow arena into an
ordinary, recursively navigable Ada object graph:

- every reachable protobuf message is a generated public record;
- `Node` is a generated discriminated record whose variant embeds the concrete
  PostgreSQL node record;
- optional fields retain their generated `Present` discriminant;
- repeated fields are typed `Ada.Containers.Vectors`;
- strings are owned `Unbounded_String` values; and
- recursive fields are typed Ada access values such as `Node_Access` and
  `Select_Stmt_Access`.

An `Owned_Syntax_Tree` is limited and controlled. It owns the complete graph,
releases it on `Clear`, replacement, or finalization, and is independent of the
flat `Syntax_Tree` after `Materialize` returns. The access values and vectors in
its records remain valid until that owning tree is cleared, parsed into again,
or finalized. Consumers must not deallocate or graft those access values into a
different owner.

```ada
with Flyology.Postgres.SQL.AST.V18;

declare
   package AST renames Flyology.Postgres.SQL.AST.V18;

   Tree : AST.Owned_Syntax_Tree;
begin
   AST.Parse
     ("WITH recent AS (SELECT id FROM events) SELECT id FROM recent",
      Tree);

   if Tree.Valid then
      declare
         Item : constant AST.Node_Access :=
           Tree.Root.Statements.Element (1).Statement.Value;
         Selection : constant AST.Select_Stmt :=
           Item.Select_Stmt_Payload;
         CTE : constant AST.Node_Access :=
           Selection.With_Clause.Value.Ctes.Element (1);
      begin
         --  Navigation uses ordinary record field notation and vector methods.
         if CTE.Kind = AST.Node_Common_Table_Expr then
            null;
         end if;
      end;
   end if;
end;
```

`Materialize` is useful when both representations are needed. The versioned
`AST.Parse` procedure is the Phase 2 path: it parses into the shallow arena and
then materializes the owned form. `AST.Parse_Direct` is the Phase 3 path: it
uses the same native scanner, LR engine, and generated reductions, but its
schema-generated converter writes from the private semantic builder directly
to the owned records. It never constructs an intermediate public
`Syntax_Tree`.

```ada
declare
   Tree : AST.Owned_Syntax_Tree;
begin
   AST.Parse_Direct ("SELECT id FROM events", Tree);
   if Tree.Valid then
      --  Tree.Root is the same fully owned record graph shown above.
      null;
   end if;
end;
```

Both paths remain available while the direct path is validated. `Equivalent`
is a generated exhaustive structural comparator used to check every record,
node variant, optional discriminant, vector element, scalar, enum, diagnostic,
and source/version field. The C/libpg_query backends remain validation oracles
and are not used by either production output.

## Version and option behavior

Pass the required `Major_Version` to `Parse`, then use the matching `V14`–`V18`
package. The version precondition on `Root` prevents accidental cross-version
interpretation. PostgreSQL 15–18 support the parser-mode and lexer-GUC fields in
`Parse_Options`. The PostgreSQL 14 extraction predates that upstream API;
`Supports_Parse_Options` reports this, and non-default options raise
`Unsupported_Parse_Options` instead of being silently ignored.

Normal parsing is entirely Ada: it does not call `libpg_query`, serialize
protobuf, or cross a C boundary. The isolated C backends remain private test
oracles. They parse the same corpus through PostgreSQL and protobuf so the test
suite can compare the two logical arenas exactly, including field presence and
diagnostic positions. Protobuf bytes, C pointers, native ownership, and arena
identifiers are not part of the public API.

## Native parser architecture

The production pipeline is:

```text
SQL text
  -> generated Flex DFA scanner
  -> generated Bison LALR tables
  -> generated Ada semantic reductions
  -> private flat semantic arena
  -> generated protobuf-schema mapping
  -> public Syntax_Tree arena and shallow views
```

The direct-owned production pipeline shares the parsing front end but omits
both public-arena stages:

```text
SQL text
  -> generated Flex DFA scanner
  -> compact generated LALR automaton interpreted by the Ada LR engine
  -> generated Ada semantic reductions
  -> private flat semantic builder
  -> generated schema-aware owned converter
  -> Owned_Syntax_Tree records
```

The scanner implements PostgreSQL's start conditions, longest-match behavior,
keywords, lookahead filters, comments, quoted and Unicode identifiers, ordinary
and escape strings, dollar quoting, parameters, operators, and numeric forms.
The parser runtime applies the checked-in version's LALR tables and generated
reductions. Semantic values are stored in a private flat builder; recursive
grammar relationships therefore do not allocate an Ada object graph. A
schema-driven converter maps those values to the same logical arena shape as
the former protobuf decoder.

The validation-only pipeline is:

```text
the same SQL text
  -> isolated version-pinned libpg_query/PostgreSQL backend
  -> protobuf wire bytes
  -> generated Ada protobuf decoder
  -> oracle Syntax_Tree arena
  -> structural comparison with the native result
```

The comparison is member-order independent for objects and order sensitive for
sequences. It preserves scalar kinds, enum values, omitted fields, array
contents, parse validity, diagnostics, and cursor positions. The C result and
its protobuf buffer are freed on every path after the oracle tree has copied
the data.

## Catalog types

`Flyology.Postgres.Types` provides version-dispatched lookup by OID or catalog
name. `Types.V14` through `Types.V18` provide generated OID constants. A
`Type_Descriptor` exposes kind, category, storage, alignment, passing mode,
length form, preferred status, element OID, and array OID.

The catalog inputs are the current supported PostgreSQL releases used by this
repository: 14.23, 15.18, 16.14, 17.10, and 18.4. Their official source archive
SHA-256 values and source URLs are recorded under `catalog/v*/UPSTREAM.toml`.

## Reproducible generation

The generated `V14`–`V18` units are never edited by hand. Seven generators form
the parser and AST toolchain:

- `generate_native_parser.py` extracts the version's Bison tables and token
  numbers, exact Flex DFA tables and actions, start conditions, and keyword
  table.
- `generate_native_actions.py` reads Clang's JSON AST for the extracted parser
  and PostgreSQL constructors, then translates every reachable grammar
  reduction into Ada. Its audit rejects unsupported C constructs.
- `generate_native_schema.py` combines `pg_query.proto` with PostgreSQL node and
  enum definitions to generate the semantic-arena-to-public-arena mapping.
- `generate_ada.py` reads `pg_query.proto`, computes every message and enum
  reachable from `ParseResult` and `Node`, and emits the public shallow views
  and the private protobuf decoder used by the C oracle.
- `generate_owned_ast.py` uses that same reachable schema to emit every owned
  record, discriminated node variant, optional and vector type, arena-to-record
  converter, and graph finalizer for `AST.V14` through `AST.V18`.
- `generate_direct_owned.py` combines the protobuf schema with Clang-derived
  PostgreSQL node and enum definitions to emit the private-builder-to-owned
  converter for every reachable message and all five majors.
- `generate_owned_equivalence.py` emits the exhaustive structural comparator
  used by differential tests; comparison logic therefore grows automatically
  when an upstream field, message, or enum is added.

The native tables and reductions come from the exact generated `gram.c` and
`scan.c` shipped by the pinned `libpg_query` extraction, including its required
PostgreSQL patches. The corresponding official PostgreSQL `gram.y`, `scan.l`,
parser support file, scanner headers, and keyword list are also checked in for
source-level audit and provenance. `pg_query.proto` remains the single source
of truth for the externally observable AST schema. The type generator reads
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

python3 tools/generate_owned_ast.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output src

python3 tools/generate_direct_owned.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --vendor backends/v18/vendor \
  --output src

python3 tools/generate_owned_equivalence.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output src

python3 tools/generate_native_parser.py \
  --major 18 \
  --vendor backends/v18/vendor \
  --output src

python3 tools/generate_native_actions.py \
  --major 18 \
  --vendor backends/v18/vendor \
  --output src \
  --audit

python3 tools/generate_native_schema.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --version-header backends/v18/vendor/pg_query.h \
  --vendor backends/v18/vendor \
  --output src
```

All parser/AST generators accept `--check`; the test action checks deterministic
output for all five versions before compiling and running traversal and
differential tests.

`tools/import_upstream.py` imports a pinned `libpg_query` release, removes
unrelated entry points, adds the version-prefixed oracle wrapper, imports the
minimal official PostgreSQL grammar/scanner source set, and records both source
archive hashes. `tools/import_catalog.py` verifies PostgreSQL's published
SHA-256 before extracting catalog definitions. The PostgreSQL and
`libpg_query` license files are retained with each imported backend.

## Testing

```sh
cd sql/tests
./scripts/test.sh
```

The tests cover the native scanner, parser tables, semantic builder and
generated reductions; every protobuf scalar encoding and malformed wire case
used by the oracle; all five shallow and owned typed roots; field notation,
optionals, vectors, nested owned nodes, enum fields, ownership replacement, and
diagnostics. Each direct-owned result is exhaustively compared with the Phase 2
arena-materialized result, which is itself checked against the version-pinned C
oracle. The differential corpus
includes empty and multi-statement inputs, quoted identifiers, Unicode,
comments, dollar and escape strings, embedded NUL rejection, invalid SQL, and
representative SELECT, CTE, join, expression, MERGE, DML, DDL, and utility
statements across all applicable majors. The SQL crate and generated units
compile with strict Ada 2022 switches. The earlier JSON/protobuf migration is
recorded in `tests/PROTOBUF_MIGRATION.md`.

### Why the LR automaton remains compact data

Expanding PostgreSQL's automaton into hand-written or generated per-state Ada
branches was evaluated and rejected. A current major contains thousands of
grammar reductions and hundreds of thousands of state/token decisions. The
expanded source would be much larger, slower to compile, and less friendly to
the instruction cache without changing the accepted language. Ayacc likewise
generates an LR automaton represented by tables, so changing generators would
not remove the numeric representation.

The intentionally hand-written part is therefore the small Ada scanner/LR
runtime and its safety checks; version-specific language data and semantic
actions stay reproducibly generated from the pinned upstream grammar. This
keeps exact PostgreSQL behavior reviewable and makes all version differences
data rather than five drifting parser implementations. Replacing the imported
Bison automaton remains possible only if an in-repository `gram.y`-to-LALR
generator can reproduce it exactly; it is not a prerequisite for the native or
direct-owned runtime paths.

The shallow arena remains the compact production representation. The owned AST
is the natural-navigation representation for consumers that prefer ordinary
Ada records and accept the allocation cost of a recursive object graph; the
direct path avoids paying for both representations when only the latter is
needed.
