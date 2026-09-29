# SQL bug reproduction programs

Each `src/repro_sql_<id>.adb` demonstrates one SQL-parser finding from the
correctness review. A program asserts the CORRECT behavior, so on the current
sources it prints `BUG REPRODUCED` and exits 1; after a fix it prints `PASS`
and exits 0. A hang is reported as exit 124 by the `timeout` wrapper.

```sh
cd sql/tests/repros
./run.sh repro_sql_<id>          # build one program and run it (60 s limit)
./run.sh repro_sql_<id> 10       # custom time limit in seconds
```

`src/sql_repro_support.ad?` provides `Check`/`Note`/`Finish` plus helpers
that parse through the native arena (`Native_Error`,
`Native_Error_Position`), through the version-pinned C/protobuf oracle
(`Oracle_Error`, `Oracle_Error_Position`), and compare the two arenas
(`Oracle_Difference`, which returns the first differing logical path or ""
when they agree, exactly as the differential suite asserts). The owned AST is
reachable directly through `Flyology.Postgres.SQL.AST.V14`–`V18`, and the
test-only validation layers under `sql/tests/src` are on the source path.

The C oracle is test-only. Nothing here belongs in the production closure.
