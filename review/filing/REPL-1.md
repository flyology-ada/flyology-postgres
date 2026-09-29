Title: Decode_Command rejects the valueless TWO_PHASE and FAILOVER options PostgreSQL subscribers send
Labels: bug
Refs: none

## Summary

`Flyology.Postgres.Replication.Decode_Command` demands a quoted value after `TWO_PHASE` inside the parenthesized `CREATE_REPLICATION_SLOT` option list, and it does not recognise `FAILOVER` at all. PostgreSQL writes both as bare names, and a bare name in that list means boolean true. A Flyology server acting as a logical-replication publisher therefore answers a valid slot-creation command from a two-phase or failover subscription with `Protocol.Protocol_Error`, and the subscription never gets its slot.

## Problem

Commit `6f496f5`.

`Parse_Options` attaches a value to an option only when the next non-space character is a quote, and otherwise records the option with no value (`src/flyology-postgres-replication.adb:447-452`):

```ada
Skip_Spaces (Text, Cursor);
if Cursor <= Text'Last and then Text (Cursor) = ''' then
   Values.Append (Option (Name, Read_Quoted (Text, Cursor)));
else
   Values.Append (Option (Name));
end if;
```

The `CREATE_REPLICATION_SLOT` branch then rejects the valueless form (`src/flyology-postgres-replication.adb:594-596`):

```ada
Require
  (Option_Has_Value (Item),
   "TWO_PHASE requires a value");
```

and every unrecognised name, `FAILOVER` among them, falls into the terminating `else` arm (`src/flyology-postgres-replication.adb:611-614`):

```ada
else
   raise Protocol.Protocol_Error with
     "unsupported logical slot option " & Option_Name (Item);
end if;
```

Both forms are legal PostgreSQL. The parenthesized replication option list makes a bare name a `DefElem` with a NULL argument. `src/backend/replication/repl_gram.y` 15.18:377-381, 16.14:375-379, 17.10:401-405 and 18.4:405-409 all read:

```
generic_option:
			ident_or_keyword
				{
					$$ = makeDefElem($1, NULL, -1);
				}
```

A NULL argument means true. `src/backend/commands/define.c` 18.4:93-100:

```c
bool
defGetBoolean(DefElem *def)
{
	/*
	 * If no parameter value given, assume "true" is meant.
	 */
	if (def->arg == NULL)
		return true;
```

`parseCreateReplSlotOptions` reads both options through exactly that function (`src/backend/replication/walsender.c` 18.4:1164-1181):

```c
		else if (strcmp(defel->defname, "two_phase") == 0)
		{
			...
			*two_phase = defGetBoolean(defel);
		}
		else if (strcmp(defel->defname, "failover") == 0)
		{
			...
			*failover = defGetBoolean(defel);
		}
```

PostgreSQL's own subscribers emit the bare names. `libpqrcv_create_slot` appends `TWO_PHASE` with no argument (`src/backend/replication/libpqwalreceiver/libpqwalreceiver.c` 18.4:930-937, same code at 15.18:954-961 and 17.10:1055-1062):

```c
		appendStringInfoString(&cmd, " LOGICAL pgoutput ");
		if (use_new_options_syntax)
			appendStringInfoChar(&cmd, '(');
		if (two_phase)
		{
			appendStringInfoString(&cmd, "TWO_PHASE");
			if (use_new_options_syntax)
				appendStringInfoString(&cmd, ", ");
```

and appends `FAILOVER` the same way (18.4:942-949, 17.10:1067-1074). `TWO_PHASE` is emitted by a PostgreSQL 15, 16, 17 or 18 subscriber whose subscription sets `two_phase = true`; `FAILOVER` is emitted by a PostgreSQL 17 or 18 subscriber whose subscription sets `failover = true`. PostgreSQL 14 has neither option and uses the older keyword list instead (`repl_gram.y` 14.23:254-282). Both flags reach `walrcv_create_slot` from `src/backend/commands/subscriptioncmds.c` 18.4:783-784, and the tablesync worker propagates the failover flag at `src/backend/replication/logical/tablesync.c` 18.4:1489-1492. `pg_recvlogical --create-slot --two-phase` produces the same list through `AppendPlainCommandOption` (`src/bin/pg_basebackup/streamutil.c` 18.4:620-626).

The contract `Decode_Command` states is `src/flyology-postgres-replication.ads:161-166`:

```ada
   function Decode_Command (Item : Protocol.Message) return Command;
   --  Decode the command grammar emitted by PostgreSQL and the constructors in
   --  this package.
   --  @param Item Simple Query message containing one replication command.
   --  @return Validated decoded command.
   --  @exception Protocol.Protocol_Error The message or command is malformed.
```

The valueless form is the grammar emitted by PostgreSQL, so rejecting it breaks that promise.

The constructor side is not wrong. `Create_Logical_Slot` writes `TWO_PHASE 'true'` (`src/flyology-postgres-replication.adb:226-228`), which PostgreSQL accepts. Only the decoder is incomplete, and that is why the tests do not catch it. `tests/src/replication_tests.adb:267-281` decodes a command carrying only `SNAPSHOT 'use'`, and `tests/src/replication_tests.adb:283-291` decodes the library's own constructor output, so every decoded `TWO_PHASE` in the suite already carries a quoted value. `tests/src/replication_tests.adb:427-429` goes further and asserts that the valueless form must be rejected:

```ada
      Assert_Command_Rejected
        ("CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput"
         & " (TWO_PHASE)");
```

That assertion enshrines the defect and has to change. No test decodes `FAILOVER` at all.

## What happens now

Spike: the program builds the two Simple Query texts `libpqrcv_create_slot` writes for a two-phase subscription and for a failover subscription, passes each to `Decode_Command`, and asserts that both decode, that the two-phase command classifies as `Create_Logical_Slot_Command` with `Two_Phase` true, and that the trailing `SNAPSHOT 'nothing'` is still decoded.

```ada
   --  Exactly what libpqrcv_create_slot writes for a two-phase subscription
   --  slot on a PostgreSQL 15 or newer publisher.
   Two_Phase_Text : constant String :=
     "CREATE_REPLICATION_SLOT ""sub_slot"" LOGICAL pgoutput "
     & "(TWO_PHASE, SNAPSHOT 'nothing')";

   --  Exactly what a PostgreSQL 17 or newer subscriber writes when the
   --  subscription requests slot failover.
   Failover_Text : constant String :=
     "CREATE_REPLICATION_SLOT ""sub_slot"" LOGICAL pgoutput "
     & "(FAILOVER, SNAPSHOT 'nothing')";
...
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query (Two_Phase_Text));
      begin
         Two_Phase_Decoded := True;
         Two_Phase_Kind :=
           Replication.Kind (Item) = Replication.Create_Logical_Slot_Command;
         Two_Phase_Flag := Replication.Two_Phase (Item);
```

Output:

```
  -- PostgreSQL 15+ two-phase subscriber sends: CREATE_REPLICATION_SLOT "sub_slot" LOGICAL pgoutput (TWO_PHASE, SNAPSHOT 'nothing')
  --   Decode_Command raised Protocol_Error: TWO_PHASE requires a value
  -- PostgreSQL 17+ failover subscriber sends: CREATE_REPLICATION_SLOT "sub_slot" LOGICAL pgoutput (FAILOVER, SNAPSHOT 'nothing')
  --   Decode_Command raised Protocol_Error: unsupported logical slot option FAILOVER
  FAILED: Decode_Command accepts the valueless TWO_PHASE option a PostgreSQL 15+ two-phase subscriber sends
  FAILED: that command classifies as Create_Logical_Slot_Command
  FAILED: a valueless TWO_PHASE means True, as defGetBoolean specifies for a DefElem with a NULL argument
  FAILED: the accompanying SNAPSHOT 'nothing' is still decoded
  FAILED: Decode_Command accepts the valueless FAILOVER option a PostgreSQL 17+ failover subscriber sends
BUG REPRODUCED: 5 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23, 15.18, 16.14, 17.10 and 18.4 server sources used for reference.

## What should happen

A valueless `TWO_PHASE` should decode as `Two_Phase` true, matching `defGetBoolean`'s rule for a `DefElem` with a NULL argument (`define.c` 18.4:96-100), and a valueless `FAILOVER` should be accepted rather than rejected as an unsupported option, because both are part of "the command grammar emitted by PostgreSQL" that `Decode_Command` promises to decode (`src/flyology-postgres-replication.ads:161-166`).

## Suggested treatment

`Parse_Options` already records a valueless option at `src/flyology-postgres-replication.adb:450-451`, so the parser needs no change. Replace the `Require (Option_Has_Value (Item), ...)` at `:594-596` with a default of `True` when the option carries no value, keeping the existing `true`/`on`/`1` and `false`/`off`/`0` mapping for the valued form, and add a `FAILOVER` branch before the `else` arm at `:611-614` with the same valueless-means-true rule.

How `FAILOVER` is surfaced needs a maintainer decision. The options are a new `Failover` accessor beside `Two_Phase` (`src/flyology-postgres-replication.ads:198`), accepting the option and discarding it so the command still decodes, or a generic accessor over the decoded option list. Nothing in the library reads it today: `src/flyology-postgres-replication-managed_primary.adb:338-351` inspects only `Snapshot` and `Two_Phase`.

The regression test belongs in `Test_Commands_And_LSN` in `tests/src/replication_tests.adb`, beside the existing slot-decoding cases at `:267-291`; the spike is that test. `tests/src/replication_tests.adb:427-429` asserts the current rejection and must be removed or inverted as part of the fix.

## Severity

A Flyology server acting as a logical-replication publisher rejects the slot-creation command from any PostgreSQL 15 or newer subscription with `two_phase = true`, and from any PostgreSQL 17 or newer subscription with `failover = true`, so those subscriptions cannot be created. It is not the default path: both `two_phase` and `failover` default to false in `CREATE SUBSCRIPTION`, so an opted-in subscription is needed to reach it. Deterministic; not reproduced against a live server.
