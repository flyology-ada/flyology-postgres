Title: Memory.Append rebases a fully retained-away store, moving Current_LSN backwards and reusing WAL positions
Labels: bug
Refs: none

## Summary

`Persistence.Memory.Append` decides contiguity from the length of the retained byte buffer alone, so a store whose bytes were all trimmed by `Retain_From` is treated as a brand-new empty store and silently rebased to whatever `Start` the caller passes. `Retain_From (Current_LSN)` is exactly what `Managed_Primary.Apply_Retention` performs once the only slot has caught up with the end of WAL, and it leaves a store whose `First_LSN` and `Current_LSN` are a real, already-streamed position. A following append below that position is accepted, both positions regress, and WAL offsets already handed to a standby come to hold different bytes.

## Problem

Commit `6f496f5`.

`Persistence.Memory` is the generic bounded volatile reference implementation of `WAL_Store` (`README.md:362-364`), and the only implementation in the tree; the test store used by the durable-backend suite delegates both operations to it (`tests/src/replication_test_durable_store.adb:702-717`):

```ada
Persist (Item, "W " & Image_LSN (Start) & " " & Encode (Data));
Memory.Append (Item.Inner, Start, Data);
```

`Append` consults only the buffer length (`src/flyology-postgres-replication-persistence-memory.adb:206-217`):

```ada
overriding procedure Append
  (Item  : in out Store;
   Start : LSN;
   Data  : Byte_Array) is
begin
   if Flyology.Bytes.To_Array (Item.WAL_Data)'Length = 0 then
      Item.WAL_Base := Start;
   elsif Start /= Current_LSN (Item) then
      raise Store_Error with "WAL append is not contiguous";
   end if;
   Flyology.Postgres.Protocol.Append_Bytes (Item.WAL_Data, Data);
end Append;
```

`Retain_From` produces exactly that state when the floor reaches the end position (`src/flyology-postgres-replication-persistence-memory.adb:229-238`):

```ada
Drop_Count := Oldest - Item.WAL_Base;
if Drop_Count = LSN (Data'Length) then
   Item.WAL_Data := Flyology.Bytes.Empty;
else
   ...
end if;
Item.WAL_Base := Oldest;
```

`First_LSN` is `WAL_Base` and `Current_LSN` is `WAL_Base` plus the buffer length, so the drained store still reports the true end position while its buffer is empty.

That call is on the ordinary retention path (`src/flyology-postgres-replication-managed_primary.adb:104-114`): `Apply_Retention` passes `Oldest_Restart_LSN` to `Retain_From`, and once the only slot's restart LSN has advanced to the end of available WAL, the floor equals `Current_LSN`.

The contract is partly on the library's side here, and the report is explicit about it. The interface documents the parameter as (`src/flyology-postgres-replication-persistence.ads:199-206`):

```ada
procedure Append
  (Item  : in out WAL_Store;
   Start : LSN;
   Data  : Byte_Array) is abstract;
--  Durably append a contiguous WAL range.
--  @param Item Store to mutate.
--  @param Start Current_LSN, or the base position of an empty store.
--  @param Data Bytes to append in WAL order.
```

and the `Memory` child repeats it as "Current_LSN, or a new base for an empty store" (`src/flyology-postgres-replication-persistence-memory.ads:117-121`). A fully drained store is byte-empty, so `Memory` can be read as doing what its own documentation permits, and that wording is the defence for the current behaviour.

What no wording permits is the observable effect. `Retain_From` is documented only to "discard bytes before Oldest while preserving the retained suffix" (`persistence.ads:207-211`) and `Append` only to append, yet the pair together moves both `First_LSN` and `Current_LSN` backwards. `Read` is documented to return "up to Maximum bytes, empty only when Start equals Current_LSN" (`persistence.ads:190-198`), a promise about positions that cannot hold once a position can be issued twice for different bytes. The `Store_Error` documented as "A nonempty append is not contiguous" (`persistence-memory.ads:121`) never fires.

No test drains a store completely. The conformance fixture appends at 100, retains from 103, and stops with three bytes still in the buffer (`tests/src/replication_persistence_conformance.adb:126-138`), so the empty-buffer branch of `Append` is never reached after a `Retain_From`.

## What happens now

Spike: six bytes are appended at position 100, the store is drained with `Retain_From (106)` exactly as `Apply_Retention` would, and a four-byte append is then attempted at position 50. It asserts that the append is rejected and that `Current_LSN` does not move backwards.

```ada
Memory.Append (Store, 100, (1, 2, 3, 4, 5, 6));
End_Before := Memory.Current_LSN (Store);
Memory.Retain_From (Store, 106);
begin
   Memory.Append (Store, 50, (9, 9, 9, 9));
   Note ("Append (Start => 50) on the drained store was accepted");
exception
   when Persistence.Store_Error =>
      Rejected := True;
      ...
end;
Check (Rejected, ...);
Check (Memory.Current_LSN (Store) >= End_Before, ...);
```

Output:

```
  ok: the store spans 100 .. 106 after the first append (harness sanity check)
  ok: the drained store still reports its real end position 106 (harness sanity check)
  -- Append (Start => 50) on the drained store was accepted
  -- after the rewinding append: First_LSN = 50, Current_LSN = 54
  FAILED: an append below the end position of a fully drained store is rejected as non-contiguous
  FAILED: Current_LSN never moves backwards, so WAL positions already handed to a standby are not reused for different bytes
BUG REPRODUCED: 2 failed expectation(s)
```

The end position moves back by 52 bytes, and positions 50 through 53 now hold bytes different from whatever a standby was already sent for that range. No exception is raised, so the mistake surfaces later, as a misleading "slot retention floor exceeds available WAL" from `Apply_Retention` when a slot sitting at 103 is next consulted.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A store that has issued WAL positions keeps its end position when its bytes are trimmed away. An append below that end position is rejected with `Store_Error` ("WAL append is not contiguous", `persistence-memory.ads:121`), and in no case may `Current_LSN` regress or a position already issued be reused for different bytes.

## Suggested treatment

This needs a maintainer decision, because the two sides of the contradiction are code and documentation and either can move:

- Make `Append` distinguish "never used" from "drained": keep a flag or compare `Start` against `Current_LSN` whenever the store has ever been appended to, and rebase only a store that has issued no position. This keeps `Retain_From` and `Append` composable and makes the drained case raise the documented `Store_Error`.
- Or re-document `Append` in `persistence.ads:199-206` and `persistence-memory.ads:117-121` to say that a store with no retained bytes may be rebased to any `Start`, and say in `Retain_From`'s own comment that draining a store to its end position forfeits its position history. Callers then have to avoid the sequence themselves.

The behaviour should not be left to depend on the size of an internal buffer either way. The regression test belongs in `tests/src/replication_persistence_conformance.adb` next to the existing append and retention checks at :126-138, extended with a full drain; the spike is that test. No existing assertion asserts the current behaviour, so none has to change.

## Severity

`Current_LSN` regresses and WAL positions already streamed to a standby are reused for different bytes, with no exception at the point of the mistake. Reaching it requires the caller to pass a `Start` that is not the store's end position after a full drain, which is unusual input and which no library code path currently produces, and the exact wording of the `Append` contract is ambiguous about whether a drained store counts as empty. Deterministic.
