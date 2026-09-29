Title: Decode_Command rejects the TEMPORARY and PHYSICAL forms of CREATE_REPLICATION_SLOT that pg_basebackup sends
Labels: bug
Refs: none

## Summary

`Flyology.Postgres.Replication.Decode_Command` demands the keyword `LOGICAL` immediately after the slot name, but PostgreSQL's grammar puts an optional `TEMPORARY` there and allows `PHYSICAL` in place of `LOGICAL`. A default `pg_basebackup` invocation opens by creating a temporary physical slot, so a Flyology server that routes `BASE_BACKUP` fails on the first command it receives, before `BASE_BACKUP` is ever read.

## Problem

Commit `6f496f5`.

The decoder reads the slot name and then insists on `LOGICAL` (`src/flyology-postgres-replication.adb:519-527`):

```ada
      elsif Is_Keyword (First, "CREATE_REPLICATION_SLOT") then
         Result.Message_Kind := Create_Logical_Slot_Command;
         declare
            Name : constant String := Next_Identifier (Text, Cursor);
         begin
            Require (Is_Slot_Name (Name), "invalid replication slot name");
            Result.Slot_Data := Flyology.Bytes.From_Byte_String (Name);
         end;
         Expect_Keyword (Text, Cursor, "LOGICAL");
```

PostgreSQL's replication grammar puts `opt_temporary` between the slot name and the kind keyword, and offers `PHYSICAL` as the alternative kind. `src/backend/replication/repl_gram.y` 18.4:183-196:

```
create_replication_slot:
			/* CREATE_REPLICATION_SLOT slot [TEMPORARY] PHYSICAL [options] */
			K_CREATE_REPLICATION_SLOT IDENT opt_temporary K_PHYSICAL create_slot_options
				{
					CreateReplicationSlotCmd *cmd;
					cmd = makeNode(CreateReplicationSlotCmd);
					cmd->kind = REPLICATION_KIND_PHYSICAL;
					cmd->slotname = $2;
					cmd->temporary = $3;
					cmd->options = $5;
					$$ = (Node *) cmd;
				}
			/* CREATE_REPLICATION_SLOT slot [TEMPORARY] LOGICAL plugin [options] */
			| K_CREATE_REPLICATION_SLOT IDENT opt_temporary K_LOGICAL IDENT create_slot_options
```

The rule has the same shape on every supported major: 14.23:228-252, 15.18:176-200, 16.14:174-198, 17.10:179-203, 18.4:183-207. `opt_temporary` is the bare keyword or nothing (`repl_gram.y` 18.4:345-348, 14.23:359-362, 15.18:317-320, 16.14:315-318, 17.10:341-344):

```
opt_temporary:
			K_TEMPORARY						{ $$ = true; }
			| /* EMPTY */					{ $$ = false; }
			;
```

So `TEMPORARY` and `PHYSICAL` both sit exactly where `Expect_Keyword (Text, Cursor, "LOGICAL")` looks, and all three real command texts in the spike below are rejected with `Protocol_Error "expected LOGICAL in replication command"`.

The interop-critical case is `pg_basebackup` run with no options. `temp_replication_slot` is initialized true (`src/bin/pg_basebackup/pg_basebackup.c` 18.4:148):

```c
static bool temp_replication_slot = true;
```

and the default `-X stream` path names and creates that slot before streaming (`pg_basebackup.c` 18.4:664-671):

```c
	if (temp_replication_slot && !replication_slot)
		replication_slot = psprintf("pg_basebackup_%u",
									(unsigned int) PQbackendPID(param->bgconn));
	if (temp_replication_slot || create_slot)
	{
		if (!CreateReplicationSlot(param->bgconn, replication_slot, NULL,
								   temp_replication_slot, true, true, false,
								   false, false))
```

`CreateReplicationSlot` renders that as `CREATE_REPLICATION_SLOT "pg_basebackup_NNNN" TEMPORARY PHYSICAL (RESERVE_WAL)` (`src/bin/pg_basebackup/streamutil.c` 18.4:601-617):

```c
	appendPQExpBuffer(query, "CREATE_REPLICATION_SLOT \"%s\"", slot_name);
	if (is_temporary)
		appendPQExpBufferStr(query, " TEMPORARY");
	if (is_physical)
		appendPQExpBufferStr(query, " PHYSICAL");
	else
		appendPQExpBuffer(query, " LOGICAL \"%s\"", plugin);

	/* Add any requested options */
	if (use_new_option_syntax)
		appendPQExpBufferStr(query, " (");
	if (is_physical)
	{
		if (reserve_wal)
			AppendPlainCommandOption(query, use_new_option_syntax,
									 "RESERVE_WAL");
	}
```

`pg_receivewal --create-slot` and `pg_basebackup -C` send the non-temporary physical form through the same function (`src/bin/pg_basebackup/pg_receivewal.c` 18.4:891-892), and a PostgreSQL walreceiver with `wal_receiver_create_temp_slot` on sends the temporary physical form (`src/backend/replication/walreceiver.c` 18.4:356-362 passing `temporary => true`, rendered by `src/backend/replication/libpqwalreceiver/libpqwalreceiver.c` 18.4:925-926 and 18.4:985-991).

`TEMPORARY LOGICAL` should not be counted as a stock-client form. `libpqrcv_create_slot` can write it (`libpqwalreceiver.c` 18.4:925-926), but no stock caller asks for it: `walreceiver.c` 18.4:362 passes `temporary => true` only on the physical path, while `subscriptioncmds.c` 18.4:783 and `tablesync.c` 18.4:1489-1490 both pass false. `TEMPORARY LOGICAL` is therefore grammar-valid but not emitted; `TEMPORARY PHYSICAL` is emitted, by default, by the most common client of all.

The contract broken is `src/flyology-postgres-replication.ads:161-166`:

```ada
   function Decode_Command (Item : Protocol.Message) return Command;
   --  Decode the command grammar emitted by PostgreSQL and the constructors in
   --  this package.
```

The physical-slot *result* is a documented subset: `src/flyology-postgres-replication.ads:151` says

```ada
   --  @enum Create_Logical_Slot_Command CREATE_REPLICATION_SLOT LOGICAL.
```

That subset does not excuse the failure, because the "Server/proxy boundary" section of `docs/BASE_BACKUP.md` documents routing a stock `pg_basebackup` as a supported capability (`docs/BASE_BACKUP.md:104-105`):

```
`Replication.Decode_Command` classifies `BASE_BACKUP` and `UPLOAD_MANIFEST` so
servers can route or proxy the original owned query.
```

A `pg_basebackup` that cannot get past its first command never reaches `BASE_BACKUP`. The `TEMPORARY` keyword position is not a documented subset at all: nothing in `src/flyology-postgres-replication.ads`, `README.md:424-429`, or `tests/REPLICATION_VALIDATION.md` declares it unsupported.

The tests do not catch it because every `CREATE_REPLICATION_SLOT` text in the suite is logical and non-temporary: `tests/src/replication_tests.adb:224-244` checks constructor output only, and the one decoded command, `tests/src/replication_tests.adb:267-281`, is `CREATE_REPLICATION_SLOT "sync_slot" LOGICAL pgoutput (SNAPSHOT 'use')`. No test decodes a `TEMPORARY` or `PHYSICAL` form.

## What happens now

Spike: the program passes three real command texts to `Decode_Command` (the temporary physical slot a default `pg_basebackup` creates, the physical slot `pg_receivewal --create-slot` creates, and a temporary logical slot) and asserts that each decodes and names its slot.

```ada
   Try_Decode
     ("pg_basebackup, default -X stream",
      "CREATE_REPLICATION_SLOT ""pg_basebackup_1234"" TEMPORARY PHYSICAL"
      & " (RESERVE_WAL)",
      "pg_basebackup_1234",
      Temp_Physical_Decoded,
      Temp_Physical_Slot);

   Try_Decode
     ("pg_receivewal --create-slot",
      "CREATE_REPLICATION_SLOT ""wal_archive"" PHYSICAL (RESERVE_WAL)",
      "wal_archive",
      Physical_Decoded,
      Physical_Slot);

   Try_Decode
     ("a temporary logical slot (libpqrcv_create_slot, temporary => true)",
      "CREATE_REPLICATION_SLOT ""sub_slot"" TEMPORARY LOGICAL pgoutput"
      & " (SNAPSHOT 'nothing')",
      "sub_slot",
      Temp_Logical_Decoded,
      Temp_Logical_Slot);
```

Output:

```
  -- pg_basebackup, default -X stream sends: CREATE_REPLICATION_SLOT "pg_basebackup_1234" TEMPORARY PHYSICAL (RESERVE_WAL)
  --   Decode_Command raised Protocol_Error: expected LOGICAL in replication command
  -- pg_receivewal --create-slot sends: CREATE_REPLICATION_SLOT "wal_archive" PHYSICAL (RESERVE_WAL)
  --   Decode_Command raised Protocol_Error: expected LOGICAL in replication command
  -- a temporary logical slot (libpqrcv_create_slot, temporary => true) sends: CREATE_REPLICATION_SLOT "sub_slot" TEMPORARY LOGICAL pgoutput (SNAPSHOT 'nothing')
  --   Decode_Command raised Protocol_Error: expected LOGICAL in replication command
  FAILED: Decode_Command accepts the temporary physical slot creation pg_basebackup sends by default
  FAILED: that command names slot pg_basebackup_1234
  FAILED: Decode_Command accepts the physical slot creation pg_receivewal --create-slot sends
  FAILED: that command names slot wal_archive
  FAILED: Decode_Command accepts TEMPORARY between the slot name and LOGICAL
  FAILED: the temporary logical form still classifies as Create_Logical_Slot_Command naming slot sub_slot
  FAILED: the temporary logical form still exposes plugin pgoutput and SNAPSHOT 'nothing'
BUG REPRODUCED: 7 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23, 15.18, 16.14, 17.10 and 18.4 server sources used for reference.

## What should happen

`Decode_Command` should accept an optional `TEMPORARY` between the slot name and the kind keyword, and should decode a `PHYSICAL` slot creation instead of raising `Protocol_Error`, because both are the grammar PostgreSQL emits (`repl_gram.y` 18.4:183-196) and the grammar `Decode_Command` promises to decode (`src/flyology-postgres-replication.ads:161-166`).

## Suggested treatment

There are two distinct fixes here, and only the first is mechanical.

Accepting `TEMPORARY` in its grammatical position is a pure parser correction with no API change: at `src/flyology-postgres-replication.adb:527`, consume an optional `TEMPORARY` keyword before `Expect_Keyword (Text, Cursor, "LOGICAL")`. The temporary logical form then decodes with the fields it already has, and the temporary flag can stay unexposed until someone needs it.

Representing a physical slot creation needs a maintainer decision, because `Command_Kind` currently documents only the logical form (`src/flyology-postgres-replication.ads:151`). The options are a new `Create_Physical_Slot_Command` variant with a `Reserve_Wal` accessor beside the existing `Slot_Name`, `Plugin`, `Snapshot` and `Two_Phase` accessors (`src/flyology-postgres-replication.ads:182-198`); a single `Create_Replication_Slot_Command` variant with a kind accessor, which changes the meaning of the existing enumerator; or leaving physical slots undecoded and documenting the exclusion, which does not fix the `pg_basebackup` routing case that `docs/BASE_BACKUP.md:104-105` promises. The `TEMPORARY` flag has the same shape of decision if it is to be exposed rather than merely accepted.

The regression test belongs in `Test_Commands_And_LSN` in `tests/src/replication_tests.adb`, beside the existing slot-decoding case at `:267-281`; the spike is that test. No existing test asserts the current rejection, so nothing has to be inverted.

## Severity

A Flyology server that serves or routes `BASE_BACKUP`, which `docs/BASE_BACKUP.md:104-105` presents as a supported capability, rejects the very first command a `pg_basebackup` run with default options sends, so the backup never starts. `pg_receivewal --create-slot`, `pg_basebackup -C`, and a PostgreSQL walreceiver with `wal_receiver_create_temp_slot` on fail the same way. No client configuration is needed to reach it: the temporary physical slot is `pg_basebackup`'s default. Deterministic; not reproduced against a live server.
