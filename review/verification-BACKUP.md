# Verification report: BACKUP findings

Adversarial verification of `discovery-BACKUP.md`. Every finding was checked
against the actual sources (`src/flyology-postgres-replication-persistence*.ad?`,
`-prepared_consumer.ad?`, `-managed_primary.adb`,
`-base_backups-server_sessions.adb`), against the documented contract
sentences (each claimed sentence was located and quoted), and against the
checked-out PostgreSQL 14.23-18.4 server sources under
`tests/.cache/postgres/*/source`. Each surviving finding has a runnable
reproduction under `tests/repros/src/`.

All seven candidates survived refutation. Two severities are corrected upward
(BACKUP-2, BACKUP-4), one upward with a caveat (BACKUP-5); the rest stand.

| ID | Verdict | Reported | Corrected | Repro |
| --- | --- | --- | --- | --- |
| BACKUP-1 | CONFIRMED | P1 | P1 | `repro_backup_1` |
| BACKUP-2 | CONFIRMED | P2 | **P1** | `repro_backup_2` |
| BACKUP-3 | CONFIRMED | P2 | P2 | `repro_backup_3` |
| BACKUP-4 | CONFIRMED | P2 | **P1** | `repro_backup_4` |
| BACKUP-5 | CONFIRMED | P2 | **P1** | `repro_backup_5` |
| BACKUP-6 | CONFIRMED | P2 | P2 | `repro_backup_6` |
| BACKUP-7 | CONFIRMED | P2 | P2 | `repro_backup_7` |

Contract sentences verified to exist as quoted:

- `persistence.ads:219-224` History: "Read a timeline history file exactly as
  sent to a standby."
- `persistence.ads:225-231` Promote: "Atomically allocate and persist a
  timeline whose history records Parent and Fork_LSN before it becomes
  current."
- `persistence.ads:175-178` Oldest_Restart_LSN: "Compute the retention floor
  across all non-invalidated slots. @return Oldest restart LSN, or zero when
  no slot retains WAL."
- `persistence.ads:199-206` Append: "@param Start Current_LSN, or the base
  position of an empty store."
- `persistence.ads:72-75` Generation: "@return Nonzero generation for an
  acquired slot, otherwise zero."
- `persistence.ads:93-102` Create: "@param State Initial state created by
  Make_Slot."
- `persistence.ads:281-286` Put: "Durably insert or replace prepared state
  identified by slot and GID."
- `memory.ads:29` "@exception Store_Error State is invalid or capacity is
  exhausted"; `memory.ads:121` "@exception Store_Error A nonempty append is
  not contiguous"; `memory.ads:144` "Persist a PostgreSQL-format history line
  and advance the timeline."
- `prepared_consumer.ads:3-5` "an applied marker prevents replay after target
  application has been recorded"; `:71-72` "Retaining the marker until then
  bounds replay."
- `README.md:358-364` Persistence paragraph; `:367-372` Managed_Primary /
  Prepared_Consumer paragraph.

Scope note: `Persistence.Memory` is the only implementation of
`Timeline_Store` and `WAL_Store` in the tree.
`tests/src/replication_test_durable_store.adb` (the "crash-durable external
test backend") journals each call and then delegates to an inner
`Memory.Store` (`:735-745` Promote, `:747-763` Put, etc.), so every
Memory-level finding below propagates to it unchanged. No finding is
"handled elsewhere".

---

### BACKUP-1: `Memory.Promote` stores only the newest history line, so `History` for the third and later timelines is not a PostgreSQL history file

**Verdict:** CONFIRMED.

`memory.adb:255-283` writes exactly one `<parent>\t<fork>\tpromotion\n` line
into a fresh `History_Entry` and never reads the parent's entry.
`memory.adb:244-253` returns those bytes verbatim, and
`managed_primary.adb:332-337` (`Timeline_History_Command`) passes them
straight into `Replication_Sessions.Send_Timeline_History`, whose
`History_Text` (`server_sessions.adb:35-44`) only widens bytes to characters
- no reformatting anywhere on the path.

The PostgreSQL claim checks out in all five cached majors: 14.23, 15.18,
16.14, 17.10 and 18.4 all contain `timeline.c:332` "If a history file exists
for the parent, copy it verbatim", followed by the append of
`"%s%u\t%X/%X\t%s\n"` with a leading `\n` when the parent file existed. So a
real `00000003.history` contains both ancestor lines (separated by a blank
line), and `xlogrecovery.c:4188` logs "new timeline %u is not a child of
database system timeline %u" and refuses the switch when the standby's
current timeline is absent from that ancestry.

The repro asserts containment of the inherited line rather than exact bytes,
because PostgreSQL's extra separator `\n` makes a byte-exact expectation
brittle; the ancestry requirement is the load-bearing part.

**Severity:** P1 (unchanged). A documented contract - "a timeline history file
exactly as sent to a standby" - is violated on a reachable path (two
promotions), and the composition with `Managed_Primary` plus a real standby is
an interop failure rather than a cosmetic one. It stops short of P0 only
because it needs two promotions, which no current test or CI shard performs
(the PostgreSQL 18 shard exercises a single 1 -> 2 switch, which one line
happens to satisfy).

**Repro:** `tests/repros/src/repro_backup_1.adb`

**Output** (`./run.sh repro_backup_1`, exit status 1):

```
  ok: two promotions allocate timelines 2 and 3 (harness sanity check)
  -- 00000002.history = "1\t0/64\tpromotion\n"
  -- 00000003.history = "2\t0/C8\tpromotion\n"
  -- PostgreSQL would store, for 00000003.history, the whole parent file "1\t0/64\tpromotion\n" followed by "2\t0/C8\tpromotion\n"
  ok: the history of timeline 2 is its single switch line (harness sanity check)
  ok: the history of timeline 3 records its own switch point from timeline 2
  FAILED: the history of timeline 3 also records the inherited timeline-1 switch line, so a standby still on timeline 1 finds itself in the ancestry of timeline 3
BUG REPRODUCED: 1 failed expectation(s)
```

**Description:** `Flyology.Postgres.Replication.Persistence.Memory.Promote`
(`src/flyology-postgres-replication-persistence-memory.adb:255-283`) stores a
single `<parentTLI>\t<switchpoint>\tpromotion\n` line as the whole history of
the new timeline, discarding the parent timeline's own history. PostgreSQL's
`writeTimeLineHistory` copies the parent history file verbatim before
appending that line, so a genuine `0000000N.history` enumerates every
ancestor, and `readTimeLineHistory` / `rescanLatestTimeLine` rely on that
ancestry. `Persistence.History` is documented as "a timeline history file
exactly as sent to a standby" and `Managed_Primary` forwards those bytes
unchanged over `TIMELINE_HISTORY`. After a second promotion (1 -> 2 -> 3), the
file for timeline 3 no longer mentions timeline 1, so a standby still on
timeline 1 logs "new timeline 3 is not a child of database system timeline 1"
and cannot follow the primary; any consumer walking the chain to find
timeline 1's switch point also gets a wrong answer.

---

### BACKUP-2: `Memory.Oldest_Restart_LSN` is order-dependent when a live slot has `Restart = 0`

**Verdict:** CONFIRMED, and stronger than reported: the wrong value is not
merely order-dependent, it is a retention floor *above* a live slot's restart
LSN, and feeding it through the same operations `Apply_Retention` performs
destroys WAL that slot still needs.

`memory.adb:163-175` overloads `Result = 0` as both "nothing seen yet" and a
real value. A zero restart LSN is reachable without any contrivance:
`managed_primary.adb:339-359` creates a logical slot with
`Restart_LSN => Position` where `Position := Stores.Current_LSN (Item.WAL.all)`,
which is `WAL_Base + 0 = 0` on a fresh Memory store; `Make_Slot`
(`persistence.adb:9-32`) accepts `Restart_LSN => 0` without complaint.

**Severity:** corrected from P2 to **P1**. This is a wrong result on ordinary
input via a reachable path, and its consequence is the P0 example in the
rubric - a WAL retention floor computed too high, so retained WAL a live slot
needs is discarded (third check in the repro: `First_LSN` moves to 50 and
`Read (0, 10)` then raises `Store_Error`). I stop at P1 rather than P0 because
the defect is confined to the reference `Memory` store (and the test store
that wraps it), not to a durability path an application ships; a reviewer
applying the P0 "WAL retention floor too high" example literally could
justifiably rate it P0.

**Repro:** `tests/repros/src/repro_backup_2.adb`

**Output** (`./run.sh repro_backup_2`, exit status 1):

```
  -- slots created as (fresh=0, later=50): Oldest_Restart_LSN = 50
  -- slots created as (later=50, fresh=0): Oldest_Restart_LSN = 0
  FAILED: the retention floor of one set of slots does not depend on the order they were created in
  FAILED: the retention floor never exceeds the restart LSN of a live slot (a slot restarting at 0 still needs WAL from 0)
  -- after Apply_Retention with a live slot restarting at 0, First_LSN = 50
  -- Read (0, 10) raised Store_Error: the WAL slot "fresh" restarts from is gone
  FAILED: WAL that the slot restarting at 0 still needs survives retention
BUG REPRODUCED: 3 failed expectation(s)
```

**Description:**
`Flyology.Postgres.Replication.Persistence.Memory.Oldest_Restart_LSN`
(`src/flyology-postgres-replication-persistence-memory.adb:163-175`) uses
`Result = 0` as its "no candidate yet" sentinel while zero is also a valid
restart LSN, so the minimum it computes depends on which array index each slot
occupies. With slots at restart 0 and 50 it returns 50 in one creation order
and 0 in the other. `Managed_Primary.Apply_Retention`
(`src/flyology-postgres-replication-managed_primary.adb:104-114`) feeds that
value directly into `Retain_From`, so in the first order it discards every WAL
byte below 50 while a live slot still restarts from 0 - the WAL that slot
needs is gone and a later `Read` for it raises `Store_Error`. A slot at
restart 0 is not contrived: `Managed_Primary`'s `CREATE_REPLICATION_SLOT`
handler creates logical slots at `Current_LSN`, which is zero on a fresh
Memory store. The interface documents this function as "the retention floor
across all non-invalidated slots", so it must be the true minimum and must not
depend on iteration order. The conformance fixture
(`tests/src/replication_persistence_conformance.adb:123`) checks a single
nonzero value and cannot catch it.

---

### BACKUP-3: `Memory.Append` on a fully retained-away store rewinds `Current_LSN` and reuses WAL positions

**Verdict:** CONFIRMED as described. The behaviour is exactly as claimed:
`Retain_From (Oldest = Current_LSN)` (`memory.adb:219-239`) sets
`WAL_Data := Empty` and `WAL_Base := Oldest`, and `Append` (`memory.adb:206-217`)
decides contiguity solely from `To_Array (Item.WAL_Data)'Length = 0`, so it
rebases to any `Start` at all.

Refutation attempt, recorded honestly: the `Append` contract does say
"@param Start Current_LSN, or the base position of an empty store", and a
fully drained store *is* byte-empty, so `Memory` can be read as doing what its
own documentation permits. What the documentation does not permit is the
observable effect: `First_LSN` and `Current_LSN` both regress (106 -> 50/54)
even though `Retain_From` is documented only to "discard bytes before Oldest"
and `Append` only to append. Positions already handed to a standby become
reusable for different bytes, and a subsequent `Apply_Retention` with a slot
at 103 raises "slot retention floor exceeds available WAL" far from the cause.

**Severity:** P2 (unchanged). Reaching it requires the caller to pass a `Start`
that is not the store's end position, i.e. unusual input; no library code path
does this, and the exact-contract wording is ambiguous. Whichever way it is
resolved, `Memory` should either keep the drained end position (raise
`Store_Error`) or the `Append` contract should say that a drained store may be
rebased - it should not be left to the size of an internal buffer.

**Repro:** `tests/repros/src/repro_backup_3.adb`

**Output** (`./run.sh repro_backup_3`, exit status 1):

```
  ok: the store spans 100 .. 106 after the first append (harness sanity check)
  ok: the drained store still reports its real end position 106 (harness sanity check)
  -- Append (Start => 50) on the drained store was accepted
  -- after the rewinding append: First_LSN = 50, Current_LSN = 54
  FAILED: an append below the end position of a fully drained store is rejected as non-contiguous
  FAILED: Current_LSN never moves backwards, so WAL positions already handed to a standby are not reused for different bytes
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:** `Memory.Append`
(`src/flyology-postgres-replication-persistence-memory.adb:206-217`) treats a
store whose retained bytes were all trimmed by `Retain_From` as a brand-new
empty store and silently rebases `WAL_Base` to whatever `Start` the caller
passes. `Retain_From (Oldest = Current_LSN)` - exactly what
`Managed_Primary.Apply_Retention` performs once the only slot's restart LSN
has caught up with the end of WAL - produces such a store while
`First_LSN = Current_LSN` is still a real, already-streamed position. After
`Append (100, 6 bytes)`, `Retain_From (106)`, `Append (50, 4 bytes)`, the store
reports `First_LSN = 50` and `Current_LSN = 54`: the end position has moved
backwards by 52 bytes and positions 50..53 now hold bytes different from
whatever a standby was already sent for that range. No `Store_Error` is
raised, so the mistake surfaces only later, as a misleading "slot retention
floor exceeds available WAL" from `Apply_Retention`.

---

### BACKUP-4: `Persistence.Generation` keeps returning the stale nonzero lease after `Release`

**Verdict:** CONFIRMED.

`Memory.Release` (`memory.adb:147-161`) clears `State.Active` and leaves
`State.Lease` intact; `Persistence.Generation` (`persistence.adb:43`) returns
that field unconditionally. The accessor's documented contract
(`persistence.ads:72-75`) is "Nonzero generation for an acquired slot,
otherwise zero", so a released slot must report zero. Nothing else in the
library clears the field, and no library code consumes `Generation` (grep over
`src/` finds only the accessor's own declaration and body), so this is a
contract that only application code can observe - and application code is
exactly who the accessor is documented for.

**Severity:** corrected from P2 to **P1**. The rubric puts "a documented
contract violated" at P1, and this needs no unusual input at all: the plain
`Acquire` -> `Release` -> `Load` lifecycle is enough. It sits at the low end of
P1 because `Is_Active` on the same snapshot still gives the right answer, so
the fix may equally be to correct the accessor's documentation and state that
`Generation` is a retained fencing epoch - but code and doc cannot both stand
as they are.

**Repro:** `tests/repros/src/repro_backup_4.adb`

**Output** (`./run.sh repro_backup_4`, exit status 1):

```
  ok: slot creation (harness check)
  ok: a never-acquired slot reports generation zero (harness sanity check)
  ok: slot acquisition issues a nonzero lease (harness check)
  ok: an acquired slot reports its lease (harness sanity check)
  ok: the matching lease is released (harness check)
  -- after Release: Is_Active = FALSE, Generation = 1
  ok: the released slot is no longer active (harness sanity check)
  FAILED: a released slot reports generation zero, as the accessor's contract requires (nonzero only for an acquired slot)
BUG REPRODUCED: 1 failed expectation(s)
```

**Description:**
`Flyology.Postgres.Replication.Persistence.Generation`
(`src/flyology-postgres-replication-persistence.adb:43`) is documented to
return "Nonzero generation for an acquired slot, otherwise zero", but
`Memory.Release`
(`src/flyology-postgres-replication-persistence-memory.adb:147-161`) only
clears the `Active` flag and leaves the `Lease` field set. After the ordinary
`Acquire` / `Release` cycle, `Load` returns a snapshot reporting
`Is_Active = False` together with `Generation = 1`. Application code that
follows the accessor's documentation and uses `Generation (State) /= 0` as its
"this slot is currently leased" test therefore sees a free slot as held, for
the entire remaining life of the slot. The persistence conformance fixture
(`tests/src/replication_persistence_conformance.adb`) never asserts
`Generation` after a release, so the reference behaviour it pins is the wrong
one.

---

### BACKUP-5: `Prepared_Consumer.Prepare` overwrites a `Target_Applied` marker for the same GID, defeating the replay guard and breaking GID reuse

**Verdict:** CONFIRMED, both scenarios, on the first attempt.

`Prepared_Consumer.Prepare` (`prepared_consumer.adb:7-20`) calls `Stores.Put`
unconditionally, and `Put` is documented (`persistence.ads:281-286`) and
implemented (`memory.adb:299-326`) to replace an existing `(slot, GID)` entry.
So the defect is in the consumer, not in the store: `Put` behaves per contract,
`Prepare` is the layer that promised the marker survives.

Refutation attempt: the package header does require `Apply_Target` to be
idempotent for `(Slot_Name, GID, XID)`, which bounds the damage in scenario 1
to a redundant apply. But the header's own words are unconditional - "an
applied marker prevents replay after target application has been recorded" -
and `Acknowledge_Commit`'s "Retaining the marker until then bounds replay"
describes exactly the window scenario 1 exploits. Scenario 2 is not covered by
the idempotence requirement at all, because the XID differs: the repro shows
`Acknowledge_Commit` for the first transaction raising `Protocol_Error`
("prepared commit acknowledgement precedes target application") once the
source has reused the GID for a second transaction, which PostgreSQL permits
as soon as the first prepared transaction has committed.

**Severity:** corrected from P2 to **P1**. Scenario 2 is an unexpected
exception on valid input via a reachable path (the API explicitly directs the
application to defer `Acknowledge_Commit` until the source commit LSN is
itself durably acknowledged, which is what opens the window), and scenario 1 is
a documented contract violated outright. The report's P2 is defensible if one
weights only the same-XID crash-replay case, where documented idempotence
absorbs the extra apply.

**Repro:** `tests/repros/src/repro_backup_5.adb`

**Output** (`./run.sh repro_backup_5`, exit status 1):

```
  -- --- scenario 1: PREPARE replayed after target application ---
  -- Apply_Target invoked for GID "gid-replay", XID = 1 (application # 1 )
  ok: the first commit applies the prepared transaction once (harness sanity check)
  -- Apply_Target invoked for GID "gid-replay", XID = 1 (application # 2 )
  -- after the replayed PREPARE and COMMIT PREPARED: Applied_Now = TRUE, Apply_Target calls = 2
  FAILED: the durable applied marker prevents replay: a repeated PREPARE and COMMIT PREPARED for the same GID does not re-apply the target
  -- --- scenario 2: the source reuses the GID before acknowledgement ---
  -- Apply_Target invoked for GID "gid-shared", XID = 11 (application # 1 )
  ok: the first transaction is applied (harness sanity check)
  -- Acknowledge_Commit for transaction 11 raised Protocol_Error: prepared commit acknowledgement precedes target application
  FAILED: acknowledging the commit LSN of the first transaction still finds the applied state the consumer recorded for it
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:**
`Flyology.Postgres.Replication.Prepared_Consumer.Prepare`
(`src/flyology-postgres-replication-prepared_consumer.adb:7-20`) persists the
incoming payload with an unconditional `Stores.Put`, which is documented to
"insert or replace" state for `(slot, GID)`. A second PREPARE for a GID whose
transaction has already reached `Target_Applied` therefore demotes the durable
phase back to `Prepared` and destroys the replay guard the package header
promises ("an applied marker prevents replay after target application has been
recorded"). Two reachable consequences follow. First, a consumer that applied
and marked a transaction but failed before its feedback confirmed the commit
LSN receives the same PREPARE again when PostgreSQL re-decodes from the
confirmed flush position, and `Commit` reports `Applied_Now = True` and invokes
`Apply_Target` a second time. Second, PostgreSQL permits a GID to be reused
once the earlier prepared transaction has committed; when the source prepares a
new transaction under that GID before the consumer has acknowledged the earlier
commit LSN, the earlier transaction's `Target_Applied` record is replaced and
the pending `Acknowledge_Commit` raises `Protocol_Error` instead of removing
the state it recorded. `Prepare` must not clear an existing applied marker for
the same `(slot, GID)`.

---

### BACKUP-6: `Memory.Create` accepts an active/leased or invalidated snapshot as initial state, creating a slot nobody can acquire or drop

**Verdict:** CONFIRMED.

`memory.adb:36-57` validates only `Name'Length = 0 or else not State.Present`
and then copies the entire `Slot_State` record, `Active`, `Lease` and `Invalid`
included. The `Store_Error` documented at `memory.ads:29` for an invalid state
is never raised for these cases. The stranded-slot consequence is real and the
repro shows all three symptoms: `Acquire` returns `Already_Active` with
`Lease = 0`, `Drop` returns `False`, and `Oldest_Restart_LSN` keeps counting the
slot's restart LSN toward the retention floor.

**Severity:** P2 (unchanged). The parameter is documented as "Initial state
created by Make_Slot"; producing an active snapshot requires passing a
`Load` result instead, which is out-of-contract input. The report's own
framing ("needs unusual input") is accurate. It is worth fixing because the
failure mode - a slot that can be neither acquired nor dropped and that pins
the WAL retention floor forever - has no recovery path short of discarding the
store, and because `Create` already performs a partial validation, so the check
is one clause wider.

**Repro:** `tests/repros/src/repro_backup_6.adb`

**Output** (`./run.sh repro_backup_6`, exit status 1):

```
  ok: the source store holds an active lease (harness sanity check)
  -- Create with an active, leased snapshot returned CREATED
  FAILED: Create rejects a snapshot that is not an inactive, unleased initial state, as its documented Store_Error requires
  -- Acquire on the copied slot returned ALREADY_ACTIVE, lease = 0
  -- Drop on the copied slot returned FALSE
  -- the copied slot still pins the retention floor at 10
  FAILED: a stored slot can always be either acquired or dropped, so it cannot be stranded active with a lease no owner of this store holds
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:** `Memory.Create`
(`src/flyology-postgres-replication-persistence-memory.adb:36-57`) checks only
that the supplied `Slot_State` has `Present` set before storing it whole, so
the `Active`, `Lease` and `Invalid` fields of a `Load`-ed snapshot are copied
into the new slot. Seeding one store from another store's snapshot - the
obvious use for `Load` returning a value the same package's `Create` accepts -
therefore produces a slot that is permanently active under a lease no owner of
the receiving store holds: `Acquire` returns `Already_Active` with a zero lease
forever, `Drop` refuses because the slot is active, and `Oldest_Restart_LSN`
keeps the slot's restart LSN as the WAL retention floor. The `Store_Error` that
`memory.ads:29` documents for an invalid state is never raised. `Create` should
reject any snapshot that is not an inactive, unleased, valid initial state.

---

### BACKUP-7: `Server_Sessions.Send_Position` declares `tli` as int4 where PostgreSQL sends int8

**Verdict:** CONFIRMED, and the PostgreSQL claim was checked in every cached
major rather than from memory.

- 14.23 `src/backend/replication/basebackup.c:1047` `SendXlogRecPtrResult`
  sends `INT8OID` for `tli`, with the comment "int8 may seem like a surprising
  data type for this, but in theory int4 would not be wide enough for this, as
  TimeLineID is unsigned."
- 15.18 `src/backend/backup/basebackup_copy.c:337` is byte-identical in that
  respect.
- 16.14, 17.10 and 18.4 `basebackup_copy.c:358` build the same column via
  `TupleDescInitBuiltinEntry (tupdesc, 2, "tli", INT8OID, -1, 0)`.

`src/flyology-postgres-replication-base_backups-server_sessions.adb:23-46`
declares `Type_Oid => 23, Type_Size => 4`, and both `Send_Start_Position`
(`:45-52`) and `Send_End_Position` (`:179-188`) route through it, so both
result sets are affected.

**Severity:** P2, low impact (unchanged). The value is sent in text format and
is correct, so this library's own `Base_Backups.Receiver` and `pg_basebackup`
- which read the column as text and never inspect the type OID - are
unaffected. A typed client reading the descriptor sees a different row shape
from the PostgreSQL server the package stands in for, and would mis-decode
timelines above 2^31-1. Not interop-breaking, so not P0.

Two adjacent observations found while checking this, offered for the fixer
rather than as separate findings:

1. `src/flyology-postgres-replication-server_sessions.adb:62` declares the
   `IDENTIFY_SYSTEM` `timeline` column as `Type_Oid => 23, Type_Size => 4`
   unconditionally. `walsender.c` `IdentifySystem` uses `INT4OID` in 14.23 and
   15.18 but `INT8OID` in 16.14, 17.10 and 18.4 - so that column is right for
   two majors and wrong for three, and correcting it needs the server major,
   which `Send_Identify_System` does not currently take.
2. PostgreSQL's `SendXlogRecPtrResult` ends with
   `pq_puttextmessage ('C', "SELECT")`, where the library sends `"SELECT 1"`
   (`server_sessions.adb:42`). Cosmetic, as the discovery report says.

**Repro:** `tests/repros/src/repro_backup_7.adb`

**Output** (`./run.sh repro_backup_7`, exit status 1):

```
  ok: the start-position result set opens with a RowDescription (harness sanity check)
  ok: the result set has the two PostgreSQL columns recptr and tli (harness sanity check)
  -- column 2 is "tli" with type OID 23 and width 4
  -- PostgreSQL 14 through 18 send type OID 20 (int8)
  ok: column 2 is named tli (harness sanity check)
  FAILED: the tli column is advertised as int8 (OID 20), the type every supported PostgreSQL major sends for it
BUG REPRODUCED: 1 failed expectation(s)
```

**Description:**
`Flyology.Postgres.Replication.Base_Backups.Server_Sessions.Send_Position`
(`src/flyology-postgres-replication-base_backups-server_sessions.adb:23-46`)
advertises the base backup start- and end-position result set's `tli` column
as `int4` (type OID 23, width 4). PostgreSQL 14 through 18 all declare it as
`int8` (OID 20), deliberately and with an explanatory comment, because
`TimeLineID` is unsigned and would not fit in int4. Both
`Send_Start_Position` and `Send_End_Position` go through this one procedure, so
a server or proxy built on this package advertises a row shape that differs
from the server it stands in for. The transmitted value is text and remains
correct, so this library's own `Base_Backups.Receiver` and `pg_basebackup` are
unaffected; a client that decodes by declared type would mis-handle timelines
above 2^31-1.

---

## Method notes

- No file under `src/`, `sql/`, `examples/`, `tests/src/` or any existing
  script was modified; `git status --short` shows only the untracked
  `tests/repros/` tree (plus other agents' untracked repro directories) and
  the pre-existing `sql/tests/config/` modifications from the session start.
- Every repro asserts the correct behaviour and currently exits 1 with
  "BUG REPRODUCED"; a fixed library would print PASS and exit 0.
- PostgreSQL behaviour was read from
  `tests/.cache/postgres/{14.23,15.18,16.14,17.10,18.4}-openssl/source`
  (`basebackup.c`, `basebackup_copy.c`, `walsender.c`, `timeline.c`,
  `xlogrecovery.c`), never from memory.
