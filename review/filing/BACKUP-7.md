Title: Base backup Send_Position declares the tli column as int4 where PostgreSQL 14 through 18 declare int8
Labels: bug
Refs: REPL-5

## Summary

`Base_Backups.Server_Sessions.Send_Position` advertises the base backup start- and end-position result set's `tli` column as `int4`, type OID 23 with width 4. Every supported PostgreSQL major declares that column as `int8`, deliberately and with an explanatory comment, because `TimeLineID` is unsigned and would not fit in int4. Both `Send_Start_Position` and `Send_End_Position` route through this one procedure, so a server or proxy built on this package advertises a row shape that differs from the server it stands in for.

## Problem

Commit `6f496f5`.

The column is built with the int4 OID and width (`src/flyology-postgres-replication-base_backups-server_sessions.adb:30-36`):

```ada
Sessions.Send_Row_Description
  (Client,
   Columns =>
     (Protocol.Make_Field_Description ("recptr"),
      Protocol.Make_Field_Description
        ("tli", Type_Oid => 23, Type_Size => 4)),
   Timeout => Timeout);
```

`recptr` takes the `Make_Field_Description` defaults, which are `Type_Oid => 25` and `Type_Size => -1` (`src/flyology-postgres-protocol.ads:320-328`), matching PostgreSQL's `TEXTOID` for that column. Only `tli` is stated explicitly, and it is stated wrongly.

Both public entry points go through it (`src/flyology-postgres-replication-base_backups-server_sessions.adb:46-53` and `:179-188`):

```ada
procedure Send_Start_Position
  (Client   : in out Sessions.Session;
   Position : LSN;
   Timeline : UInt32;
   Timeout  : Duration) is
begin
   Send_Position (Client, Position, Timeline, Timeout);
end Send_Start_Position;
```

```ada
procedure Send_End_Position
  ...
begin
   Send_Position (Client, Position, Timeline, Timeout);
   Sessions.Send_Command_Complete (Client, "BASE_BACKUP", Timeout);
   Sessions.Send_Ready (Client, Timeout => Timeout);
end Send_End_Position;
```

PostgreSQL declares int8 in every cached major, and says why. In 14.23, `SendXlogRecPtrResult` (`tests/.cache/postgres/14.23-openssl/source/src/backend/replication/basebackup.c:1047`) writes the field header by hand (`basebackup.c:1069-1073`):

```c
	/*
	 * int8 may seem like a surprising data type for this, but in theory int4
	 * would not be wide enough for this, as TimeLineID is unsigned.
	 */
	pq_sendint32(&buf, INT8OID);	/* type oid */
```

15.18 moved the same function to `tests/.cache/postgres/15.18-openssl/source/src/backend/backup/basebackup_copy.c:337` and is byte-identical in that respect, with the comment and `pq_sendint32(&buf, INT8OID)` at `basebackup_copy.c:359-363`.

16.14, 17.10 and 18.4 build the descriptor through the tuple-descriptor helper, each at `src/backend/backup/basebackup_copy.c:354-358`:

```c
	/*
	 * int8 may seem like a surprising data type for this, but in theory int4
	 * would not be wide enough for this, as TimeLineID is unsigned.
	 */
	TupleDescInitBuiltinEntry(tupdesc, (AttrNumber) 2, "tli", INT8OID, -1, 0);
```

The advertised width is not 4 in any of them either. 14.23 and 15.18 write it by hand as `-1` (`basebackup.c:1074`, `basebackup_copy.c:364`), and 16.14 through 18.4 build the column from the built-in int8 entry rather than stating 4, the `-1` in that call being the type modifier.

No test inspects the descriptor. `tests/src/tests.adb:1403-1439` drives the whole base backup exchange, start position through end position, into `Base_Backups.Receiver`, and the assertions read decoded values rather than column metadata (`tests/src/tests.adb:1456-1460`):

```ada
Assert
  (Base_Backups.Kind (Event) = Base_Backups.Backup_Start
   and then Base_Backups.Start_LSN (Event) = 16#100#
   and then Base_Backups.Timeline (Event) = 1,
   "base backup exposes its consistent start position");
```

The values are sent in text format and are correct, so nothing in that path can notice.

## What happens now

Spike: `Send_Start_Position` is called on a server session over an in-memory transport, the first frame is decoded as a `RowDescription`, and the second field's type OID is compared against PostgreSQL's `INT8OID`.

```ada
Int8_Oid : constant Protocol.UInt32 := 20;
--  PostgreSQL INT8OID, from src/include/catalog/pg_type.dat.

Backup_Sessions.Send_Start_Position
  (Session, Position => 16#100#, Timeline => 1, Timeout => 1.0);
...
Check (Protocol.Field_Name (Tli) = "tli", ...);
Check (Protocol.Type_Oid (Tli) = Int8_Oid, ...);
```

Output:

```
  ok: the start-position result set opens with a RowDescription (harness sanity check)
  ok: the result set has the two PostgreSQL columns recptr and tli (harness sanity check)
  -- column 2 is "tli" with type OID 23 and width 4
  -- PostgreSQL 14 through 18 send type OID 20 (int8)
  ok: column 2 is named tli (harness sanity check)
  FAILED: the tli column is advertised as int8 (OID 20), the type every supported PostgreSQL major sends for it
BUG REPRODUCED: 1 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23, 15.18, 16.14, 17.10 and 18.4 server sources used for reference.

## What should happen

The `tli` column should be advertised as `int8`, type OID 20, with the width PostgreSQL sends, because that is what `SendXlogRecPtrResult` declares in all five supported majors and this procedure stands in for that function.

## Suggested treatment

Change the one call at `src/flyology-postgres-replication-base_backups-server_sessions.adb:34-35` to `Type_Oid => 20`, and set `Type_Size` to the width PostgreSQL sends for the column instead of 4. Both entry points are fixed by that one edit, since both route through `Send_Position`. Which width to send needs a maintainer decision, because the majors do not agree in the source: 14.23 and 15.18 send `-1` explicitly, while 16.14 through 18.4 let the built-in int8 entry supply it. The options are to send `-1`, matching the two majors that state a value, or to send the int8 catalog width, matching what the newer majors emit at run time.

Unlike the `IDENTIFY_SYSTEM` `timeline` column, which changed type between majors and is the subject of {{ISSUE:REPL-5}}, the type OID here is int8 in all five supported majors, so correcting it needs no server major and no new parameter.

The regression test belongs in `tests/src/tests.adb` beside the base backup exchange at :1403-1439: decode the start-position `RowDescription` and assert the two columns' names and type OIDs before feeding the frames to the receiver. The spike is that test. No existing assertion has to change.

One adjacent observation, offered for the fixer rather than as a finding: `Send_Position` closes with `Sessions.Send_Command_Complete (Client, "SELECT 1", Timeout)` (`src/flyology-postgres-replication-base_backups-server_sessions.adb:43`), where PostgreSQL sends the untagged `"SELECT"` (`basebackup.c:1095` in 14.23, `basebackup_copy.c:371` in 18.4). That difference is cosmetic and no client in the tree depends on either spelling.

## Severity

Protocol fidelity only. The value is sent in text format and is correct, so this library's own `Base_Backups.Receiver` and `pg_basebackup`, which read the column as text and never consult the type OID, are unaffected. A typed client that decodes by the declared type sees a different row shape from the PostgreSQL server this package imitates and would mis-decode timelines above 2^31-1, which needs a timeline count no real installation reaches. Deterministic.
