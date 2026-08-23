---
description: Preserve Flyology Postgres's project-specific repository rules and verification workflow.
---

# Repository agent instructions

## Website documentation

Hand-written Guide, Architecture, and Journal pages follow
`website/AGENTS.md`. Link the first explanatory mention of each public
Flyology Postgres API entity on a page to its verified generated GNATdoc unit
or declaration entry.

## Releases

- Automatic index publication is driven by immutable annotated tags named
  `<crate>/v<version>`, such as `flyology_postgres/v0.1.0`.
- Before tagging, set the released crate's `alire.toml` to the exact stable
  version, replace inappropriate `-dev` dependency constraints with stable
  constraints, and run its required checks plus `alr show`. Its manifest name
  and version must exactly match the tag.
- Indexed crates in this repository are `flyology_postgres`,
  `flyology_postgres_sql`, `flyology_postgres_sql_core`, and
  `flyology_postgres_sql_v14` through `flyology_postgres_sql_v18`. Tag each
  released crate independently, even when several tags point to one monorepo
  commit.
- Create and push the tag only after committing the release-ready manifests:

  ```sh
  git tag -a <crate>/v<version> -m "Release <crate> <version>"
  git push origin refs/tags/<crate>/v<version>
  ```

- Never move, replace, or reuse a published release tag. Put the next
  development-version change in a later commit.

## SQL parser changes

The supported consumer parser is the generated owned AST API in
`Flyology.Postgres.SQL.AST.V14` through `V18`. Each package exposes one `Parse`
operation. Treat `Flyology.Postgres.SQL.Views` as the explicit shallow-arena
alternative, not as a competing default API.

Earlier parser representations remain deliberately available under
`sql/tests/` as validation layers. Use them to localize a defect, but do not
move them back into the production project or expose their entry points to
consumers.

### Required test commands

For a quick edit/build loop:

```sh
cd sql/tests
alr -n build
./bin/sql_tests
```

Before completing any SQL parser, AST, generator, schema, or native-backend
change, run the complete suite:

```sh
cd sql/tests
./scripts/test.sh
```

The complete script verifies generated files for PostgreSQL 14 through 18,
audits generated semantic actions, builds under the strict Ada 2022 switches,
checks that the production archive contains no C/protobuf-oracle symbols,
checks each native wrapper's exact export set, and runs the runtime suite.

Parser changes that can affect pgish must also pass:

```sh
cd examples/pgish
alr -n build
./scripts/test.sh
```

This includes the unit suite, extended-query integration, and real
`psql`-to-pgish integration. In an isolated worktree, a missing sibling
`flyology` checkout may require temporarily resolving the root Alire pin to an
existing checkout. Never commit a machine-specific absolute pin.

### Validation ladder

Diagnose from the public result downward. Use the first layer that diverges to
identify the faulty implementation.

1. **Owned AST:** `AST.V*.Parse` is the production result being tested.
2. **Shallow arena baseline:** the test-only `AST.V*.Testing.Parse_Baseline`
   parses through `SQL.Views`, materializes the arena, and
   `AST.V*.Testing.Equivalent` compares the complete owned graphs, including
   node variants, vectors, scalar values, enum values, optional presence,
   source text, version, and diagnostics.
3. **Native arena versus C oracle:**
   `Flyology.Postgres.SQL.Differential_Testing` parses identical SQL through
   the native Ada arena and the version-pinned C/protobuf oracle.
   `Internals.First_Difference` prints the first logical arena path that
   differs.
4. **Low-level components:** `Native_Testing` exercises the builder, scanner,
   LALR engine, and reductions. `Decoder_Testing` exercises protobuf wire
   decoding and malformed input. The isolated C wrappers and generated
   decoders live in `sql/tests/oracle/`.

The full runtime order is visible in `sql/tests/src/sql_tests.adb`. The broad
owned corpus is in `sql/tests/src/owned_ast_tests.adb`; the native/C arena
corpus is in
`sql/tests/src/flyology-postgres-sql-differential_testing.adb`.

### Interpreting failures

- If owned parsing differs from `Parse_Baseline`, but native/C arena
  differential tests pass, inspect `generate_owned_parser.py`,
  `generate_owned_ast.py`, and the generated builder-to-owned conversion.
- If the native arena differs from the C oracle, use the path printed by
  `First_Difference`. Scanner or syntax/diagnostic differences normally point
  to `generate_native_parser.py`, `generate_native_actions.py`, or the native
  scanner/LALR runtime. Correct syntax with a wrong arena shape normally points
  to `generate_native_schema.py`, `Native.Converters`, or `Arena_Storage`.
- If only the C baseline or malformed-wire tests fail, inspect the
  version-prefixed wrapper, `C_Oracle`, `Decoders`, and the generated
  `Decoder_V*` under `sql/tests/oracle/`. These are oracle failures, not a
  reason to add protobuf to the production closure.
- If all parser comparisons pass but pgish fails, debug the consumer boundary
  in `examples/pgish/src/pgish_sql.adb` and run the pgish suite independently.
- Always reproduce a failure with the smallest SQL string and the narrowest
  affected PostgreSQL version. Then add that input to both the owned baseline
  corpus and native/C differential corpus when applicable. Remember that
  `MERGE` begins with PostgreSQL 15.

For a difficult owned-graph mismatch, temporarily set `TRACE_MISMATCH = True`
in `sql/tools/generate_owned_equivalence.py`, regenerate the affected
`AST.V*.Testing` package, and rerun `sql_tests`. The comparator will print the
first owned field path that differs. Restore the flag to `False` and regenerate
before committing.

### Generated-source discipline

Do not hand-edit generated version packages. Fix their schema input, upstream
input, or generator, then regenerate every affected major.

- `generate_ada.py`: shallow `SQL.Views.V*` declarations and test-only
  protobuf decoders.
- `generate_owned_ast.py`: owned records, node variants, vectors, optionals,
  cleanup, and arena materialization support.
- `generate_owned_visitors.py`: exhaustive typed traversal hooks and walk logic
  for the owned records.
- `generate_owned_parser.py`: production native-builder-to-owned parsing.
- `generate_owned_equivalence.py`: test-only baseline and exhaustive owned
  comparison.
- `generate_native_parser.py`: scanner and LALR tables/runtime bindings.
- `generate_native_actions.py`: audited semantic reductions.
- `generate_native_schema.py`: native semantic schema metadata.

`pg_query.proto` is the source of truth for the versioned public AST shape and
protobuf oracle decoder. The checked-in PostgreSQL grammar, scanner, headers,
and source definitions are the source of truth for native parsing behavior.

After changing a generator, generate twice and verify that the second run
changes no files. Run the generator `--check` path through
`sql/tests/scripts/test.sh` before completion. Preserve the test-only
`sql_oracle.gpr` boundary and its production archive-symbol assertion.
