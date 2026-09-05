# Flyology PostgreSQL SQL

`flyology_postgres_sql` contains a native Ada implementation of PostgreSQL's
raw SQL parser for PostgreSQL 14 through 18. Each major has generated scanner
tables, parser tables, semantic reductions, schema metadata, an Ada 2022
syntax-tree API, and built-in type metadata. Consumer builds use checked-in
source and do not access the network.

## Selecting parser versions at build time

Applications that use one PostgreSQL major should depend on its version crate,
for example:

```toml
[[depends-on]]
flyology_postgres_sql_v18 = "*"
```

and import `sql_v18.gpr` from their project. The Ada API remains
`Flyology.Postgres.SQL.AST.V18`; selecting a crate changes the compilation
closure, not the generated package names. Version crates share
`flyology_postgres_sql_core`, so a V18-only build compiles the common scanner,
LALR runtime, and semantic helpers once plus only the V18 grammar, schema, AST,
views, visitors, and catalog metadata.

The `flyology_postgres_sql` crate and `sql.gpr` remain the compatibility
umbrella for applications that select PostgreSQL versions at runtime. They
depend on all five version crates. V14 through V18 can also be combined by
depending on just the desired version crates and importing their corresponding
`sql_vNN.gpr` projects.

```toml
[[depends-on]]
flyology_postgres_sql_v14 = "*"
flyology_postgres_sql_v18 = "*"
```

```ada
with "sql_v14.gpr";
with "sql_v18.gpr";
project My_Application is
   --  with Flyology.Postgres.SQL.AST.V14 and AST.V18 from Ada sources.
end My_Application;
```

Both version libraries import the same `sql_core.gpr`; GPR and Alire resolve
that shared core once. The generated AST types remain deliberately distinct
between majors.

## Owned Ada ASTs

`Flyology.Postgres.SQL.AST.V14` through `AST.V18` are the primary consumer API.
Each version parses directly into an ordinary, recursively navigable Ada object
graph:

- every reachable protobuf message is a generated public record;
- `Node` is a generated discriminated record whose variant embeds the concrete
  PostgreSQL node record;
- optional fields retain their generated `Present` discriminant;
- repeated fields are typed `Ada.Containers.Vectors`;
- strings are owned `Unbounded_String` values; and
- recursive fields are typed Ada access values such as `Node_Access` and
  `Select_Stmt_Access`.

An `Owned_Syntax_Tree` is limited and controlled. It owns the complete graph and
releases it on `Clear`, replacement, or finalization. The access values and
vectors in its records remain valid until that owning tree is cleared, parsed
into again, or finalized. Consumers must not deallocate or graft those access
values into a different owner.

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

### Generated visitors

Each owned version has a generated visitor child package, for example
`Flyology.Postgres.SQL.AST.V18.Visitors`. Derive a state-bearing type from
`Visitor` and override only the typed hooks of interest. `Traverse` performs a
depth-first walk in protobuf field order and follows every present message
field and every message element of a typed vector.

```ada
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Visitors;

declare
   package AST renames Flyology.Postgres.SQL.AST.V18;
   package Visitors renames Flyology.Postgres.SQL.AST.V18.Visitors;

   type Select_Counter is new Visitors.Visitor with record
      Selects : Natural := 0;
      Targets : Natural := 0;
   end record;

   overriding procedure Enter_Select_Stmt
     (Self    : in out Select_Counter;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Select_Stmt
     (Self    : in out Select_Counter;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      Self.Selects := Self.Selects + 1;
      Self.Targets := Self.Targets + Natural (Item.Target_List.Length);
   end Enter_Select_Stmt;

   Tree    : AST.Owned_Syntax_Tree;
   Counter : Select_Counter;
begin
   AST.Parse
     ("WITH q AS (SELECT id FROM events) SELECT id FROM q", Tree);
   if Tree.Valid then
      Visitors.Traverse (Counter, Tree);
   end if;
end;
```

Every reachable protobuf message has matching generated `Enter_*` and
`Leave_*` hooks. `Enter_Node` and `Leave_Node` provide a common hook around the
discriminated `Node` wrapper; the concrete hook, such as
`Enter_Select_Stmt`, runs inside it. An enter hook receives
`Continue_Traversal` initially and may set `Skip_Children` to prune that
message's descendants or `Stop_Traversal` to end the entire walk. A skipped
message still receives its leave hook; a stopped traversal does not unwind
leave hooks.

Visitors borrow the object graph and never take ownership. Their callbacks
must not free, graft, or mutate access values. Traversal assumes the
parser-produced acyclic graph remains intact for the call; references remain
subject to the owning `Owned_Syntax_Tree` lifetime. Exceptions raised by a
callback propagate immediately and do not guarantee balanced leave hooks.

### Analysis and transformation passes

Runnable PostgreSQL 18 examples live in `examples/`:

- `analyze_sql.adb` accumulates statement, target, relation, join, column, and
  function-call facts in visitor state. With no argument it analyzes its built-in
  CTE/join query; one command-line argument replaces that SQL text.
- `transform_sql_ast.adb` uses a visitor to collect owned references into a
  rewrite plan, then renames a relation and redacts string literals in a second
  pass.

```sh
cd sql/examples
alr -n build
./scripts/test.sh

# Analyze another statement. Quote it as one shell argument.
./bin/analyze_sql "SELECT count(*) FROM audit.events"
```

Analysis belongs directly in `Enter_*` and `Leave_*` callbacks: keep counters,
sets, stacks, or reports in the derived visitor. Use `Skip_Children` when a
matched subtree cannot contribute more facts, and `Stop_Traversal` when one
answer is enough.

AST transformations should use two passes. The traversal pass observes records
and retains only child access values already owned by the tree. After traversal
finishes, the apply pass changes scalar, enum, optional, or string payloads
through those references. Do not resize vectors, replace node discriminants,
change access topology, or attach objects from another owner while walking.
Every retained reference is valid only while its `Owned_Syntax_Tree` remains
alive and uncleared.

This transforms the in-memory raw AST, not the original SQL text:
`Source_Text` remains the input, and this crate does not currently provide a
deparser. A tool that needs rewritten SQL should either emit its own target
representation or pair the rewrite plan with a dedicated SQL printer. The same
patterns work for V14 through V17 by changing the two versioned package names;
the visitor surfaces are generated from each version's checked-in schema.

`AST.Parse` is the sole owned parser entry point. It writes from the native
semantic builder directly to the owned records and never constructs an
intermediate shallow arena. Arena materialization and exhaustive structural
comparison exist only in the test project as an independent validation
baseline; they are not installed consumer APIs.

## Advanced shallow views

Consumers optimizing for fewer allocations can explicitly opt into
`Flyology.Postgres.SQL.Views`. `Syntax_Tree` is limited and owns a flat Ada
arena. `Views.V14` through `Views.V18` expose opaque `*_Reference` values,
public shallow record views, and opaque `Sequence_Of_*` handles.

```ada
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.Views;
with Flyology.Postgres.SQL.Views.V18;

declare
   package SQL renames Flyology.Postgres.SQL;
   package Views renames Flyology.Postgres.SQL.Views;
   package V18 renames Flyology.Postgres.SQL.Views.V18;

   Tree : Views.Syntax_Tree;
begin
   Views.Parse ("select id, payload from events", SQL.PostgreSQL_18, Tree);

   if Views.Is_Valid (Tree) then
      declare
         Item : constant V18.Node_Reference :=
           V18.Statement
             (Tree,
              V18.Element
                (Tree, V18.Statements (Tree, V18.Root (Tree)), 1));
         Select_Ref : constant V18.Select_Stmt_Reference :=
           V18.As_Select_Stmt (Tree, Item);
         Statement : constant V18.Select_Stmt := V18.View (Tree, Select_Ref);
      begin
         null;
      end;
   end if;
end;
```

Elaborating a versioned `Views.VNN` package registers that version with the
generic `Views.Parse` dispatcher. An application using the all-version umbrella
but dispatching only through the unversioned `Views` package should also add a
context clause for `Flyology.Postgres.SQL.All_Versions`; elaborating that
package registers all five backends. Calling generic `Views.Parse` for a backend
that was not linked and registered raises `Parser_Backend_Error` with an
actionable message—it never falls back to another PostgreSQL grammar.

Every non-repeated field has a definite discriminated `Optional_*` wrapper.
Repeated fields appear directly as typed sequence handles. Scalars and enums
are ordinary Ada values, strings are owned `Unbounded_String` values, and child
messages remain opaque references.

### Reference lifetime

A reference or sequence is meaningful only with the exact `Syntax_Tree` that
created it. Calling `Views.Parse` again on that tree invalidates all earlier
references and sequence handles. Scalar, enum, and owned text components copied
into a view remain ordinary Ada values, but references and sequences contained
in that view retain the tree lifetime rule.

## Version and option behavior

Select the owned package matching the required PostgreSQL major. Advanced
shallow consumers pass the same `Major_Version` to `Views.Parse` and then use
the matching `Views.V14`–`Views.V18` package. PostgreSQL 15–18 support the
parser-mode and lexer-GUC fields in `Parse_Options`. The PostgreSQL 14
extraction predates that upstream API; non-default options raise
`Unsupported_Parse_Options` instead of being silently ignored.

Normal parsing is entirely Ada: it does not call `libpg_query`, serialize
protobuf, or cross a C boundary. The isolated C backends remain private test
oracles. They parse the same corpus through PostgreSQL and protobuf so the test
suite can compare the two logical arenas exactly, including field presence and
diagnostic positions. Protobuf bytes, C pointers, native ownership, and arena
identifiers are not part of the public API.

## Native parser architecture

The primary production pipeline is:

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
reductions. Semantic values are stored in a private flat builder. Generated
schema-aware converters then produce either the primary owned records or the
advanced shallow arena without involving C or protobuf. The explicitly
selected `Views.Parse` path shares this parser front end and maps into a flat
`Syntax_Tree` arena instead.

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
the data. These units and their native libraries are compiled by
`tests/sql_oracle.gpr`, not by production `sql.gpr`. The test action also checks
the production archive for oracle, protobuf-decoder, and C-wrapper symbols.

As in the pinned PostgreSQL parser sources, SQL text is interpreted as UTF-8
when converting a diagnostic's internal byte offset to its public, 1-based
character position.

## Catalog types

`Flyology.Postgres.Types` provides version-dispatched lookup by OID or catalog
name. `Types.V14` through `Types.V18` provide generated OID constants. A
`Type_Descriptor` exposes kind, category, storage, alignment, passing mode,
length form, preferred status, element OID, and array OID.

The catalog inputs are the current supported PostgreSQL releases used by this
repository: 14.23, 15.18, 16.14, 17.10, and 18.4. Their official source archive
SHA-256 values and source URLs are recorded under `catalog/v*/UPSTREAM.toml`.

## Reproducible generation

The generated `V14`–`V18` units are never edited by hand. Eight generators form
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
- `generate_owned_visitors.py` emits exhaustive depth-first owned-AST visitors,
  typed enter/leave hooks, and pruning/stop control for every reachable message.
- `generate_owned_parser.py` combines the protobuf schema with Clang-derived
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
  --output src \
  --oracle-output tests/oracle/src

python3 tools/generate_types.py \
  --major 18 \
  --catalog catalog/v18/pg_type.dat \
  --output src

python3 tools/generate_owned_ast.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output src

python3 tools/generate_owned_visitors.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output src

python3 tools/generate_owned_parser.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --vendor backends/v18/vendor \
  --output src

python3 tools/generate_owned_equivalence.py \
  --major 18 \
  --proto backends/v18/vendor/pg_query.proto \
  --output tests/src

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

`tools/generate_build_layout.py` generates the version registration adapters
and the complete deterministic GPR source lists for the shared core, V14–V18,
and compatibility umbrella. Its classifier uses stable `_vNN`/`-vNN` filename
markers; version-neutral generated action catalogs and runtime units belong to
the core. Run it with `--check` to detect an unclassified or stale project
layout without rewriting files.

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
used by the oracle; all five shallow and owned typed roots; generated visitors,
typed callbacks, pruning and stopping; field notation, optionals, vectors,
nested owned nodes, enum fields, ownership replacement, and diagnostics. Each
owned result is exhaustively compared with the test-only
arena-materialized baseline, which is itself checked against the version-pinned
C oracle. The differential corpus
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
generator can reproduce it exactly; it is not a prerequisite for the native
runtime paths.

The owned AST is the default natural-navigation representation. The shallow
arena remains an explicit advanced choice for consumers that value fewer
allocations enough to manage reference lifetimes themselves.
