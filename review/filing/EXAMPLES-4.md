Title: psqlish raises Constraint_Error on a zero-column result and abandons the connection
Labels: bug
Refs: EXAMPLES-11

## Summary

`psqlish` narrows the library's `Natural`-valued `Protocol.Field_Count` and `Protocol.Column_Count` to `Positive` in two declarations. A zero-field RowDescription is legal on the wire, and real PostgreSQL produces one for `SELECT;`, so the range check fails, `Constraint_Error` leaves `Execute_Query`, `Run`'s handler closes the socket without sending Terminate and re-raises, and the process prints an unhandled-exception report and exits nonzero. An interactive session is destroyed where `psql` prints an empty result and carries on.

## Problem

Commit `6f496f5`.

The two narrowings (`examples/psqlish/src/psqlish_main.adb:230-236`):

```ada
               when Protocol.Row_Description_Response =>
                  declare
                     Description : constant Protocol.Row_Description :=
                       Protocol.Description (Event);
                     Count : constant Positive :=
                       Protocol.Field_Count (Description);
                     Columns : Display.Column_Array (1 .. Count);
```

and (`examples/psqlish/src/psqlish_main.adb:258-264`):

```ada
               when Protocol.Data_Row_Response =>
                  declare
                     Row : constant Protocol.Data_Row :=
                       Protocol.Row_Data (Event);
                     Count : constant Positive :=
                       Protocol.Column_Count (Row);
                     Values : Display.Cell_Array (1 .. Count);
```

The library declares both accessors as returning `Natural`, and documents the value as a count with no lower bound (`src/flyology-postgres-protocol.ads:370-373`):

```ada
   function Field_Count (Item : Row_Description) return Natural;
   --  Return the number of described result fields.
   --  @param Item Row metadata to inspect.
   --  @return Number of fields.
```

and (`src/flyology-postgres-protocol.ads:414-417`):

```ada
   function Column_Count (Item : Data_Row) return Natural;
   --  Return the number of values in a decoded row.
   --  @param Item Row to inspect.
   --  @return Number of columns.
```

A zero-field RowDescription is reachable. PostgreSQL accepts `SELECT;`, whose target list is empty, and answers with a RowDescription of zero fields followed by a DataRow of zero columns; `psql` renders that as `--` and `(1 row)`. The companion server produces the same three messages for `SELECT *` with no FROM clause, which is a separate defect reported in {{ISSUE:EXAMPLES-11}} and is the input a user is most likely to type into this client.

Once the check fails, the failure is not contained. `Run`'s handler closes the socket without a Terminate message and re-raises (`examples/psqlish/src/psqlish_main.adb:516-522`):

```ada
   exception
      when others =>
         --  Do not send Terminate after a protocol/transport failure.
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
```

and the top-level handler prints the whole occurrence and sets a failure status (`examples/psqlish/src/psqlish_main.adb:543-545`):

```ada
   when Error : others =>
      Put_Error (Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
```

The psqlish README states that empty and command-only responses are handled (`examples/psqlish/README.md:144-147`):

> Notices and errors include severity and SQLSTATE. Parameter-status events that occur during a query are printed as `PARAMETER name = value`. Empty queries, command-only responses, multiple statements, and errors followed by `ReadyForQuery` all have explicit handling.

The display layer is not the problem: `Psqlish.Display.Begin_Result` accepts an empty `Column_Array` and renders the command tag alone. The nested psqlish suite exercises the display layer directly (`examples/psqlish/tests/src/fixture_tests.adb:84-104`) and never constructs a result with zero columns, and no test drives the two declarations in the client main at all.

## What happens now

Spike: the program builds a RowDescription payload whose Int16 field count is zero and a DataRow payload whose Int16 column count is zero, decodes both through `Flyology.Postgres.Protocol.Decode_Backend`, confirms the library reports zero for each, and then evaluates the two narrowing declarations copied from the client main. It finally renders a zero-column result through the display layer to show where the defect is not.

```ada
   --  RowDescription payload: Int16 field count = 0.
   Zero_Fields : constant Protocol.Byte_Array := (0, 0);
   --  DataRow payload: Int16 column count = 0.
   Zero_Columns : constant Protocol.Byte_Array := (0, 0);

   Row_Event : constant Protocol.Backend_Message :=
     Protocol.Decode_Backend (Protocol.Make_Message ('T', Zero_Fields));
...
      declare
         Count   : constant Positive := Protocol.Field_Count (Description);
         Columns : Display.Column_Array (1 .. Count) :=
           (others => Display.Make_Column ("x"));
```

```
  ok: a zero-field RowDescription decodes as RowDescription
  ok: the library reports Field_Count = 0 (Natural, not Positive)
  ok: the library reports Column_Count = 0 (Natural, not Positive)
  -- psqlish_main.adb:234 raised CONSTRAINT_ERROR : range check failed
  FAILED: psqlish accepts a zero-field RowDescription
  -- psqlish_main.adb:262 raised CONSTRAINT_ERROR : range check failed
  FAILED: psqlish accepts a zero-column DataRow
  -- Display renders a zero-column result as: "SELECT 1
"
  ok: Psqlish.Display already accepts an empty Column_Array
BUG REPRODUCED: 2 failed expectation(s)
```

The three control checks passing first establish that the message is well formed, that the library decodes it, and that the display layer copes, so the failure is isolated to the two narrowings.

The `psqlish` binary itself was not run: it is not built in this tree, and the demonstration above is at the library and declaration level. The reachability of a zero-field RowDescription was confirmed separately on the wire against the running `examples/pgish/bin/flyology_pgish`, which answers `SELECT *` with `RowDescription fields=0`, `DataRow []` and `CommandComplete 'SELECT 1'` ({{ISSUE:EXAMPLES-11}}).

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A zero-field RowDescription and a zero-column DataRow are legal protocol messages, and the library reports both counts as `Natural` (`src/flyology-postgres-protocol.ads:370`, `:414`). The client should display an empty result and stay in the read-evaluate-print loop, as `psql` does for `SELECT;`, rather than raising `Constraint_Error`, dropping the connection without Terminate, and exiting.

## Suggested treatment

Declare both counts as `Natural` and give the arrays a `1 .. Count` range that can be empty:

```ada
   Count : constant Natural := Protocol.Field_Count (Description);
   Columns : Display.Column_Array (1 .. Count);
```

The loops over `Columns'Range` and `Values'Range` already iterate zero times for an empty range, and `Display.Begin_Result` already accepts an empty `Column_Array`, so no other change in the client is needed.

The regression test belongs in `examples/psqlish/tests/src/fixture_tests.adb` beside the expanded-output assertions (`examples/psqlish/tests/src/fixture_tests.adb:84-104`), decoding a zero-field RowDescription and a zero-column DataRow and rendering the result. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

The client dies on a legal server response: unhandled exception report, socket closed without Terminate, nonzero exit, interactive session gone. It takes a zero-column result, which needs `SELECT;` on real PostgreSQL or `SELECT *;` against the companion server, so it is not what an ordinary query produces, but it is one keystroke away for a user experimenting at the prompt and the companion server reaches it through a documented statement shape. Deterministic.
