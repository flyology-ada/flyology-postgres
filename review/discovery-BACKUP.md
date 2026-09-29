# Discovery report: BACKUP (Base_Backups, Server_Sessions, Persistence, Memory, Managed_Primary, Prepared_Consumer)

Scope: read-only review of
`src/flyology-postgres-replication-base_backups.ads/.adb`,
`src/flyology-postgres-replication-base_backups-server_sessions.ads/.adb`,
`src/flyology-postgres-replication-persistence.ads/.adb`,
`src/flyology-postgres-replication-persistence-memory.ads/.adb`,
`src/flyology-postgres-replication-managed_primary.ads/.adb`,
`src/flyology-postgres-replication-prepared_consumer.ads/.adb`,
`docs/BASE_BACKUP.md`, README paragraphs, and the relevant Client copy-state
transitions in `src/flyology-postgres-client.adb`. PostgreSQL wire behaviour
was checked against the checked-out server sources in
`tests/.cache/postgres/{14.23,15.18,16.14,17.10,18.4}-openssl/source`
(`basebackup.c`, `basebackup_copy.c`, `repl_gram.y`, `repl_scanner.l`,
`walsender.c`), not from memory.

Severity rubric (as given): P0 = memory/aliasing unsafety, security, hang or
deadlock in normal operation, data-loss-class invariant violation, or
interop-breaking protocol violation; P1 = wrong result or unexpected exception
on valid input via a reachable path, or a documented contract violated; P2 =
edge-case incorrectness, wrong diagnostics, or contract drift needing unusual
input.

| ID | Title | Severity | Confidence |
| --- | --- | --- | --- |
| BACKUP-1 | `Memory.Promote` stores only the newest history line, so `History` for the third and later timelines is not a PostgreSQL history file | P1 | medium-high |
| BACKUP-2 | `Memory.Oldest_Restart_LSN` is order-dependent when a live slot has `Restart = 0` | P2 | high |
| BACKUP-3 | `Memory.Append` on a fully retained-away store rewinds `Current_LSN` and reuses WAL positions | P2 | medium |
| BACKUP-4 | `Persistence.Generation` keeps returning the stale nonzero lease after `Release` | P2 | high |
| BACKUP-5 | `Prepared_Consumer.Prepare` overwrites a `Target_Applied` marker for the same GID, defeating the replay guard and breaking GID reuse | P2 | medium-high |
| BACKUP-6 | `Memory.Create` accepts an active/leased or invalidated snapshot as initial state, creating a slot nobody can acquire or drop | P2 | high |
| BACKUP-7 | `Server_Sessions.Send_Position` declares `tli` as int4 where PostgreSQL sends int8 | P2 (low impact) | high |

No P0 findings. The BASE_BACKUP client (command text, v14 multi-COPY state
machine, v15+ multiplexed decoder, numeric decoding, error/cancel drain) was
checked against the server sources and found consistent; see "Areas reviewed
with no findings".

---

### BACKUP-1: `Memory.Promote` stores only the newest history line, so `History` for the third and later timelines is not a PostgreSQL history file

Location: `src/flyology-postgres-replication-persistence-memory.adb:255-284`
(`Promote`), `:244-253` (`History`); contract in
`src/flyology-postgres-replication-persistence.ads:219-236`
(`History`: "Read a timeline history file exactly as sent to a standby";
`Promote`: "persist a timeline whose history records Parent and Fork_LSN").
Served verbatim by `src/flyology-postgres-replication-managed_primary.adb:332-336`
(`Timeline_History_Command`).

Severity: P1. Confidence: medium-high (the Memory spec says "Persist a
PostgreSQL-format history *line*", which could be read as a deliberate
simplification, but the interface promises a history *file* as sent to a
standby, and Managed_Primary forwards it to real standbys).

Evidence:
```ada
      New_Timeline := Item.Timeline + 1;
      Item.Histories (Index) :=
        (Timeline => New_Timeline,
         Data     => Flyology.Bytes.From_Byte_String
           (Parent_Image & Character'Val (9) & Replication.Image (Fork_LSN)
            & Character'Val (9) & "promotion" & Character'Val (10)));
```
Only one line is written; the parent's own history is not prepended.
PostgreSQL's `writeTimeLineHistory` copies the parent timeline's history file
and appends the new `<parentTLI>\t<switchpoint>\t<reason>` line, so
`0000000N.history` lists every ancestor. `readTimeLineHistory` on the standby
builds the ancestry list from that file, and `rescanLatestTimeLine` refuses a
timeline whose history does not contain the standby's current timeline
("new timeline %u is not a child of database system timeline %u").

Failure scenario: application promotes twice on a Memory-backed (or the
journaling test store, which wraps Memory) primary: 1 -> 2 -> 3. A standby
that is still on timeline 1 connects, IDENTIFY_SYSTEM reports 3, walreceiver
fetches `TIMELINE_HISTORY 2` and `TIMELINE_HISTORY 3`. File 3 contains only
`2<TAB>X/Y<TAB>promotion`, so timeline 1 is absent from its ancestry and the
standby cannot follow. Any consumer parsing the chain (e.g. to find the
switch point for timeline 1) gets a wrong answer.

Reproduction sketch (no PostgreSQL needed):
```ada
package M is new Persistence.Memory (Capacity => 4);
S : M.Store;  T2, T3 : UInt32;
M.Promote (S, 1, 16#64#, T2);      --  T2 = 2
M.Promote (S, 2, 16#C8#, T3);      --  T3 = 3
--  Expected (PostgreSQL format for 00000003.history):
--    "1" & HT & "0/64" & HT & "promotion" & LF &
--    "2" & HT & "0/C8" & HT & "promotion" & LF
--  Actual: M.History (S, 3) = "2" & HT & "0/C8" & HT & "promotion" & LF only
```

Existing coverage: `tests/src/replication_persistence_conformance.adb:140-145`
promotes exactly once and only checks `History (2)'Length > 0`.
`tests/src/postgres_test_managed_physical_primary.adb` exercises a single
1 -> 2 switch, which the one-line file happens to satisfy.

---

### BACKUP-2: `Memory.Oldest_Restart_LSN` is order-dependent when a live slot has `Restart = 0`

Location: `src/flyology-postgres-replication-persistence-memory.adb:163-175`.
Contract: `persistence.ads:175-178` ("Oldest restart LSN, or zero when no slot
retains WAL"); consumer `managed_primary.adb:104-114` (`Apply_Retention`).

Severity: P2. Confidence: high.

Evidence:
```ada
      for Item_Entry of Item.Slots loop
         if Item_Entry.State.Present and then not Item_Entry.State.Invalid
           and then
             (Result = 0 or else Item_Entry.State.Restart < Result)
         then
            Result := Item_Entry.State.Restart;
```
`Result = 0` is used both as "nothing seen yet" and as a legitimate value.
`Make_Slot` accepts `Restart_LSN => 0`, and Managed_Primary itself creates a
logical slot at `Current_LSN`, which is 0 on a fresh empty Memory store
(`WAL_Base = 0`, no data).

Failure scenario: slots A (`Restart 0`) and B (`Restart 50`). Slot order
[A, B]: first iteration sets `Result := 0`, second sees `Result = 0` and sets
`Result := 50` -> returns 50. Order [B, A]: `Result := 50`, then `0 < 50` ->
`Result := 0` -> returns 0. The same slot set yields either "retain from 50"
(`Apply_Retention` trims WAL below 50) or "nothing retains WAL" (no trim at
all, unbounded growth) depending on array position, which changes after a
Drop reuses a free index. Whichever semantic is intended for a zero restart
LSN, the function must not depend on iteration order.

Reproduction sketch:
```ada
M.Create (S, "a", Make_Slot (Physical_Slot, 0), R);
M.Create (S, "b", Make_Slot (Physical_Slot, 50), R);
--  M.Oldest_Restart_LSN (S) = 50
--  fresh store, reversed creation order ("b" then "a"):
--  M.Oldest_Restart_LSN (S) = 0
```
Existing coverage: conformance test line 123 checks a single value (110)
with no zero-restart slot.

---

### BACKUP-3: `Memory.Append` on a fully retained-away store rewinds `Current_LSN` and reuses WAL positions

Location: `src/flyology-postgres-replication-persistence-memory.adb:206-217`
(`Append`), `:219-242` (`Retain_From`). Contract: `persistence.ads:199-206`
("Start: Current_LSN, or the base position of an empty store"), Memory spec
"@exception Store_Error A nonempty append is not contiguous".

Severity: P2. Confidence: medium (the phrase "empty store" is ambiguous; the
finding is that a store whose bytes were all trimmed by `Retain_From` still
has a meaningful `Current_LSN`, and the code lets it go backwards).

Evidence:
```ada
      if Flyology.Bytes.To_Array (Item.WAL_Data)'Length = 0 then
         Item.WAL_Base := Start;
      elsif Start /= Current_LSN (Item) then
         raise Store_Error with "WAL append is not contiguous";
      end if;
```
`Retain_From (Oldest = Current_LSN)` sets `WAL_Data := Empty` and
`WAL_Base := Oldest`, so the store looks "empty" to `Append` although
`First_LSN = Current_LSN = Oldest` is a real position.

Failure scenario: `Append (100, 6 bytes)` -> `Current = 106`;
`Retain_From (106)` (exactly what `Apply_Retention` does when the only slot's
restart equals the current end); then `Append (50, 4 bytes)` is accepted:
`First_LSN = 50`, `Current_LSN = 54`. `Current_LSN` went from 106 to 54 and
positions 50..53 now carry bytes different from whatever a standby already
received for that range. A subsequent `Apply_Retention` with a slot at 103
raises "slot retention floor exceeds available WAL" instead of the store
rejecting the rewind at its source.

Reproduction sketch:
```ada
M.Append (S, 100, (1,2,3,4,5,6));   M.Retain_From (S, 106);
M.Append (S, 50, (9,9,9,9));        --  expected Store_Error; actual: accepted
--  M.First_LSN (S) = 50, M.Current_LSN (S) = 54  (was 106)
```
Existing coverage: conformance test lines 126-137 append once and retain a
prefix; never drains and re-appends.

---

### BACKUP-4: `Persistence.Generation` keeps returning the stale nonzero lease after `Release`

Location: `src/flyology-postgres-replication-persistence-memory.adb:147-161`
(`Release` clears `Active` but not `Lease`), accessor
`src/flyology-postgres-replication-persistence.adb:44`; contract
`persistence.ads:72-75`: "@return Nonzero generation for an acquired slot,
otherwise zero."

Severity: P2 (documented accessor contract violated on a trivially reachable
path). Confidence: high.

Evidence:
```ada
      if Released then
         Item.Slots (Index).State.Active := False;
      end if;
```
Failure scenario: after `Acquire` (lease L) and `Release`, `Load` returns a
snapshot with `Is_Active = False` and `Generation = L`. Code that uses
`Generation (State) /= 0` as the "acquired" test (as the doc invites) sees a
released slot as leased.

Reproduction sketch:
```ada
M.Create (S, "p", Make_Slot (Physical_Slot, 10), R);
M.Acquire (S, "p", Physical_Slot, A, L, St);  M.Release (S, "p", L, Ok);
St := M.Load (S, "p");
--  expected: not Is_Active (St) and Generation (St) = 0
--  actual:   not Is_Active (St) and Generation (St) = L (/= 0)
```
Existing coverage: none asserts `Generation` after `Release`.

---

### BACKUP-5: `Prepared_Consumer.Prepare` overwrites a `Target_Applied` marker for the same GID, defeating the replay guard and breaking GID reuse

Location: `src/flyology-postgres-replication-prepared_consumer.adb:7-20`
(`Prepare` -> unconditional `Put`), `memory.adb:299-326` (`Put` replaces an
existing (slot, GID) entry). Contract: package header
`prepared_consumer.ads:3-6` ("an applied marker prevents replay after target
application has been recorded"), `Acknowledge_Commit` ("Retaining the marker
until then bounds replay").

Severity: P2 (bounded by the documented Apply_Target idempotence
requirement, but the state machine is keyed only by (slot, GID) and a real
pgoutput source can legitimately deliver a new PREPARE for that key before the
previous commit has been acknowledged). Confidence: medium-high.

Evidence:
```ada
   procedure Prepare (...) is
   begin
      Stores.Put (Item.Store.all, Slot_Name, GID,
                  Stores.Make_Prepared (XID, Prepare_LSN, Payload));
```
Failure scenarios:
1. Crash-replay: consumer runs `Prepare (g)`, `Commit (g)` (Apply_Target
   invoked, phase `Target_Applied`), then fails before its feedback confirms
   the commit LSN. PostgreSQL re-decodes from the confirmed flush; when that
   is before the PREPARE, `ReorderBufferFinishPrepared` re-sends the PREPARE
   (and then COMMIT PREPARED). The consumer's `Prepare (g)` replaces the
   `Target_Applied` record with a fresh `Prepared` record, so the following
   `Commit (g)` returns `Applied_Now = True` and calls Apply_Target again.
   The header says the marker prevents exactly this replay.
2. GID reuse: PostgreSQL allows a GID to be reused as soon as the earlier
   prepared transaction has committed. Source prepares xact 1 as `g`,
   commits it, then prepares xact 2 as `g` before the consumer has
   acknowledged the commit LSN of xact 1. `Prepare (g, XID 2)` discards
   xact 1's marker; the consumer's later `Acknowledge_Commit (g)` (for
   xact 1) either raises "prepared commit acknowledgement precedes target
   application" (phase is now `Prepared`) or, if xact 2 has been committed
   meanwhile, removes xact 2's marker instead.

Reproduction sketch (Memory store + counting Apply_Target):
```ada
C.Prepare (S, "slot", "g", XID => 1, Prepare_LSN => 10, Payload => (1,2));
C.Commit  (S, "slot", "g", Applied);           --  Applied = True, count = 1
C.Prepare (S, "slot", "g", XID => 1, Prepare_LSN => 10, Payload => (1,2));  --  replayed PREPARE
C.Commit  (S, "slot", "g", Applied);
--  expected: Applied = False, count = 1 (marker retained)
--  actual:   Applied = True,  count = 2
```
Existing coverage: `tests/src/replication_tests.adb:1346-1364` covers one
prepare, commit, replacement-consumer commit (no re-apply), acknowledge; it
never re-prepares the same GID.

---

### BACKUP-6: `Memory.Create` accepts an active/leased or invalidated snapshot as initial state, creating a slot nobody can acquire or drop

Location: `src/flyology-postgres-replication-persistence-memory.adb:36-57`.
Contract: `persistence.ads:93-103` ("State: Initial state created by
Make_Slot"), Memory spec "@exception Store_Error State is invalid or capacity
is exhausted".

Severity: P2 (needs unusual input: a `Load`-ed snapshot passed to `Create`,
e.g. when copying slots between stores). Confidence: high.

Evidence:
```ada
      if Name'Length = 0 or else not State.Present then
         raise Store_Error with "invalid replication slot creation";
      end if;
      ...
      Item.Slots (Index) := (Name => To_Unbounded_String (Name), State => State);
```
Only `Present` is validated; `Active`, `Lease`, `Invalid` are copied as-is.

Failure scenario: `Create ("b", Load (Other, "a"))` while "a" is acquired
elsewhere stores "b" with `Active = True` and a foreign lease. `Acquire ("b")`
returns `Already_Active` forever, `Drop ("b")` returns `False` (active), and
`Oldest_Restart_LSN` keeps counting it. Only a caller that happens to know the
foreign lease value can `Release` it. The documented Store_Error is not raised.

Reproduction sketch:
```ada
M.Create (S, "a", Make_Slot (Physical_Slot, 10), R);
M.Acquire (S, "a", Physical_Slot, A, L, St);        --  St.Active = True
M.Create (S, "b", St, R);                            --  expected Store_Error; actual Created
M.Acquire (S, "b", Physical_Slot, A, L2, St2);       --  Already_Active, L2 = 0
M.Drop (S, "b", Dropped);                            --  Dropped = False
```
Existing coverage: none.

---

### BACKUP-7: `Server_Sessions.Send_Position` declares `tli` as int4 where PostgreSQL sends int8

Location: `src/flyology-postgres-replication-base_backups-server_sessions.adb:23-46`.

Severity: P2, low impact (this library's own Receiver and pg_basebackup read
the column as text and never check the type OID). Confidence: high.

Evidence:
```ada
            Protocol.Make_Field_Description
              ("tli", Type_Oid => 23, Type_Size => 4)),
```
PostgreSQL 14 (`basebackup.c` `SendXlogRecPtrResult`) and 15-18
(`basebackup_copy.c`) declare `tli` as `INT8OID` with the comment
"int4 would not be wide enough for this, as TimeLineID is unsigned". A proxy
built on this package therefore advertises a different row shape from the
server it is proxying; a typed client would mis-decode timelines above
2^31-1 (the text value itself is still correct). The CommandComplete tag
"SELECT 1" (PostgreSQL: "SELECT") is cosmetic.

Existing coverage: `tests/src/tests.adb` `Test_Base_Backup_Client_State`
round-trips through this library's Receiver only.

---

## Areas reviewed with no findings

- Command text for each major, checked against `repl_gram.y`/`repl_scanner.l`
  and `parse_basebackup_options` in the checked-out 14.23-18.4 sources:
  legacy keyword forms and any-order option list for 14; parenthesised
  `generic_option` list for 15+ with `PROGRESS true`, `WAL true`,
  `WAIT false`, `TABLESPACE_MAP true`, `VERIFY_CHECKSUMS false`
  (`defGetBoolean` accepts IDENT booleans), `CHECKPOINT 'fast'`,
  `MAX_RATE n` (UCONST, 32..1048576 in all majors), `MANIFEST
  'yes'|'force-encode'`, `MANIFEST_CHECKSUMS` only with an enabled manifest
  (server rejects it otherwise), `TARGET`/`TARGET_DETAIL`,
  `COMPRESSION`/`COMPRESSION_DETAIL`, bare `INCREMENTAL` (17+), identifiers
  downcased by the scanner, single-quote doubling is the only escaping the
  replication scanner needs (no backslash processing).
- Omitting `TARGET 'client'` on 15+: I initially suspected this selected the
  legacy per-tablespace sink; the 15.18-18.4 sources show `use_copytblspc` is
  set but never read and `bbsink_copystream_new` is always used, so the
  multiplexed stream is correct. Refuted.
- v14 receiver state machine versus `perform_base_backup`/`SendBackupHeader`/
  `SendBackupManifest`: start result set, tablespace rows (NULL oid/location
  for base, NULL size without PROGRESS), one CopyOutResponse+CopyDone per
  tablespace with no CommandComplete between, optional manifest COPY, then end
  result set, `CommandComplete BASE_BACKUP`, ReadyForQuery. Client's
  `Receive_Copy_Event` handles CopyOutResponse and RowDescription in
  `Copy_Completion_Active` for exactly this.
- v15+ multiplexed decoder versus `basebackup_copy.c`: 'n' (two C strings,
  empty location for base), 'd' (payload after tag), 'p' (int64 at offset 1;
  Wire positions are 0-based so `Position => 1` is correct), 'm' (single
  byte), progress frames sent even without PROGRESS (`end_archive`), archive
  count equals tablespace rows, manifest presence, trailing-byte and unknown
  tag rejection, CopyDone then end result set.
- Numeric decoding: `Replication.Value` for `%X/%X`, `Parse_UInt32` for tli,
  `Parse_UInt64` for KiB size, NULL handling for spcoid/spclocation/size.
- Error/cancel mid-stream: ErrorResponse in either path moves to
  Awaiting_Ready and the following ReadyForQuery yields Complete; Client
  stays `Simple_Query_Active` on a simple-query error, so the documented
  "call until Complete after Error" holds.
- UPLOAD_MANIFEST client path versus `walsender.c` `UploadManifest`:
  CopyInResponse, CopyData/CopyDone/CopyFail, CommandComplete then
  ReadyForQuery; Server_Sessions manifest upload helpers mirror it.
- Server_Sessions frame encoders ('n', 'm', 'd', 'p' at offset 1, CopyDone
  only between legacy streams, double CommandComplete before ReadyForQuery
  matching walsender's `EndReplicationCommand`).
- Persistence lease semantics: stale lease fenced in Advance/Release, zero
  lease rejected, generation counter wrap guard, Kind_Mismatch/Invalidated/
  Already_Active precedence, Drop refuses active slots, monotonic Advance
  (equal LSN allowed, backwards rejected, confirmed >= restart).
- Managed_Primary: slot acquired before validation and released in the
  exception handler; Advance only after standby feedback with flushed >=
  streamed end (walreceiver reports flush = keepalive end when idle);
  retention applied after release; logical start position clamped to
  confirmed LSN; COPY BOTH completion order; DROP WAIT bounded by the
  configured deadline.
- Prepared_Consumer: Commit applies once per durable phase, Mark failure
  raised, Acknowledge requires Target_Applied, Rollback refuses applied
  state (documented).

## Observations not counted

- `Begin_Manifest_Upload` raises `Database_Error` on an ErrorResponse with
  the ReadyForQuery still unread; the spec's drain guidance ("after finish or
  abort, consume ... until Is_Ready") does not mention this case, and
  `Client.Send_Command` does not reject a new Query while
  `Simple_Query_Active`, so a caller that proceeds to `Start` gets a
  misleading "BASE_BACKUP became ready before its final result". Doc gap /
  Client laxity rather than a Base_Backups defect.
- `Managed_Primary` ignores the `TIMELINE` clause of physical
  START_REPLICATION and never emits the next-timeline result set after
  CopyDone. The managed physical integration test shows the application is
  expected to select the timeline's WAL range itself, and a PostgreSQL
  walreceiver tolerates a bare CommandComplete (it re-requests via history
  files), so this is a documented composition boundary, not a defect.
- `Await_Feedback` has no overall deadline; a peer that keeps sending status
  updates with a flush below the target keeps the loop alive indefinitely.
  Real standbys converge, so not counted as a hang in normal operation.
- `Memory.Current_LSN` and `Memory.Read` copy the whole WAL buffer
  (`To_Array`) on every call; performance only.
- `Memory.Invalidate` on an active slot lets the holder keep advancing while
  retention ignores it; consistent with PostgreSQL invalidation semantics.
- `Set_Target (Client_Target)` and `Set_Compression (No_Compression)` are
  rejected on PostgreSQL 14 even though they express the default; over-strict
  but documented ("setters reject options unavailable on Item's server
  major").
- `Rollback`/`Commit` for an unknown GID raise `Protocol_Error`, whereas
  PostgreSQL's apply worker silently skips a ROLLBACK PREPARED whose PREPARE
  predates the slot's two-phase start point (pgoutput does send such
  rollbacks). Documented exception policy; applications must pre-check with
  `Load`.
- Server_Sessions `Send_Position` CommandComplete tag "SELECT 1" versus
  PostgreSQL's "SELECT": cosmetic.
