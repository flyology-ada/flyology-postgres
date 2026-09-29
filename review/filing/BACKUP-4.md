Title: Persistence.Generation keeps returning the stale nonzero lease after a slot is released
Labels: bug, documentation
Refs: none

## Summary

`Persistence.Generation` is documented to return a nonzero value for an acquired slot and zero otherwise, but `Persistence.Memory.Release` clears only the `Active` flag and leaves the `Lease` field set. After the plain acquire and release cycle, a snapshot reports `Is_Active = False` together with `Generation = 1`. Application code that follows the accessor's documentation and tests `Generation (State) /= 0` for "this slot is currently leased" sees a free slot as held, for the whole remaining life of the slot.

## Problem

Commit `6f496f5`.

The accessor's contract (`src/flyology-postgres-replication-persistence.ads:72-75`):

```ada
function Generation (Item : Slot_State) return UInt64;
--  Read the lease generation captured by a slot snapshot.
--  @param Item Slot snapshot to inspect.
--  @return Nonzero generation for an acquired slot, otherwise zero.
```

The body returns the stored field with no condition attached (`src/flyology-postgres-replication-persistence.adb:43`):

```ada
function Generation (Item : Slot_State) return UInt64 is (Item.Lease);
```

`Make_Slot` starts the field at zero (`src/flyology-postgres-replication-persistence.adb:23-31`) and `Acquire` sets it together with `Active` (`src/flyology-postgres-replication-persistence-memory.adb:104-105`), so the accessor is correct before and during a lease. Release is where the two fields diverge (`src/flyology-postgres-replication-persistence-memory.adb:147-161`):

```ada
overriding procedure Release
  (Item     : in out Store;
   Name     : String;
   Lease    : UInt64;
   Released : out Boolean) is
   Index : constant Natural := Slot_Index (Item, Name);
begin
   Released := Index /= 0
     and then Item.Slots (Index).State.Active
     and then Lease /= 0
     and then Item.Slots (Index).State.Lease = Lease;
   if Released then
      Item.Slots (Index).State.Active := False;
   end if;
end Release;
```

`Lease` is never cleared here, and nothing else in `src/` clears it. `Persistence.Memory` is the bounded volatile reference implementation of `Slot_Store` (`README.md:362-364`) and the only implementation in the tree; the test store used by the durable-backend suite delegates `Release` to this same body (`tests/src/replication_test_durable_store.adb:662-670`):

```ada
Persist (Item, "R " & Encode (Name) & " " & Image_U64 (Lease));
Memory.Release (Item.Inner, Name, Lease, Released);
```

No library code reads `Generation`. A search over `src/` finds only the declaration at `persistence.ads:72` and the body at `persistence.adb:43`, so the mismatch is observable only by application code, which is exactly the audience the accessor is documented for. `Is_Active` on the same snapshot (`persistence.ads:64-67`, `persistence.adb:40`) does report the truth, which is why nothing inside the library notices.

The conformance fixture releases and re-acquires but never loads a snapshot in between to inspect `Generation` (`tests/src/replication_persistence_conformance.adb:64-72`):

```ada
Persistence.Release
  (Slots, "conformance_physical", Lease_1, Changed);
Check (Changed, "matching lease release");
Persistence.Acquire
  (Slots, "conformance_physical", Persistence.Physical_Slot,
   Acquired, Lease_2, State);
Check
  (Acquired = Persistence.Acquired and then Lease_2 > Lease_1,
   "increasing lease generation");
```

`Generation` appears nowhere in that file, so the reference behaviour the fixture pins is silent on this point.

## What happens now

Spike: one slot is created, acquired, and released with the matching lease, and its snapshot is loaded again. It asserts the accessor's documented postcondition, that a released slot reports generation zero.

```ada
Memory.Acquire
  (Store, "primary", Persistence.Physical_Slot, Acquired, Lease, State);
Memory.Release (Store, "primary", Lease, Released);
State := Memory.Load (Store, "primary");
Check (not Persistence.Is_Active (State), ...);
Check (Persistence.Generation (State) = 0, ...);
```

Output:

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

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

Code and documentation must agree. Either `Generation` returns zero for a slot that is not currently acquired, as `persistence.ads:72-75` states, or the documented meaning of `Generation` changes to something a released slot can satisfy.

## Suggested treatment

This needs a maintainer decision, because the two options give `Generation` different meanings for application code:

- Clear the field on release, so the accessor's existing wording holds: add `Item.Slots (Index).State.Lease := 0;` beside the `Active := False` at `src/flyology-postgres-replication-persistence-memory.adb:159`. `Acquire` already draws the next value from `Item.Next_Generation` rather than from the slot (`persistence-memory.adb:101-107`), and `Advance` and `Release` already require `Active` before comparing the lease (`:122-128`, `:154-157`), so nothing in the store depends on the stale value surviving.
- Or re-document `Generation` in `persistence.ads:72-75` as a retained fencing epoch: the generation of the most recent lease, nonzero once the slot has ever been acquired, with `Is_Active` as the "currently leased" test. This preserves the ability to compare a held lease against the slot's last generation after a release.

The regression test belongs in `tests/src/replication_persistence_conformance.adb` beside the release check at :64-66, asserting whichever postcondition is chosen on a snapshot loaded after `Release`; the spike is that test in its first form. No existing assertion has to change, because no fixture asserts `Generation` today.

## Severity

A documented accessor returns a value its own contract forbids, and the trigger is the plain acquire, release, load lifecycle with no unusual input. An application using the documented test treats a free slot as permanently held and never re-acquires it. Nothing inside the library consumes `Generation`, and `Is_Active` on the same snapshot is correct, so an application that uses `Is_Active` is unaffected. Deterministic.
