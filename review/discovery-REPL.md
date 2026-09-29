# Discovery report: REPL — streaming replication protocol core

## Scope

Read-only correctness review of the physical/logical replication *transport*
core (not the pgoutput codec, not BASE_BACKUP/persistence):

- `src/flyology-postgres-replication.ads` / `.adb` — LSN text, command
  constructors, `Decode_Command`, CopyData stream-message constructors/decoder.
- `src/flyology-postgres-replication-feedback.ads` / `.adb` — standby reporter.
- `src/flyology-postgres-replication-server_sessions.ads` / `.adb` — backend
  response sequences for replication commands and COPY BOTH.
- Context: `src/flyology-postgres-client.adb` COPY BOTH path
  (`Receive_Copy_Event`, `Send_Copy_Data`, `Send_Command`),
  `src/flyology-postgres-replication-managed_primary.adb`,
  `src/flyology-postgres-framing.adb`, `src/flyology-postgres-transports.ads`,
  `README.md` "Streaming replication", `tests/REPLICATION_VALIDATION.md`,
  `tests/src/replication_tests.adb`, `postgres_test_replication*.adb`.

Checked against PostgreSQL 14–18 walsender/walreceiver behavior and the
"Streaming Replication Protocol" docs.

## Severity rubric

- P0 = memory/aliasing unsafety, security, hang/deadlock in normal operation,
  or interop-breaking protocol violation.
- P1 = wrong result or unexpected exception on valid input via a reachable
  path, or a documented contract violated.
- P2 = edge-case incorrectness, wrong diagnostics, or contract drift needing
  unusual input.

## Summary table

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| REPL-1 | `Decode_Command` rejects PostgreSQL's valueless `TWO_PHASE` (and `FAILOVER`) in `CREATE_REPLICATION_SLOT` | P1 | High (TWO_PHASE); Medium (FAILOVER) |
| REPL-2 | `Decode_Command` cannot parse `CREATE_REPLICATION_SLOT` with `TEMPORARY` or a `PHYSICAL` slot, which real PG clients send | P2 | High |
| REPL-3 | `Read_Standby_Message` raises `Protocol_Error` on a standby-initiated `CopyDone` (valid end-of-COPY) | P2 | Medium |
| REPL-4 | Replication `SHOW` rejects dotted GUC names that PostgreSQL accepts | P2 | Medium |

Known and excluded (not re-reported): PROTO-1 (Read_Message re-arms Timeout per
transport read), PROTO-4 (startup "replication" value case-sensitivity).

---

## Findings

### REPL-1: `Decode_Command` rejects PostgreSQL's valueless `TWO_PHASE` (and `FAILOVER`) option in `CREATE_REPLICATION_SLOT`

Location: `src/flyology-postgres-replication.adb:587-614`
Severity: P1
Confidence: High for `TWO_PHASE`; Medium for `FAILOVER`.

Evidence (option-list branch of the CREATE_REPLICATION_SLOT decoder):

```
587                  elsif Ada.Characters.Handling.To_Lower
588                    (Option_Name (Item)) = "two_phase"
589                  then
...
594                     Require
595                       (Option_Has_Value (Item),
596                        "TWO_PHASE requires a value");
...
611                  else
612                     raise Protocol.Protocol_Error with
613                       "unsupported logical slot option " & Option_Name (Item);
614                  end if;
```

`Parse_Options` only attaches a value to an option when the next non-space
character is a `'` (`src/flyology-postgres-replication.adb:447-452`); otherwise
the option is valueless. So a `TWO_PHASE` token with no `'...'` after it decodes
as `Has_Value = False`, and the `Require` at :594-596 raises `Protocol_Error`.

PostgreSQL's own walreceiver (`libpqrcv_create_slot` in
`libpqwalreceiver.c`, PG15+) emits the boolean options **without a value** in
the parenthesized grammar, e.g.

```
CREATE_REPLICATION_SLOT "sub_slot" LOGICAL pgoutput (TWO_PHASE, SNAPSHOT 'nothing')
```

On the server, PG parses this with `defGetBoolean(defel)`, and
`defGetBoolean` returns `true` when the DefElem's argument is NULL — i.e.
valueless `TWO_PHASE` is valid and means "true". PG17 similarly appends a
valueless `FAILOVER` when slot failover is requested; the `else` arm at
:611-614 rejects `FAILOVER` outright as an "unsupported logical slot option".

The existing unit test enshrines the wrong behavior:
`tests/src/replication_tests.adb:427-429` asserts
`CREATE_REPLICATION_SLOT ... (TWO_PHASE)` **is rejected**, which is the exact
command a real two-phase subscriber sends.

Failure scenario: A Flyology server acting as a logical-replication primary
receives `CREATE_REPLICATION_SLOT` from a real PostgreSQL subscription worker
whose subscription has `two_phase = true` (and/or `failover = true` on PG17+).
`Decode_Command` raises `Protocol.Protocol_Error`, so the server rejects a
valid PostgreSQL command and the subscription cannot create its slot. This is
a documented-contract violation: `Decode_Command` promises to "Decode the
command grammar emitted by PostgreSQL" (`.ads:161-166`).

Note the constructor side is asymmetric but consistent with PG's *value* form:
`Create_Logical_Slot (..., Two_Phase => True)` emits `TWO_PHASE 'true'`
(`.adb:228`), which PG accepts; the bug is purely that the *decoder* refuses the
valueless form PG itself produces.

Reproduction test sketch (no real PostgreSQL needed):
- Build a `Protocol.Message` with tag `'Q'` and C-string payload
  `CREATE_REPLICATION_SLOT sub LOGICAL pgoutput (TWO_PHASE, SNAPSHOT 'nothing')`
  (the `Query` helper in `tests.adb` / `replication_tests.adb` does this).
- Call `Replication.Decode_Command (Message)`.
- Expected: a `Create_Logical_Slot_Command` with `Two_Phase (Item) = True`,
  `Snapshot (Item) = No_Snapshot`.
- Actual: raises `Protocol.Protocol_Error "TWO_PHASE requires a value"`.
- Second case: `... pgoutput (FAILOVER, SNAPSHOT 'nothing')` →
  raises `Protocol.Protocol_Error "unsupported logical slot option FAILOVER"`.

Existing coverage: `tests/src/replication_tests.adb:427-432` (asserts the
*wrong* rejection); the PG18 subscription integration test in
`REPLICATION_VALIDATION.md` uses only `SNAPSHOT 'use'` tablesync slots, so it
never exercises valueless `TWO_PHASE`/`FAILOVER`.

---

### REPL-2: `Decode_Command` cannot parse `CREATE_REPLICATION_SLOT` with `TEMPORARY` or a `PHYSICAL` slot

Location: `src/flyology-postgres-replication.adb:519-536`
Severity: P2
Confidence: High

Evidence:

```
519       elsif Is_Keyword (First, "CREATE_REPLICATION_SLOT") then
520          Result.Message_Kind := Create_Logical_Slot_Command;
521          declare
522             Name : constant String := Next_Identifier (Text, Cursor);
523          begin
524             Require (Is_Slot_Name (Name), "invalid replication slot name");
525             Result.Slot_Data := Flyology.Bytes.From_Byte_String (Name);
526          end;
527          Expect_Keyword (Text, Cursor, "LOGICAL");
```

Immediately after the slot name the decoder unconditionally requires the
keyword `LOGICAL`. PostgreSQL's grammar is
`CREATE_REPLICATION_SLOT slot [TEMPORARY] { PHYSICAL [RESERVE_WAL] | LOGICAL plugin ... }`.
No `TEMPORARY`, `PHYSICAL`, or `RESERVE_WAL` handling exists anywhere in the
core replication body (grep for those keywords finds only `Start_Physical` /
`START_REPLICATION`).

Real PostgreSQL clients emit both forms:
- `pg_basebackup` by default creates a temporary physical slot:
  `CREATE_REPLICATION_SLOT "pg_basebackup_NNNN" TEMPORARY PHYSICAL RESERVE_WAL`.
- `pg_receivewal --create-slot`, `pg_basebackup -C`: physical slot creation.
- `libpqrcv_create_slot` appends ` TEMPORARY` right after the slot name when a
  temporary logical slot is requested, i.e.
  `CREATE_REPLICATION_SLOT "s" TEMPORARY LOGICAL pgoutput (...)`.

In every one of these, `Expect_Keyword (..., "LOGICAL")` at :527 sees
`TEMPORARY` (or `PHYSICAL`) and raises
`Protocol_Error "expected LOGICAL in replication command"`.

Failure scenario: A Flyology server receiving a temporary-slot create, or any
physical-slot create, from a stock PostgreSQL client rejects the command.
`Decode_Command`'s documented promise to decode "the command grammar emitted by
PostgreSQL" (`.ads:161-166`) is violated. (Physical-slot creation additionally
has no representation in `Command_Kind`, so even a corrected parser would need a
new variant — a scope decision, hence P2 rather than P1.)

Reproduction test sketch (no real PostgreSQL needed):
- `Decode_Command (Query ("CREATE_REPLICATION_SLOT s TEMPORARY LOGICAL pgoutput (SNAPSHOT 'nothing')"))`
  → expected: decoded logical create; actual: `Protocol_Error "expected LOGICAL..."`.
- `Decode_Command (Query ("CREATE_REPLICATION_SLOT s PHYSICAL RESERVE_WAL"))`
  → expected: a physical-slot create; actual: `Protocol_Error`.

Existing coverage: none; `replication_tests.adb` only exercises non-temporary
`CREATE_REPLICATION_SLOT ... LOGICAL`.

---

### REPL-3: `Read_Standby_Message` raises `Protocol_Error` on a standby-initiated `CopyDone`

Location: `src/flyology-postgres-replication-server_sessions.adb:201-206`;
decode strictness at `src/flyology-postgres-replication.adb:929-935`
Severity: P2
Confidence: Medium

Evidence:

```
201    function Read_Standby_Message
202      (Client : in out Sessions.Session; Timeout : Duration)
203       return Stream_Message is
204    begin
205       return Decode (Sessions.Read_Command (Client, Timeout));
206    end Read_Standby_Message;
```

`Decode` requires a CopyData message:

```
929       Require
930         (Protocol.Code (Item) = 'd',
931          "replication streaming requires a CopyData message");
```

`Read_Command` returns whatever typed frontend message arrives. A standby is
entitled to end the COPY BOTH stream from its side at any point by sending
`CopyDone` (tag `'c'`), including immediately after the primary requests a
reply with `Reply_Requested => True`. When that happens, `Read_Standby_Message`
feeds the `'c'` message into `Decode`, which raises
`Protocol.Protocol_Error "replication streaming requires a CopyData message"`
instead of surfacing the end-of-stream event.

The server-side streaming loops call `Read_Standby_Message` in the middle of
streaming while awaiting feedback (`managed_primary.adb:88-102`,
`server_sessions` test `postgres_test_replication_server.adb:122-124`), so a
standby that decides to stop right then turns a normal end-of-COPY into an
unexpected exception on the primary. The documented contract of
`Read_Standby_Message` ("Read and decode one standby CopyData message ...
@return Standby status update or hot-standby feedback",
`server_sessions.ads:106-112`) says nothing about `CopyDone`, so callers have no
typed way to distinguish "standby closed its direction" from "malformed frame";
both arrive as the same `Protocol_Error`.

Failure scenario: physical or logical primary calls `Read_Standby_Message`
(directly, or via `Await_Feedback`); the standby sends `CopyDone` to close its
send direction (a legal message sequence). The primary raises `Protocol_Error`
rather than proceeding to its own `Finish_Streaming`/completion path.

Reproduction test sketch (in-memory transport, no real PostgreSQL):
- Drive a server `Session` on `Memory_Transport`. Queue a frontend `CopyDone`
  message (tag `'c'`) as the next backend-to-be-read byte stream.
- Call `Replication_Sessions.Read_Standby_Message (Session, Timeout)`.
- Expected (per PG semantics): a way to observe end-of-COPY.
- Actual: raises `Protocol.Protocol_Error`.
- Contrast: `managed_primary.Complete_Copy` correctly uses
  `Sessions.Read_Copy_Command` (which classifies `CopyDone`) — the mismatch is
  that mid-stream feedback reads cannot.

Existing coverage: none; integration tests only send `CopyDone` after the
primary has already called `Finish_Streaming` and switched to
`Read_Copy_Command`.

---

### REPL-4: Replication `SHOW` rejects dotted GUC names that PostgreSQL accepts

Location: `src/flyology-postgres-replication.adb:100-104` (`Is_Option_Name`),
used by `Show` (`.adb:183-189`) and `Decode_Command`'s SHOW branch
(`.adb:503-514`)
Severity: P2
Confidence: Medium

Evidence:

```
100    function Is_Option_Name (Name : String) return Boolean is
101      (Name'Length > 0
102       and then
103         (for all Item of Name =>
104            Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'));
```

Both the `Show` constructor and the `SHOW` decode branch validate the parameter
name with `Is_Option_Name`, which forbids `.`. PostgreSQL GUC names for
extensions are namespaced with a dot (e.g. `SHOW myext.my_setting`), and PG's
replication-mode `SHOW` accepts any GUC name. `Show ("myext.setting")` raises
`Protocol_Error "invalid replication SHOW parameter name"`, and
`Decode_Command (Query ("SHOW myext.setting"))` likewise raises
`"invalid replication SHOW parameter name"` at :508-510.

Failure scenario: a caller issuing `SHOW` for a namespaced GUC, or a Flyology
server decoding such a `SHOW` from a client, gets a spurious rejection of a
valid parameter name. Impact is limited because replication `SHOW` is
overwhelmingly used for core GUCs (`wal_segment_size`, `wal_level`, ...) that
contain no dot.

Reproduction test sketch:
- `Replication.Show ("plugin.max_files")` → expected: `SHOW plugin.max_files`
  Query; actual: `Protocol_Error`.
- `Replication.Decode_Command (Query ("SHOW plugin.max_files"))` → expected:
  `Show_Command` with `Parameter = "plugin.max_files"`; actual: `Protocol_Error`.

Existing coverage: `replication_tests.adb:217-219,392-400` only test
`SHOW wal_level`.

---

## Areas reviewed with no findings

- **LSN `Image` / `Value` round trips** (`.adb:35-98`): `"0/0"`,
  `"FFFFFFFF/FFFFFFFF"`, lowercase hex, missing/empty halves, extra slash, and
  9-digit halves are all handled correctly. `Image (0) = "0/0"`; no leading
  zeros; `Hex_Value` enforces 1..8 digits per half and rejects non-hex; the
  `high << 32 | low` mapping is correct. Slash-position guards
  (`Slash > First and Slash < Last`) correctly reject `"/5"` and `"5/"`.
- **CopyData constructor/decoder symmetry** (`.adb:806-987`): field order and
  widths for XLogData (`'w'`), PrimaryKeepalive (`'k'`), StandbyStatusUpdate
  (`'r'`), HotStandbyFeedback (`'h'`) all match PG. Exact-length checks
  (18/34/25) and `>= 25` for XLogData are correct; empty WAL payload decodes to
  an empty `Data` slice without out-of-bounds access; reply-flag bytes are
  strictly validated `in 0 | 1`; trailing bytes are rejected for the
  fixed-length frames. `Contents'Length > 0` is checked before the tag byte is
  read.
- **Timestamp signedness** (`.adb:833-846`, `wire.ads:37-45`): negative
  PostgreSQL-epoch timestamps round-trip via `To_UInt64_Bits`/`To_Int64_Bits`
  (verified for `-12`).
- **`Read_U64` bounds** (`.adb:814-831`): guarded by `Wire.Try_Read_U64` /
  `Can_Read`; no out-of-bounds read on truncated input (raises `Protocol_Error`).
- **Command text generation / quoting** (`.adb:111-291`): `SQL_Literal` doubles
  single quotes and passes backslashes through verbatim, matching the PG
  replication scanner (which is *not* standard SQL string escaping). Option
  names, valued options, valueless options, and explicitly-empty-value options
  are emitted distinctly; empty option lists emit no `(...)`. Slot-name and
  option-name validation matches PG identifier rules.
- **Option parse round trip** (`.adb:340-477`, `Options` accessor :794-804):
  quoted identifiers (`""`-doubling), quoted values (`''`-doubling), values
  containing `,`/`)`, libpq-style quoted option names, and the empty `()` list
  all parse; trailing junk after the option list is rejected (`Expect_End`).
- **Stream-message accessors** (`.adb:989-1083`): each accessor's variant guard
  matches the field it exposes; `Sent_At` is correctly unguarded (all four
  variants carry a timestamp).
- **`Send_Identify_System`** (`server_sessions.adb:47-79`): four columns with
  correct labels; `timeline` typed as int4 (OID 23, size 4); `systemid`,
  `xlogpos`, `dbname` as text; empty `Database` encoded as SQL NULL.
- **`Send_Create_Logical_Slot`** (`server_sessions.adb:122-153`): four columns
  in PG order (slot_name, consistent_point, snapshot_name, output_plugin);
  empty `Snapshot_Name` → NULL, matching `SNAPSHOT 'use'`/`'nothing'`.
- **`Timeline_File_Name`** (`server_sessions.adb:24-34`): `%08X.history`
  uppercase hex matches PG history filenames.
- **`Begin_Streaming`** (`server_sessions.adb:163-171`): CopyBothResponse with
  text overall format and zero columns, matching PG.
- **Feedback reporter monotonicity** (`feedback.adb:27-53`): reports
  written=flushed=applied=Position, so `flushed <= written` always holds; the
  first `On_Wait` only arms the timer; interval gating is correct.
- **Client COPY BOTH state machine** (`client.adb:43-70,480-559,2266-2415`):
  CopyBothResponse is consumed by the query-event path (`Enter_Copy`,
  Origin=Simple_Copy) and correctly treated as unexpected inside
  `Receive_Copy_Event`; send-direction guards for CopyData/CopyDone/CopyFail are
  correct; the physical timeline-switch trailing result set is handled via the
  RowDescription branch that restores Simple_Query state.

## Observations not counted

- **TIMELINE_HISTORY `content` column type** (`server_sessions.adb:105-116`):
  both columns are declared text (OID 25). The PG docs describe `content` as
  `bytea`. The bytes are transmitted verbatim in text format and real
  walreceivers read the column bytes regardless of type OID, so this is
  cosmetic; not counted as a bug.
- **`Report_Timeout := 5.0`** (`feedback.adb:8`) is a private-body policy value,
  not a visible interface constant, and does not break a protocol rule; per the
  Ada-interface-values rule it is not a finding. If the peer stops reading, a
  `Write_Message` timeout raised inside `On_Wait` propagates out and aborts the
  in-flight read — a documented best-effort tradeoff of the `Wait_Observer`
  contract (`transports.ads:20-26`), noted for awareness.
- **Feedback reporter conflates "no position set" with position `0/0`**
  (`feedback.adb:40-45`): a stream legitimately acknowledging `0/0` stays
  silent. Documented behavior; extreme edge case.
- **`Send_Identify_System` requires `System_Id > 0` and `Timeline > 0`**
  (`server_sessions.adb:55-56`): raises on a zero systemid/timeline, which never
  occurs from a real primary; not a reachable interop problem.
