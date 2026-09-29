# Adversarial verification: REPL findings (streaming-replication protocol core)

Repository: `/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd`
PostgreSQL sources consulted: `tests/.cache/postgres/{14.23,15.18,16.14,17.10,18.4}-openssl/source`
Repro harness: `tests/repros` (`./run.sh repro_repl_<n>`)

All four candidate findings survived refutation. Two of them are more serious
than the discovery report claimed; one report sub-claim about which stock
client sends a form is inaccurate and is corrected below.

Files added (only under `tests/repros/src/`, per the rules):
`repro_repl_1.adb`, `repro_repl_2.adb`, `repro_repl_3.adb`, `repro_repl_4.adb`.

## Shared interop facts established against real PostgreSQL sources

| Fact | Source |
|---|---|
| A bare option name in the parenthesized replication option list is a `DefElem` with a NULL argument | `repl_gram.y` 15.18:377-381, 17.10:401-405, 18.4:405-409 — `generic_option: ident_or_keyword { $$ = makeDefElem($1, NULL, -1); }` |
| A NULL-argument `DefElem` means boolean **true** | `src/backend/commands/define.c` 18.4:94-100 — `defGetBoolean`: "If no parameter value given, assume \"true\" is meant." → `if (def->arg == NULL) return true;` |
| `TWO_PHASE` / `FAILOVER` are read through `defGetBoolean` | `walsender.c` 18.4:1164-1181 |
| Grammar places `TEMPORARY` between the slot name and `PHYSICAL`/`LOGICAL`, and a physical slot has no plugin | `repl_gram.y` 18.4:178-199 (same shape 14.23:230-252, 15.18:178-200, 16.14:176-198) |
| `SHOW` takes a dotted GUC name | `repl_gram.y` 18.4:153-164 / 14.23:141-152 — `var_name: IDENT \| var_name '.' IDENT { psprintf("%s.%s", ...) }`; `repl_scanner.l` 18.4:211-214 returns `.` as itself |
| A standby's mid-stream `CopyDone` is normal and is answered with the walsender's own `CopyDone` | `walsender.c` 18.4:2260-2331, esp. 2323-2330 |

Declared scope checked before judging "documented subset":
`src/flyology-postgres-replication.ads:161-166` — `Decode_Command` "Decode the
command grammar emitted by PostgreSQL and the constructors in this package";
`:151` — `@enum Create_Logical_Slot_Command CREATE_REPLICATION_SLOT LOGICAL`;
`README.md:425-427` lists the classified commands; `docs/BASE_BACKUP.md:102-108`
("Server/proxy boundary") documents serving/routing `BASE_BACKUP` and
`UPLOAD_MANIFEST` from a Flyology server, which is what makes a stock
`pg_basebackup` a supported peer. `tests/REPLICATION_VALIDATION.md` declares no
exclusion for `TEMPORARY`, `PHYSICAL`, valueless `TWO_PHASE`/`FAILOVER`, dotted
`SHOW`, or a standby-initiated `CopyDone`.

Test-suite impact confirmed: `tests/src/replication_tests.adb:427-429` asserts
that `CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput (TWO_PHASE)` is
**rejected** (`Assert_Command_Rejected`). Fixing REPL-1 requires changing that
assertion; it currently enshrines the defect.

---

### REPL-1: `Decode_Command` rejects PostgreSQL's valueless `TWO_PHASE` and `FAILOVER` in `CREATE_REPLICATION_SLOT`

**Verdict:** CONFIRMED (both halves; the report's "Medium" confidence on
`FAILOVER` can be raised to High — the emitter and the server-side
`defGetBoolean` handling are both in the cached sources).

**Severity:** P1 (unchanged from the report).

**Repro:** `tests/repros/src/repro_repl_1.adb`

**Output** (`cd tests/repros && ./run.sh repro_repl_1 90`, exit status **1**):

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

**Description:**
`Flyology.Postgres.Replication.Decode_Command` requires an explicit value for
`TWO_PHASE` (`src/flyology-postgres-replication.adb:594-596`, reached because
`Parse_Options` only attaches a value when the next non-space character is a
`'`, at `:447-452`) and rejects `FAILOVER` outright in the `else` arm at
`:611-614`. Both are the exact forms PostgreSQL itself emits: a PostgreSQL 15+
subscriber whose subscription enables `two_phase` writes
`CREATE_REPLICATION_SLOT "s" LOGICAL pgoutput (TWO_PHASE, SNAPSHOT 'nothing')`
(`libpqwalreceiver.c` 15.18:954-965, 18.4:930-940, driven from
`subscriptioncmds.c` 18.4:783-784), a PostgreSQL 17+ subscriber with
`failover = true` appends a bare `FAILOVER` the same way
(`libpqwalreceiver.c` 17.10:1067-1074, 18.4:942-949; the tablesync worker
propagates `MySubscription->failover` at `tablesync.c` 18.4:1489-1492), and
`pg_recvlogical --create-slot --two-phase` produces the identical list through
`streamutil.c` 18.4:620-626 (`AppendPlainCommandOption`). On the server side
the bare token is a valid boolean *true*: `repl_gram.y` 18.4:405-409 builds a
NULL-argument `DefElem` and `walsender.c` 18.4:1164-1181 reads it with
`defGetBoolean`, whose documented rule is `define.c` 18.4:96-100. Consequence:
a Flyology server acting as a logical-replication primary answers a valid
PostgreSQL slot-creation command with `Protocol.Protocol_Error`, so the
subscription cannot create its slot; this violates `Decode_Command`'s stated
contract at `src/flyology-postgres-replication.ads:161-166`. It is P1 rather
than P0 because `two_phase` and `failover` both default to false in
`CREATE SUBSCRIPTION`, so the failure needs an opted-in subscription rather
than the default path. Note the constructor side is not wrong — the library's
own `Create_Logical_Slot (..., Two_Phase => True)` emits `TWO_PHASE 'true'`
(`:228`), which PostgreSQL accepts; only the decoder is incomplete. Fixing this
requires updating `tests/src/replication_tests.adb:427-429`, which currently
asserts the rejection, and requires a decision about how `FAILOVER` is surfaced
(no accessor exists today; `managed_primary.adb:338-350` inspects only
`Snapshot` and `Two_Phase`).

---

### REPL-2: `Decode_Command` cannot parse `CREATE_REPLICATION_SLOT` with `TEMPORARY` or a `PHYSICAL` slot

**Verdict:** CONFIRMED, with one report sub-claim corrected and the severity
raised. The physical-slot *result type* gap is a documented subset
(`replication.ads:151` says `Create_Logical_Slot_Command` is
"CREATE_REPLICATION_SLOT LOGICAL"), but it is still a bug: **`pg_basebackup`
sends the temporary physical form by default**. The `TEMPORARY` keyword
position is not a documented subset at all — nothing declares it unsupported.

*Correction to the report:* it states that `libpqrcv_create_slot` "appends
` TEMPORARY` right after the slot name when a temporary **logical** slot is
requested". The code can do that (`libpqwalreceiver.c` 18.4:925-926), but no
stock PostgreSQL caller does: `walreceiver.c` 18.4:362 passes
`temporary => true` only on the *physical* path, while `subscriptioncmds.c`
18.4:783 and `tablesync.c` 18.4:1489-1490 both pass `false`. So
`TEMPORARY LOGICAL` is grammar-valid but not emitted by a stock client;
`TEMPORARY PHYSICAL` is.

**Severity:** P1 (raised from the report's P2).

**Repro:** `tests/repros/src/repro_repl_2.adb`

**Output** (`cd tests/repros && ./run.sh repro_repl_2 90`, exit status **1**):

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

**Description:**
After the slot name, `Decode_Command` unconditionally demands `LOGICAL`
(`src/flyology-postgres-replication.adb:519-527`,
`Expect_Keyword (Text, Cursor, "LOGICAL")` at `:527`). PostgreSQL's grammar is
`CREATE_REPLICATION_SLOT IDENT opt_temporary { PHYSICAL | LOGICAL IDENT }
create_slot_options` (`repl_gram.y` 18.4:178-199 and the same shape on 14-17),
so both `TEMPORARY` and `PHYSICAL` sit exactly where the decoder expects
`LOGICAL`, and every one of the three real command texts above is rejected with
`Protocol_Error "expected LOGICAL in replication command"`. The interop-critical
case is `pg_basebackup` with default options: `temp_replication_slot` is
initialized `true` (`pg_basebackup.c` 18.4:148) and the default `-X stream`
reaches `pg_basebackup.c` 18.4:664-671, which calls
`CreateReplicationSlot(..., temp_replication_slot, /*is_physical*/ true,
/*reserve_wal*/ true, ...)`; `streamutil.c` 18.4:601-616 renders that as
`CREATE_REPLICATION_SLOT "pg_basebackup_NNNN" TEMPORARY PHYSICAL
(RESERVE_WAL)`. `pg_receivewal --create-slot` and `pg_basebackup -C` send the
non-temporary physical form (`pg_receivewal.c` 18.4:891-892), and a PostgreSQL
walreceiver with `wal_receiver_create_temp_slot` on sends the temporary
physical form (`walreceiver.c` 18.4:356-362 →
`libpqwalreceiver.c` 18.4:925-926, 985). Consequence: a Flyology server that
routes `BASE_BACKUP` — a documented capability, `docs/BASE_BACKUP.md:102-108`
"Server/proxy boundary" — fails on the *first* command a default
`pg_basebackup` invocation sends, before `BASE_BACKUP` is ever reached, and
`Decode_Command`'s documented promise to decode "the command grammar emitted
by PostgreSQL" (`replication.ads:161-166`) is broken. Two distinct fixes are
needed: accepting `TEMPORARY` in its grammatical position is a pure parser
correction with no API change, whereas representing a physical-slot creation
needs a new `Command_Kind` variant (the current enum documents only
`CREATE_REPLICATION_SLOT LOGICAL` at `replication.ads:151`) plus a `RESERVE_WAL`
accessor — an API decision, not something to invent silently.

---

### REPL-3: `Read_Standby_Message` raises `Protocol_Error` on a standby-initiated `CopyDone`

**Verdict:** CONFIRMED. Confidence should be raised from the report's "Medium":
PostgreSQL's walsender explicitly treats a mid-stream standby `CopyDone` as a
normal event, and PostgreSQL's own WAL-streaming clients send it routinely.

**Severity:** P1 (raised from the report's P2) — valid, routine input produces
an unexpected exception on a path the library itself drives in a loop, and the
resulting unwind loses standby progress.

**Repro:** `tests/repros/src/repro_repl_3.adb`

**Output** (`cd tests/repros && ./run.sh repro_repl_3 90`, exit status **1**):

```
  -- control: a StandbyStatusUpdate decodes as STANDBY_STATUS_UPDATE
  -- standby sends a bare CopyDone ('c') while the primary awaits feedback
  --   Read_Standby_Message raised Protocol_Error: replication streaming requires a CopyData message
  -- contrast: Sessions.Read_Copy_Command classifies the same bytes as FRONTEND_COPY_DONE
  ok: harness sanity check: a StandbyStatusUpdate is read and decoded
  ok: harness sanity check: the session layer classifies the queued frame as Frontend_Copy_Done
  FAILED: a standby-initiated CopyDone is not reported as a malformed replication frame (PostgreSQL's walsender answers it with its own CopyDone)
  FAILED: the primary can observe end-of-COPY through the feedback-reading API instead of unwinding on Protocol_Error
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:**
`Replication.Server_Sessions.Read_Standby_Message`
(`src/flyology-postgres-replication-server_sessions.adb:201-206`) feeds
whatever `Sessions.Read_Command` returns straight into `Decode`, which requires
a CopyData frame (`src/flyology-postgres-replication.adb:929-931`,
`Require (Protocol.Code (Item) = 'd', "replication streaming requires a
CopyData message")`). A standby closing its send direction mid-stream is not an
error in PostgreSQL: `walsender.c` 18.4:2260-2331 reads standby replies while
streaming and, on `PqMsg_CopyDone` (`:2323-2330`), answers with its own
`CopyDone` instead of failing. PostgreSQL's WAL clients send exactly that while
the server is still streaming — `receivelog.c` 18.4:1156-1163 (WAL segment
boundary) and 18.4:1213-1225 (`CheckCopyStreamStop`) both call `PQputCopyEnd`
with `still_sending` true, which is how `pg_receivewal` and `pg_basebackup`'s
background WAL streamer stop. The path is reachable inside this library:
`managed_primary.adb:80-102` `Await_Feedback` loops on `Read_Standby_Message`
and is invoked at `:161` (physical) and `:281` (logical) *before*
`Complete_Copy` at `:171`/`:289` switches to `Sessions.Read_Copy_Command`,
which does classify `CopyDone`. Consequence: a standby that stops at a normal
point turns a clean end-of-COPY into `Protocol.Protocol_Error` that propagates
out through `Stream_Physical`'s `when others => ... raise;` handler
(`managed_primary.adb:178-184`), so the physical slot is never advanced to the
feedback LSN the standby already reported, and the caller receives the same
exception text a genuinely malformed frame produces — with no typed way to tell
the two apart. The repro's contrast line shows the session layer *can* see the
frame (`Frontend_Copy_Done`); only the replication feedback API cannot. A fix
needs an API decision: either a `CopyDone`-carrying result from
`Read_Standby_Message` or a distinct end-of-stream exception/predicate; the
current spec (`server_sessions.ads:106-112`) documents neither.

---

### REPL-4: Replication `SHOW` rejects dotted GUC names that PostgreSQL accepts

**Verdict:** CONFIRMED as a genuine rejection of valid PostgreSQL syntax, but
**no stock PostgreSQL client sends a dotted `SHOW`**, so it is not a
default-path interop break.

**Severity:** P2 (unchanged from the report).

**Repro:** `tests/repros/src/repro_repl_4.adb`

**Output** (`cd tests/repros && ./run.sh repro_repl_4 90`, exit status **1**):

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

**Description:**
Both the `Show` constructor (`src/flyology-postgres-replication.adb:183-189`)
and `Decode_Command`'s SHOW branch (`:503-514`) validate the parameter with
`Is_Option_Name` (`:100-104`), which admits only `[A-Za-z0-9_]` and therefore
rejects `.`. PostgreSQL's replication grammar builds a dotted GUC name
explicitly — `repl_gram.y` 18.4:153-164 (identical at 14.23:141-152):
`show: K_SHOW var_name` with `var_name: IDENT | var_name '.' IDENT { $$ =
psprintf("%s.%s", $1, $3); }`, and `repl_scanner.l` 18.4:211-214 returns `.` as
itself — so `SHOW myext.my_setting` is valid replication-mode syntax on every
supported major, and namespaced GUCs are the standard way PostgreSQL extensions
expose settings. Consequence: a caller issuing `SHOW` for a namespaced GUC, or
a Flyology server decoding such a `SHOW` from a client, gets
`Protocol_Error "invalid replication SHOW parameter name"` for a parameter
PostgreSQL would accept. Impact stays low: the only `SHOW` commands stock
clients issue in replication mode are `SHOW wal_segment_size` and
`SHOW data_directory_mode` (`streamutil.c` 18.4:293 and :367), neither dotted,
and `managed_primary.adb:318-331` answers only core GUCs. Related but not
separately reported: `Is_Option_Name` also rejects `$` and 8-bit bytes, which
PostgreSQL's `ident_cont` allows (`repl_scanner.l` 18.4:106-109).

---

## Summary

| ID | Verdict | Severity (report → verified) | Repro |
|----|---------|------------------------------|-------|
| REPL-1 | CONFIRMED | P1 → P1 | `repro_repl_1` |
| REPL-2 | CONFIRMED (one sub-claim corrected) | P2 → **P1** | `repro_repl_2` |
| REPL-3 | CONFIRMED | P2 → **P1** | `repro_repl_3` |
| REPL-4 | CONFIRMED | P2 → P2 | `repro_repl_4` |

Every repro prints `BUG REPRODUCED` and exits 1 on the current sources; each
asserts the corrected behavior, so a fixed library prints `PASS` and exits 0.
No file outside `tests/repros/src/` was created or modified.

---

### REPL-5: `Send_Identify_System` declares the `timeline` column as int4 for every peer, but PostgreSQL 16 changed it to int8

**Verdict:** CONFIRMED.

**Severity:** P2 (as reported). Protocol fidelity only: the advertised type
OID and width are wrong for three of the five supported majors, but the text
value on the wire is unchanged and neither stock client consults the OID, so
nothing in the PostgreSQL tree misbehaves against it. The `.ads` and README
make no typed promise about the column, so no documented contract sentence is
violated either — this is contract drift against the server being imitated,
not a wrong result on a reachable path.

**Repro:** `tests/repros/src/repro_repl_5.adb`

**Output** (`./run.sh repro_repl_5`, exit status 1):

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

**Description:** `src/flyology-postgres-replication-server_sessions.adb:47-79`
(`Send_Identify_System`) builds the four-column IDENTIFY_SYSTEM result set with
`Protocol.Make_Field_Description ("timeline", Type_Oid => 23, Type_Size => 4)`,
an unconditional int4 declaration, while
`src/backend/replication/walsender.c` `IdentifySystem()` splits on the major:
14.23 `:444-445` and 15.18 `:460-461` declare column 2 with `INT4OID` and fill
it with `Int32GetDatum` (`:458`, `:474`), whereas 16.14 `:462-463`, 17.10
`:475-476` and 18.4 `:445-446` declare it with `INT8OID` and fill it with
`Int64GetDatum` (`:476`, `:489`, `:459`). A Flyology-based primary or proxy
therefore advertises the wrong column type to any PostgreSQL 16, 17 or 18
peer — three of the five supported majors — and the wrong width with it
(int8 typlen 8 versus the 4 sent). The consequence is bounded: the DataRow
payload is still the correct decimal text (`server_sessions.adb:66-74` sends
`Protocol.Text_Column (Decimal_Image (Timeline))`), and both stock consumers
read it as text without looking at the descriptor —
`src/backend/replication/libpqwalreceiver/libpqwalreceiver.c`
`libpqrcv_identify_system` uses `PQgetvalue (res, 0, 1)` through
`pg_strtoint32` (18.4 `:458`), and `src/bin/pg_basebackup/streamutil.c`
`RunIdentifySystem` uses `PQgetvalue (res, 0, 1)` through `atoi` (18.4
`:443`) — so walreceiver, `pg_basebackup` and `pg_receivewal` are unaffected,
as is this library's own client path, which never parses the OID. What breaks
is any typed or generic client that binds by result type, or a fidelity test
that diffs the RowDescription against a real server. Unlike BACKUP-7, whose
`tli` column is int8 in all five majors and so admits a single unconditional
correction, this column has two correct answers, and
`src/flyology-postgres-replication-server_sessions.ads:9-15` gives
`Send_Identify_System` no server major to select between them: the API cannot
express the 16+ answer at all. A fix therefore needs a user decision on how
the peer major reaches this call — a new `Server_Major` parameter (the
repository already has `Base_Backups.Server_Major`, a `14 .. 18` subtype at
`src/flyology-postgres-replication-base_backups.ads:11`, and the defaulted
`Server_Major : Positive := 18` formal on `Replication.Create_Logical_Slot`
at `src/flyology-postgres-replication.ads:95`, so either shape has
precedent), versus carrying the major on the `Sessions.Session`, versus
leaving the choice to the caller by exposing the column descriptors. Adding a
defaulted parameter changes the answer for existing callers
(`managed_primary.adb:311`, `tests/src/postgres_test_replication_server.adb:254`,
`examples/psqlbench/src/psqlbench_links.adb:669`) depending on the default
chosen, which is itself a policy decision and not authorized by the finding.
