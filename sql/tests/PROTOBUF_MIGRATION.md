# Protobuf migration validation

The JSON implementation was retained outside the production crate long enough
to compare it with the generated Ada protobuf decoder. On 2026-08-04, the
pinned `libpg_query` release for each PostgreSQL major was built in a temporary
directory with both its legacy JSON and protobuf entry points. Sixteen cases
per major (80 total) produced equivalent logical trees or identical diagnostics.

The corpus covered scalar defaults, valid and invalid statements,
multi-statement input, quoted identifiers, Unicode, comments, dollar-quoted
strings, CTEs, joins, DDL, utility statements, and syntax specific to each
major. Proto3 default-valued scalar fields were normalized according to wire
semantics: an omitted scalar carries no presence bit. Separate low-level tests
verify that an explicitly encoded scalar zero is retained as present.

Embedded NUL input cannot be represented faithfully by the upstream C-string
API. The owned `AST.V*.Parse` and advanced `Views.Parse` operations reject it
before parsing and report its exact byte position. This behavior is covered by
the permanent parser tests.

After the comparison passed, the JSON emitter, JSON accessor, Ada JSON loader,
and GNATCOLL.JSON dependency were removed. The temporary comparison program and
dual-path native builds are not part of this repository.
