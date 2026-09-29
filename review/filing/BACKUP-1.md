Title: Memory.Promote drops the parent history, so a third timeline's history file omits every earlier ancestor
Labels: bug
Refs: none

## Summary

`Persistence.Memory.Promote` writes a single `<parentTLI>\t<switchpoint>\tpromotion\n` line as the entire history of the new timeline and never reads the parent's history entry. PostgreSQL copies the parent history file verbatim before appending that line, so a genuine `0000000N.history` enumerates every ancestor. After a second promotion the history this library serves for timeline 3 no longer mentions timeline 1, so a standby still on timeline 1 does not find itself in the ancestry and refuses to follow the primary.

## Problem

Commit `6f496f5`.

`Persistence.Memory` is the generic bounded volatile reference implementation of `Timeline_Store` (`README.md:362-364`), and it is the only implementation of that interface in the tree. `Promote` composes the new history entry from the parent identifier and the fork position alone (`src/flyology-postgres-replication-persistence-memory.adb:277-281`):

```ada
Item.Histories (Index) :=
  (Timeline => New_Timeline,
   Data     => Flyology.Bytes.From_Byte_String
     (Parent_Image & Character'Val (9) & Replication.Image (Fork_LSN)
      & Character'Val (9) & "promotion" & Character'Val (10)));
```

Nothing in that procedure looks up `Item.Histories` for the parent timeline. The test store used by the durable-backend suite delegates `Promote` straight to this body (`tests/src/replication_test_durable_store.adb:735-745`):

```ada
Memory.Promote (Item.Inner, Parent, Fork_LSN, New_Timeline);
```

Those bytes are what a standby receives. `History` returns them verbatim (`src/flyology-postgres-replication-persistence-memory.adb:244-253`), `Managed_Primary` passes them straight to the wire (`src/flyology-postgres-replication-managed_primary.adb:332-337`):

```ada
when Timeline_History_Command =>
   Replication_Sessions.Send_Timeline_History
     (Client, Replication.Timeline (Command),
      Stores.History
        (Item.Timelines.all, Replication.Timeline (Command)),
      Timeout => Item.Operation_Timeout);
```

and `History_Text` only widens octets to characters (`src/flyology-postgres-replication-server_sessions.adb:36-45`). There is no reformatting anywhere on the path.

The contract being violated is on the interface (`src/flyology-postgres-replication-persistence.ads:219-224`):

```ada
function History
  (Item : Timeline_Store; Timeline : UInt32) return Byte_Array is abstract;
--  Read a timeline history file exactly as sent to a standby.
```

`Promote` is documented on the same interface as persisting "a timeline whose history records Parent and Fork_LSN before it becomes current" (`src/flyology-postgres-replication-persistence.ads:225-231`), and the `Memory` child documents it as "Persist a PostgreSQL-format history line and advance the timeline" (`src/flyology-postgres-replication-persistence-memory.ads:144`).

PostgreSQL builds the file the other way round. `writeTimeLineHistory` (`tests/.cache/postgres/18.4-openssl/source/src/backend/access/transam/timeline.c:304`) copies the parent file before it appends anything (`timeline.c:331-337`):

```c
	/*
	 * If a history file exists for the parent, copy it verbatim
	 */
	if (ArchiveRecoveryRequested)
	{
		TLHistoryFileName(histfname, parentTLI);
		RestoreArchivedFile(path, histfname, "RECOVERYHISTORY", 0, false);
	}
```

and only then appends the switch line, inserting a separating newline when a parent file was present (`timeline.c:401-406`):

```c
	snprintf(buffer, sizeof(buffer),
			 "%s%u\t%X/%X\t%s\n",
			 (srcfd < 0) ? "" : "\n",
			 parentTLI,
			 LSN_FORMAT_ARGS(switchpoint),
			 reason);
```

That comment sits at line 332 and the `snprintf` at 401 in all five cached majors: 14.23, 15.18, 16.14, 17.10 and 18.4.

The ancestry is load-bearing on the standby. `rescanLatestTimeLine` reads the new timeline's history and walks it for its own timeline (`tests/.cache/postgres/18.4-openssl/source/src/backend/access/transam/xlogrecovery.c:4174-4192`):

```c
	found = false;
	foreach(cell, newExpectedTLEs)
	{
		currentTle = (TimeLineHistoryEntry *) lfirst(cell);

		if (currentTle->tli == recoveryTargetTLI)
		{
			found = true;
			break;
		}
	}
	if (!found)
	{
		ereport(LOG,
				(errmsg("new timeline %u is not a child of database system timeline %u",
						newtarget,
						replayTLI)));
		return false;
	}
```

The same rejection is at `xlogrecovery.c:4146` in 15.18, `:4116` in 16.14, `:4166` in 17.10, and in `src/backend/access/transam/xlog.c:4636` in 14.23, which has no `xlogrecovery.c`.

No test reaches a second promotion. The persistence conformance fixture promotes once and asserts only that the history is nonempty (`tests/src/replication_persistence_conformance.adb:140-145`):

```ada
Persistence.Promote (Timelines, 1, 105, Timeline);
Check
  (Timeline = 2
   and then Persistence.Current_Timeline (Timelines) = 2
   and then Persistence.History (Timelines, 2)'Length > 0,
   "timeline promotion and history persistence");
```

A single 1 to 2 switch is the one case a one-line history happens to satisfy, because timeline 2's ancestry is exactly its own switch line.

## What happens now

Spike: a fresh `Memory.Store` is promoted twice, from timeline 1 to 2 at fork `0/64` and from 2 to 3 at fork `0/C8`, and the stored history of each timeline is read back. It asserts that timeline 3's history contains the timeline-1 switch line inherited from its parent as well as its own. Containment rather than byte equality is asserted because PostgreSQL's extra separating newline would make an exact expectation brittle; the ancestry is the load-bearing part.

```ada
Line_1 : constant String :=
  "1" & HT & Replication.Image (Fork_1_2) & HT & "promotion" & LF;
Line_2 : constant String :=
  "2" & HT & Replication.Image (Fork_2_3) & HT & "promotion" & LF;

Memory.Promote (Store, Parent => 1, Fork_LSN => Fork_1_2,
                New_Timeline => Timeline_2);
Memory.Promote (Store, Parent => 2, Fork_LSN => Fork_2_3,
                New_Timeline => Timeline_3);

Check (Contains (Text (History_3), Line_2), ...);
Check (Contains (Text (History_3), Line_1), ...);
```

Output:

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

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 14.23, 15.18, 16.14, 17.10 and 18.4 server sources used for reference.

## What should happen

`Promote` should store the parent timeline's history followed by the new switch line, so that `History (N)` returns a file naming every ancestor of timeline N, which is what `persistence.ads:219-224` promises when it says the bytes are the history file "exactly as sent to a standby" and what `readTimeLineHistory` and `rescanLatestTimeLine` require.

## Suggested treatment

In `Promote`, read the current timeline's stored history before allocating the new entry and prefix it to the switch line, matching `writeTimeLineHistory`:

```ada
Parent_History : constant Byte_Array := History (Item, Parent);
...
Data => Flyology.Bytes.From_Byte_String
  (Text_Of (Parent_History)
   & (if Parent_History'Length = 0 then "" else "" & Character'Val (10))
   & Parent_Image & Character'Val (9) & Replication.Image (Fork_LSN)
   & Character'Val (9) & "promotion" & Character'Val (10));
```

Whether the separating newline PostgreSQL inserts is reproduced is a formatting detail a fixer can settle either way; the ancestry lines are the requirement. Note that the per-timeline entry then grows with the promotion count, so the `Capacity` formal now bounds total history bytes as well as entry count.

The regression test belongs in `tests/src/replication_persistence_conformance.adb` beside the existing single-promotion check at :140-145, extended to a second promotion; the spike is that test. No existing assertion has to change: the conformance check at :140-145 stays true, because timeline 2's correct history is still exactly its own switch line.

## Severity

A standby that has already followed one timeline switch cannot follow a second one: it reads a history file that does not name its own timeline, logs "new timeline 3 is not a child of database system timeline 1", and stops. Any consumer walking the chain for an earlier switch point also gets a wrong answer. It needs two promotions on one store, which no current test performs, and the affected store is the bounded reference implementation and the test store that wraps it. Deterministic; not reproduced against a live server.
