# Example-crate bug reproduction programs

Each `src/repro_examples_<id>.adb` demonstrates one finding from the
correctness review against the `pgish` or `psqlish` example crates. A program
asserts the CORRECT behavior, so on the current sources it prints
`BUG REPRODUCED` and exits 1; after a fix it prints `PASS` and exits 0. A hang
is reported as exit 124 by the `timeout` wrapper.

```sh
cd examples/repros
./run.sh repro_examples_<id>          # build one program and run it (60 s limit)
./run.sh repro_examples_<id> 10       # custom time limit in seconds
```

The example crates' packages (`Pgish_SQL`, `Pgish_Catalog`, `Pgish_State`,
`Pgish_Handler`, `Psqlish.Display`, `Psqlish.Input`, `Psqlish.Options`) are on
the source path directly from `../pgish/src` and `../psqlish/src`, so a
program drives them exactly as `pgish_tests.adb` does, without a socket.
`src/example_repro_support.ad?` provides `Check`/`Note`/`Finish`.
