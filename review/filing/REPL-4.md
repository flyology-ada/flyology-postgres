Title: Replication SHOW rejects the dotted GUC names PostgreSQL's replication grammar accepts
Labels: bug
Refs: none

## Summary

The replication `SHOW` constructor and decoder both validate the parameter with `Is_Option_Name`, which admits only letters, digits and underscore. PostgreSQL's replication grammar builds a dotted GUC name explicitly, so `SHOW myext.my_setting` is valid on every supported major. A caller asking for a namespaced extension GUC, or a Flyology server decoding such a `SHOW`, gets `Protocol_Error` for a parameter PostgreSQL would answer.

## Problem

Commit `6f496f5`.

`Is_Option_Name` forbids the dot (`src/flyology-postgres-replication.adb:100-104`):

```ada
   function Is_Option_Name (Name : String) return Boolean is
     (Name'Length > 0
      and then
        (for all Item of Name =>
           Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'));
```

The constructor applies it (`src/flyology-postgres-replication.adb:183-189`):

```ada
   function Show (Parameter : String) return Protocol.Message is
   begin
      Require
        (Is_Option_Name (Parameter),
         "invalid replication SHOW parameter name");
      return Query ("SHOW " & Parameter);
   end Show;
```

and so does `Decode_Command`'s SHOW branch (`src/flyology-postgres-replication.adb:503-514`):

```ada
      elsif Is_Keyword (First, "SHOW") then
         Result.Message_Kind := Show_Command;
         declare
            Name : constant String := Next_Token (Text, Cursor);
         begin
            Require
              (Is_Option_Name (Name),
               "invalid replication SHOW parameter name");
```

PostgreSQL's replication grammar assembles a dotted name from the parts. `src/backend/replication/repl_gram.y` 18.4:153-164, identical at 14.23:141-152:

```
show:
			K_SHOW var_name
				{
					VariableShowStmt *n = makeNode(VariableShowStmt);
					n->name = $2;
					$$ = (Node *) n;
				}

var_name:	IDENT	{ $$ = $1; }
			| var_name '.' IDENT
				{ $$ = psprintf("%s.%s", $1, $3); }
		;
```

The scanner returns the dot as itself, so it reaches that rule (`src/backend/replication/repl_scanner.l` 18.4:211-214):

```
.				{
					/* Any char not recognized above is returned as itself */
					return yytext[0];
				}
```

`SHOW myext.my_setting` is therefore valid replication-mode syntax on every supported major, and a namespaced name is the standard way a PostgreSQL extension exposes a setting.

No stock PostgreSQL client sends a dotted `SHOW`. The only replication-mode `SHOW` commands in the PostgreSQL tree are `SHOW wal_segment_size` and `SHOW data_directory_mode`, both issued by `src/bin/pg_basebackup/streamutil.c` (18.4:293 and 18.4:367), and neither is dotted. This is a rejection of valid input rather than a default-path interop break.

The contract broken is `src/flyology-postgres-replication.ads:161-166`:

```ada
   function Decode_Command (Item : Protocol.Message) return Command;
   --  Decode the command grammar emitted by PostgreSQL and the constructors in
   --  this package.
```

The tests do not catch it because every `SHOW` in the suite uses an undotted core GUC: `tests/src/replication_tests.adb:217-219` checks the constructor's text for `wal_level`, and `tests/src/replication_tests.adb:392-400` decodes the same command back. `tests/src/postgres_test_replication.adb:191` uses `wal_level` as well.

One related case is worth deciding at the same time. `Is_Option_Name` also rejects `$` and 8-bit bytes, which PostgreSQL's identifier rule allows (`repl_scanner.l` 18.4:107, `ident_cont [A-Za-z\200-\377_0-9\$]`). Any fix to the character set should decide those two cases at the same time.

## What happens now

Spike: the program calls `Replication.Show` with a namespaced GUC name and separately passes the query text PostgreSQL accepts to `Decode_Command`, asserting that the constructor renders it verbatim and that the decoder exposes the complete dotted name. `SHOW wal_segment_size` is round-tripped first as a control.

```ada
   Guc : constant String := "myext.my_setting";
...
         Command : constant Protocol.Message := Replication.Show (Guc);
      begin
         Constructor_Built := True;
         Constructor_Text := Query_Text (Command) = "SHOW " & Guc;
...
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query ("SHOW " & Guc));
      begin
         Decoder_Accepted :=
           Replication.Kind (Item) = Replication.Show_Command;
         Decoder_Parameter := Replication.Parameter (Item) = Guc;
```

Output:

```
  -- control: SHOW wal_segment_size decodes with parameter wal_segment_size
  -- constructing Replication.Show ("myext.my_setting")
  --   Show raised Protocol_Error: invalid replication SHOW parameter name
  -- decoding the query text PostgreSQL accepts: SHOW myext.my_setting
  --   Decode_Command raised Protocol_Error: invalid replication SHOW parameter name
  ok: harness sanity check: SHOW wal_segment_size still round-trips
  FAILED: Replication.Show accepts a namespaced GUC name
  FAILED: and renders it verbatim as SHOW myext.my_setting
  FAILED: Decode_Command classifies SHOW myext.my_setting as a SHOW command
  FAILED: and exposes the complete dotted parameter name
BUG REPRODUCED: 4 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23 and 18.4 server sources used for reference.

## What should happen

Both `Show` and `Decode_Command` should accept a GUC name of the shape `var_name` accepts, that is one or more identifiers joined by dots, and `Parameter` should return the complete dotted name, because `repl_gram.y` 18.4:161-164 builds exactly that name and PostgreSQL answers it.

## Suggested treatment

Add a separate predicate for a replication GUC name, next to `Is_Option_Name` at `src/flyology-postgres-replication.adb:100-104`, that accepts a non-empty sequence of `Is_Option_Name` segments separated by single dots, with no leading, trailing or doubled dot. Use it at `:186` and at `:510-512`. `Is_Option_Name` itself stays as it is for the logical option list, where PostgreSQL's `generic_option` takes a plain identifier.

Whether the same predicate should also admit `$` and the 8-bit bytes `repl_scanner.l` 18.4:107 allows in an identifier is a maintainer decision, since it widens what the constructor will emit as well as what the decoder will accept.

The regression test belongs beside the existing `SHOW` cases in `tests/src/replication_tests.adb:217-219` and `:392-400`; the spike is that test. No existing test asserts the current rejection, so nothing has to be inverted.

## Severity

A caller that issues `SHOW` for a namespaced extension GUC, or a Flyology server that decodes such a `SHOW` from a client, gets `Protocol_Error "invalid replication SHOW parameter name"` for a parameter PostgreSQL would accept. The trigger is unusual: no stock client sends a dotted `SHOW` in replication mode, the only such commands in the PostgreSQL tree being `SHOW wal_segment_size` and `SHOW data_directory_mode` (`streamutil.c` 18.4:293 and 18.4:367), and `src/flyology-postgres-replication-managed_primary.adb:317-331` answers only core GUCs anyway. Deterministic; not reproduced against a live server.
