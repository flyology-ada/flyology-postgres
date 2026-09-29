Title: Send_Identify_System advertises the IDENTIFY_SYSTEM timeline column as int4 for PostgreSQL 16 and newer peers
Labels: bug
Refs: BACKUP-7

## Summary

`Send_Identify_System` builds the IDENTIFY_SYSTEM RowDescription with a fixed `timeline` column of type OID 23 and width 4. PostgreSQL changed that column from int4 to int8 in 16, so the declaration is wrong for three of the five supported majors. The DataRow text is unchanged and no stock client reads the OID, so this is protocol fidelity against the server being imitated rather than a wrong result on a stock-client path.

## Problem

Commit `6f496f5`.

The column set is unconditional (`src/flyology-postgres-replication-server_sessions.adb:57-65`):

```ada
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description ("systemid"),
            Protocol.Make_Field_Description
              ("timeline", Type_Oid => 23, Type_Size => 4),
            Protocol.Make_Field_Description ("xlogpos"),
            Protocol.Make_Field_Description ("dbname")),
         Timeout => Timeout);
```

`IdentifySystem` in `src/backend/replication/walsender.c` splits on the major. PostgreSQL 14.23:444-445 and 15.18:460-461 declare column 2 as int4:

```c
	TupleDescInitBuiltinEntry(tupdesc, (AttrNumber) 2, "timeline",
							  INT4OID, -1, 0);
```

PostgreSQL 16.14:462-463, 17.10:475-476 and 18.4:445-446 declare it as int8:

```c
	TupleDescInitBuiltinEntry(tupdesc, (AttrNumber) 2, "timeline",
							  INT8OID, -1, 0);
```

The datum construction follows the same split: `Int32GetDatum` at 14.23:458 and 15.18:474, `Int64GetDatum` at 16.14:476, 17.10:489 and 18.4:459. So OID 23 with width 4 is right for two of the five supported majors and wrong for the other three, which also carry the wrong width, int8 having a typlen of 8.

The consequence is bounded. The DataRow payload is the correct decimal text either way (`src/flyology-postgres-replication-server_sessions.adb:66-70`):

```ada
      Sessions.Send_Data_Row
        (Client,
         Values =>
           (Protocol.Text_Column (Decimal_Image (System_Id)),
            Protocol.Text_Column (Decimal_Image (Timeline)),
```

and both stock consumers read that text without consulting the descriptor. `libpqrcv_identify_system` uses `pg_strtoint32` on the string (`src/backend/replication/libpqwalreceiver/libpqwalreceiver.c` 18.4:460):

```c
	*primary_tli = pg_strtoint32(PQgetvalue(res, 0, 1));
```

and `RunIdentifySystem` uses `atoi` on it (`src/bin/pg_basebackup/streamutil.c` 18.4:443):

```c
		*starttli = atoi(PQgetvalue(res, 0, 1));
```

So walreceiver, `pg_basebackup` and `pg_receivewal` are unaffected, as is this library's own client path, which never parses the OID. What is affected is a typed or generic client that binds by result type, and any fidelity check that diffs the RowDescription against a real server.

There is no `.ads` sentence to quote against. `src/flyology-postgres-replication-server_sessions.ads:9-17` describes the shape of the response but makes no typed promise about the column, and `README.md:424-429` does not either:

```ada
   procedure Send_Identify_System
     (Client         : in out Sessions.Session;
      System_Id      : UInt64;
      Timeline       : UInt32;
      Current_WAL    : LSN;
      Database       : String := "";
      Timeout        : Duration);
   --  Complete IDENTIFY_SYSTEM as a four-column simple-query response. An
   --  empty Database is encoded as SQL NULL for a physical connection.
```

The profile carries no server major, so the API cannot express the 16 and newer answer at all. This is contract drift against the server being imitated rather than a violation of a documented sentence.

The tests do not catch it because nothing asserts the IDENTIFY_SYSTEM descriptor. `tests/src/replication_tests.adb` covers the client-side constructor and the decoded command only (`:214-216` and `:385-389`), and the two callers that produce a real response, `tests/src/postgres_test_replication_server.adb:254` and `src/flyology-postgres-replication-managed_primary.adb:311`, are never checked against a column type. No test in `tests/src/` reads `Protocol.Type_Oid` from an IDENTIFY_SYSTEM RowDescription.

## What happens now

Spike: the program calls `Send_Identify_System` on a session standing in for a PostgreSQL 16, 17 or 18 primary, decodes the first frame written, and asserts that column 2 is advertised as int8 with the int8 width.

```ada
   Int4_Oid : constant Protocol.UInt32 := 23;
   Int8_Oid : constant Protocol.UInt32 := 20;
   --  PostgreSQL INT4OID and INT8OID, from src/include/catalog/pg_type.dat.
...
   Replication_Sessions.Send_Identify_System
     (Session,
      System_Id   => 7_000_000_000_000_000_001,
      Timeline    => 1,
      Current_WAL => 16#100#,
      Database    => "",
      Timeout     => 1.0);
...
            Check
              (Protocol.Type_Oid (Tli) = Int8_Oid,
               "the timeline column is advertised as int8 (OID 20) for a "
               & "PostgreSQL 16 or newer peer, as walsender.c "
               & "IdentifySystem sends");
```

Output:

```
  ok: the IDENTIFY_SYSTEM result set opens with a RowDescription (harness sanity check)
  ok: the result set has the four PostgreSQL columns systemid, timeline, xlogpos and dbname (harness sanity check)
  -- column 2 is "timeline" with type OID 23 and width 4
  -- PostgreSQL 14 and 15 send type OID 23 (int4); PostgreSQL 16, 17 and 18 send type OID 20 (int8)
  -- Send_Identify_System takes no server major, so one declaration is used for every peer
  ok: column 2 is named timeline (harness sanity check)
  FAILED: the timeline column is advertised as int8 (OID 20) for a PostgreSQL 16 or newer peer, as walsender.c IdentifySystem sends
  FAILED: the timeline column carries the int8 width of 8 for a PostgreSQL 16 or newer peer
BUG REPRODUCED: 2 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23, 15.18, 16.14, 17.10 and 18.4 server sources used for reference.

## What should happen

The IDENTIFY_SYSTEM `timeline` column should be declared with the type the peer's major uses: OID 23 with width 4 for PostgreSQL 14 and 15, OID 20 with width 8 for PostgreSQL 16, 17 and 18, as `walsender.c` `IdentifySystem` declares it at 14.23:444-445, 15.18:460-461, 16.14:462-463, 17.10:475-476 and 18.4:445-446.

## Suggested treatment

This needs a maintainer decision, because the fix is not a constant change: the column has two correct answers and the current profile has no way to choose between them. This is the same shape as {{ISSUE:BACKUP-7}}, whose `tli` column is int8 in all five majors and therefore admits a single unconditional correction; here it does not.

The options for getting the peer major to the call are a new `Server_Major` parameter on `Send_Identify_System` (`src/flyology-postgres-replication-server_sessions.ads:9-15`), for which the repository has both precedents: the `subtype Server_Major is Positive range 14 .. 18` at `src/flyology-postgres-replication-base_backups.ads:11`, and the defaulted `Server_Major : Positive := 18` formal on `Replication.Create_Logical_Slot` at `src/flyology-postgres-replication.ads:95`; carrying the major on the `Sessions.Session` so every response in the package can use it; or leaving the choice to the caller by exposing the column descriptors.

Whichever is chosen, a defaulted parameter changes the advertised type for the three existing callers, `src/flyology-postgres-replication-managed_primary.adb:311`, `tests/src/postgres_test_replication_server.adb:254` and `examples/psqlbench/src/psqlbench_links.adb:669`, according to the default picked, which is itself a policy choice.

The regression test belongs beside the server-response tests in `tests/src/replication_tests.adb`; the spike is that test, once the API can express the 16 and newer answer. No existing test asserts the current column type, so nothing has to be inverted.

## Severity

A Flyology-based primary or proxy advertises the wrong result-column type and width for IDENTIFY_SYSTEM to any PostgreSQL 16, 17 or 18 peer, which is three of the five supported majors. Nothing in the PostgreSQL tree misbehaves against it: the wire text is correct and both stock consumers read the value as text without looking at the descriptor, so the reachable impact is limited to a typed or generic client that binds by result type, or a fidelity check that diffs the RowDescription against a real server. The wrong declaration is deterministic and was not compared against a live server. PostgreSQL 16, 17 and 18 only.
