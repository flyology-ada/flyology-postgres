Title: Memory.Create accepts an active leased snapshot as initial state, creating a slot nobody can acquire or drop
Labels: bug
Refs: none

## Summary

`Persistence.Memory.Create` validates only that the supplied `Slot_State` has its `Present` flag set, then stores the record whole, `Active`, `Lease` and `Invalid` included. Seeding one store from another store's `Load` result therefore produces a slot that is permanently active under a lease no owner of the receiving store holds. `Acquire` returns `Already_Active` with a zero lease forever, `Drop` refuses because the slot is active, and the slot keeps pinning the WAL retention floor. The `Store_Error` the child documents for an invalid state is never raised.

## Problem

Commit `6f496f5`.

`Create` checks one flag and copies the rest (`src/flyology-postgres-replication-persistence-memory.adb:36-57`):

```ada
if Name'Length = 0 or else not State.Present then
   raise Store_Error with "invalid replication slot creation";
end if;
...
Item.Slots (Index) :=
  (Name => To_Unbounded_String (Name), State => State);
Result := Created;
```

`Persistence.Memory` is the bounded volatile reference implementation of `Slot_Store` (`README.md:362-364`) and the only implementation in the tree; the test store used by the durable-backend suite delegates `Create` to this body after journalling (`tests/src/replication_test_durable_store.adb:595-602`):

```ada
Persist (Item, "C " & Encode (Name) & " " & Kind & " " ...);
Remember (Item, Name);
Memory.Create (Item.Inner, Name, State, Result);
```

The parameter is documented as a constructed initial state on the interface (`src/flyology-postgres-replication-persistence.ads:93-102`):

```ada
procedure Create
  (Item   : in out Slot_Store;
   Name   : String;
   State  : Slot_State;
   Result : out Create_Result) is abstract;
--  Create a named slot without replacing an existing slot.
--  @param Item Store to mutate.
--  @param Name Nonempty stable slot name.
--  @param State Initial state created by Make_Slot.
--  @param Result Whether the slot was created or already existed.
```

and the child documents the check that is missing (`src/flyology-postgres-replication-persistence-memory.ads:24-29`):

```ada
--  Create a slot according to Slot_Store.Create.
--  @param Item Memory store to mutate.
--  @param Name Nonempty slot name.
--  @param State Initial state created by Make_Slot.
--  @param Result Creation outcome.
--  @exception Store_Error State is invalid or capacity is exhausted.
```

`Make_Slot` always produces `Active => False`, `Invalid => False`, `Lease => 0` (`src/flyology-postgres-replication-persistence.adb:23-31`), so a `Make_Slot` result is always a valid initial state. A `Load` result is not, and `Load` returns the stored record unfiltered (`src/flyology-postgres-replication-persistence-memory.adb:59-64`), so the two values have the same type and only one of them is admissible.

Nothing recovers the resulting slot. `Acquire` short-circuits on `Active` before it can issue a lease (`src/flyology-postgres-replication-persistence-memory.adb:97-99`):

```ada
elsif Item.Slots (Index).State.Active then
   Result := Already_Active;
   State := Item.Slots (Index).State;
```

`Drop` refuses an active slot (`:66-76`):

```ada
Dropped := Index /= 0 and then not Item.Slots (Index).State.Active;
```

and `Release` requires a matching lease, which only the other store's owner has (`:154-157`). The slot's restart LSN keeps counting toward `Oldest_Restart_LSN` (`:163-175`) for the life of the store.

The conformance fixture only ever passes `Make_Slot` results to `Create` (`tests/src/replication_persistence_conformance.adb:28-33`, :99-104, :116-121), so the unvalidated fields are never populated in a test.

## What happens now

Spike: a slot is created and acquired in a source store, and the resulting snapshot is passed to `Create` on a second store. It asserts that `Create` rejects the snapshot, and, when it does not, that the stored slot can still be either acquired or dropped.

```ada
Memory.Acquire
  (Source, "held", Persistence.Physical_Slot, Acquired, Lease, State);
begin
   Memory.Create (Copy, "copied", State, Created);
   Note ("Create with an active, leased snapshot returned " & ...);
exception
   when Event : Persistence.Store_Error =>
      Rejected := True;
      ...
end;
Memory.Acquire
  (Copy, "copied", Persistence.Physical_Slot, Acquired, Lease, State);
Memory.Drop (Copy, "copied", Dropped);
Check (Acquired = Persistence.Acquired or else Dropped, ...);
```

Output:

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

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Create` should reject any `State` that is not an inactive, unleased, valid initial state, raising the `Store_Error` that `persistence-memory.ads:29` documents, so that every slot a store holds can be either acquired or dropped.

## Suggested treatment

Widen the existing guard by one clause, in the `Create` body at `src/flyology-postgres-replication-persistence-memory.adb:43-45`:

```ada
if Name'Length = 0 or else not State.Present
  or else State.Active or else State.Invalid or else State.Lease /= 0
then
   raise Store_Error with "invalid replication slot creation";
end if;
```

The check costs nothing at the call sites the library itself uses, which all pass `Make_Slot` results (`src/flyology-postgres-replication-managed_primary.adb:352-360`).

The regression test belongs in `tests/src/replication_persistence_conformance.adb` beside the existing creation checks at :28-33, asserting that `Create` raises `Store_Error` for an acquired snapshot; the spike is that test. No existing assertion has to change, because no fixture passes anything but a `Make_Slot` result.

## Severity

The slot can be neither acquired nor dropped and pins the WAL retention floor forever, with no recovery path short of discarding the store. It needs out-of-contract input: the parameter is documented as "Initial state created by Make_Slot", and producing an active snapshot means passing a `Load` result instead, which no library code path does. It is worth fixing because `Create` already performs a partial validation, so the correct check is one clause wider, and because the two values share a type so the mistake is easy for an application to make. Deterministic.
