Title: flyology_pgish option and environment errors escape the main handler and print a GNAT traceback
Labels: bug
Refs: SERVER-1

## Summary

`flyology_pgish` elaborates `Options : constant Parsed_Configuration := Read_Configuration;` in the main procedure's declarative part. `Read_Configuration` raises `Constraint_Error` for every invalid option and for a non-numeric port in the environment. RM 11.2 places the declarative part outside the frame's own handlers, so the handler that prints `flyology_pgish: <message>` and sets a failure status never runs. Users get GNAT's unhandled-exception report with a load address and raw traceback addresses instead of the intended one-line diagnostic.

## Problem

Commit `6f496f5`.

The declaration (`examples/pgish/src/flyology_pgish.adb:136`):

```ada
   Options : constant Parsed_Configuration := Read_Configuration;
```

`Read_Configuration` raises `Constraint_Error` for an option with no value (`examples/pgish/src/flyology_pgish.adb:67`), an unknown option (`:97`), an out-of-range port (`:102-104`), a bad task mode (`:105-108`) and a lone `--tls-cert` or `--tls-key` (`:109-114`):

```ada
      if Port not in 1 .. 65_535 then
         raise Constraint_Error with "port must be in 1 .. 65535";
      end if;
      if SQL.Image (Task_Mode) not in "lightweight" | "native" then
         raise Constraint_Error with
           "task mode must be lightweight or native";
      end if;
```

and `Integer'Value` raises it for a non-numeric `--port` argument or `FLYOLOGY_PGISH_PORT` value.

The handler that was written for exactly these messages is at the end of the same procedure (`examples/pgish/src/flyology_pgish.adb:242-249`):

```ada
exception
   when Error : others =>
      Pgish_Signals.Complete;
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "flyology_pgish: " &
         Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Flyology_Pgish;
```

Per RM 11.2, the handlers of a handled sequence of statements do not cover exceptions raised during the elaboration of the declarative part of the same body, so this handler cannot see any of them. The exception propagates out of the main subprogram and the runtime prints its own report. The same mechanism appears in the library's own session code and is reported separately in {{ISSUE:SERVER-1}}.

No test invokes the binary with an invalid option. The real `psql` integration script starts the server with valid environment variables only (`examples/pgish/scripts/run-integration.sh:51-56`), and `examples/pgish/src/pgish_tests.adb` never calls `Read_Configuration`.

## What happens now

There is no spike for this one: the defect is in the declarative part of a main procedure and cannot be reached from a test program, so the prebuilt binary was run directly under `timeout` from the repository root.

```
### --port abc

Execution of ./examples/pgish/bin/flyology_pgish terminated by unhandled exception
raised CONSTRAINT_ERROR : bad input for 'Value: "abc"
Load address: 0x104434000
Call stack traceback locations:
0x104d17c68 0x104d17cc8 0x104d473b0 0x104d465a0 0x104d465d4 0x10443cc2c 0x10443dd2c 0x104d63134
exit=1

### --bogus

Execution of ./examples/pgish/bin/flyology_pgish terminated by unhandled exception
raised CONSTRAINT_ERROR : unknown option: --bogus
Load address: 0x102c50000
Call stack traceback locations:
0x103533c68 0x103533cc8 0x102c58f8c 0x102c59d2c 0x10357f134
exit=1

### --port 70000

Execution of ./examples/pgish/bin/flyology_pgish terminated by unhandled exception
raised CONSTRAINT_ERROR : port must be in 1 .. 65535
Load address: 0x100678000
Call stack traceback locations:
0x100f5bc68 0x100f5bcc8 0x100680ff8 0x100681d2c 0x100fa7134
exit=1

### FLYOLOGY_PGISH_PORT=x

Execution of ./examples/pgish/bin/flyology_pgish terminated by unhandled exception
raised CONSTRAINT_ERROR : bad input for 'Value: "x"
Load address: 0x102804000
Call stack traceback locations:
0x1030e7c68 0x1030e7cc8 0x1031173b0 0x1031165a0 0x1031165d4 0x10280c900 0x10280dd2c 0x103133134
exit=1
```

The messages the handler was written to print are visible inside the runtime's report, which is what shows that the handler is being skipped rather than that the message is missing. The `--task-mode weird` and lone `--tls-cert` cases produce the same shape, each with its own message. No server is left running: `Shutdown_Watcher` is never activated when the declarative part fails, and the process exits 1 in every case.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

An invalid option or environment value should produce the diagnostic the program already writes, `flyology_pgish: unknown option: --bogus` on standard error, with a failure exit status and no traceback. The handler at `examples/pgish/src/flyology_pgish.adb:242-249` should cover configuration errors.

## Suggested treatment

Move the elaboration into the statement part so the handler covers it. `Options` is read by the `Example_Server` instantiation at `examples/pgish/src/flyology_pgish.adb:138-149` and by the server setup, so the smallest change that keeps the instantiation valid is to make `Options` a variable with a default value and assign `Read_Configuration` at the top of the statement part, or to wrap the declaration in an inner block with its own handler that prints the message and sets the failure status before returning.

The regression test belongs in `examples/pgish/scripts/run-integration.sh`, next to the server startup block (`examples/pgish/scripts/run-integration.sh:51-56`), running the binary once with an invalid option and asserting the exact `flyology_pgish: unknown option: --bogus` line and exit status 1. No existing test asserts the current behaviour, so none has to change.

## Severity

Wrong diagnostics on invalid input. The user still learns what was wrong, because the message is embedded in the runtime report, but it arrives with a load address and raw traceback addresses that suggest a crash rather than a typo. The process still exits nonzero and no server is left running, so nothing beyond the diagnostic is affected. It needs an invalid command-line option or environment value. Deterministic.
