Title: Memory.Oldest_Restart_LSN treats restart LSN zero as no candidate and discards WAL a live slot needs
Labels: bug
Refs: none

## Summary

`Persistence.Memory.Oldest_Restart_LSN` uses `Result = 0` as its "no candidate yet" sentinel while zero is also a valid restart LSN, so the minimum it returns depends on which array slot each replication slot occupies. With slots restarting at 0 and 50 it returns 50 in one creation order and 0 in the other. `Managed_Primary.Apply_Retention` feeds that value straight into `Retain_From`, so in the first order the store discards every WAL byte below 50 while a live slot still restarts from 0, and a later read for that slot raises `Store_Error`.

## Problem

Commit `6f496f5`.

`Persistence.Memory` is the generic bounded volatile reference implementation of `Slot_Store` and `WAL_Store` (`README.md:362-364`), and is the only implementation of either interface in the tree. The test store used by the durable-backend suite delegates the same computation to it (`tests/src/replication_test_durable_store.adb:672-677`):

```ada
overriding function Oldest_Restart_LSN
  (Item : Store) return Flyology.Postgres.Replication.LSN is
begin
   Require_Open (Item);
   return Memory.Oldest_Restart_LSN (Item.Inner);
end Oldest_Restart_LSN;
```

The sentinel and the value share one variable (`src/flyology-postgres-replication-persistence-memory.adb:163-175`):

```ada
overriding function Oldest_Restart_LSN (Item : Store) return LSN is
   Result : LSN := 0;
begin
   for Item_Entry of Item.Slots loop
      if Item_Entry.State.Present and then not Item_Entry.State.Invalid
        and then
          (Result = 0 or else Item_Entry.State.Restart < Result)
      then
         Result := Item_Entry.State.Restart;
      end if;
   end loop;
   return Result;
end Oldest_Restart_LSN;
```

A slot seen at restart 0 sets `Result` to 0, which the next iteration reads as "nothing seen yet" and overwrites with any later slot's restart LSN.

The contract requires the true minimum (`src/flyology-postgres-replication-persistence.ads:175-178`):

```ada
function Oldest_Restart_LSN (Item : Slot_Store) return LSN is abstract;
--  Compute the retention floor across all non-invalidated slots.
--  @param Item Store to query.
--  @return Oldest restart LSN, or zero when no slot retains WAL.
```

`README.md:360-362` restates it: slot mutations "expose the oldest restart LSN as the WAL retention floor".

A restart LSN of zero needs no contrivance. `Managed_Primary`'s `CREATE_REPLICATION_SLOT` handler creates a logical slot at the store's current end position (`src/flyology-postgres-replication-managed_primary.adb:339-360`):

```ada
when Create_Logical_Slot_Command =>
   declare
      Position : constant LSN := Stores.Current_LSN (Item.WAL.all);
      ...
      Stores.Create
        (Item.Slots.all,
         Replication.Slot_Name (Command),
         Stores.Make_Slot
           (Stores.Logical_Slot,
            Restart_LSN   => Position,
            Confirmed_LSN => Position,
            Plugin        => Replication.Plugin (Command)),
         Result);
```

On a fresh `Memory` store `Current_LSN` is `WAL_Base + 0`, which is zero, and `Make_Slot` accepts `Restart_LSN => 0` without complaint (`src/flyology-postgres-replication-persistence.adb:9-32`). So the first slot created on an empty managed primary restarts at zero.

The consequence is in the retention path (`src/flyology-postgres-replication-managed_primary.adb:104-114`):

```ada
procedure Apply_Retention (Item : in out Primary) is
   Floor : constant LSN :=
     Stores.Oldest_Restart_LSN (Item.Slots.all);
begin
   if Floor > Stores.First_LSN (Item.WAL.all) then
      Require
        (Floor <= Stores.Current_LSN (Item.WAL.all),
         "slot retention floor exceeds available WAL");
      Stores.Retain_From (Item.WAL.all, Floor);
   end if;
end Apply_Retention;
```

There is no second opinion between the wrong floor and the discard.

The conformance fixture creates its slots at 100, 108 and 110 and asserts a single nonzero result (`tests/src/replication_persistence_conformance.adb:122-124`):

```ada
Check
  (Persistence.Oldest_Restart_LSN (Slots) = 110,
   "oldest restart retention floor");
```

That value is above every other slot's restart LSN, so the assertion passes whichever branch runs, and no fixture creates a slot at zero or varies creation order.

## What happens now

Spike: two `Memory` stores are seeded with the same two slots, one restarting at 0 and one at 50, in the two possible creation orders, and `Oldest_Restart_LSN` is read from each. A third store then performs exactly the sequence `Apply_Retention` performs, and reads back the WAL the zero slot still needs.

```ada
Memory.Create (Ascending, "fresh",
   Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 0), Created);
Memory.Create (Ascending, "later",
   Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 50), Created);
--  Descending gets "later" first, then "fresh".

Memory.Append (Retained, 0, (1 .. 100 => 7));
Floor := Memory.Oldest_Restart_LSN (Retained);
if Floor > Memory.First_LSN (Retained) then
   Memory.Retain_From (Retained, Floor);
end if;
...
Note ("Read (0, 10) returned" & Natural'Image (Memory.Read (Retained, 0, 10)'Length) ...);
```

Output:

```
  -- slots created as (fresh=0, later=50): Oldest_Restart_LSN = 50
  -- slots created as (later=50, fresh=0): Oldest_Restart_LSN = 0
  FAILED: the retention floor of one set of slots does not depend on the order they were created in
  FAILED: the retention floor never exceeds the restart LSN of a live slot (a slot restarting at 0 still needs WAL from 0)
  -- after Apply_Retention with a live slot restarting at 0, First_LSN = 50
  -- Read (0, 10) raised Store_Error: the WAL slot "fresh" restarts from is gone
BUG REPRODUCED: 3 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Oldest_Restart_LSN` should return the minimum restart LSN over all present, non-invalidated slots regardless of iteration order, and zero only when no such slot exists, as `persistence.ads:175-178` states. It must never exceed the restart LSN of a live slot, because `Apply_Retention` treats it as the position below which WAL is no longer needed.

## Suggested treatment

Track "seen a candidate" separately from the value:

```ada
overriding function Oldest_Restart_LSN (Item : Store) return LSN is
   Result : LSN := 0;
   Found  : Boolean := False;
begin
   for Item_Entry of Item.Slots loop
      if Item_Entry.State.Present and then not Item_Entry.State.Invalid
        and then (not Found or else Item_Entry.State.Restart < Result)
      then
         Result := Item_Entry.State.Restart;
         Found := True;
      end if;
   end loop;
   return Result;
end Oldest_Restart_LSN;
```

The regression test belongs in `tests/src/replication_persistence_conformance.adb` beside the existing floor check at :122-124: create one slot at restart zero alongside a higher one and assert the floor is zero. The spike is that test, and its order-independence case is worth keeping as a second store. No existing assertion has to change; the :122-124 check remains true under the corrected function.

## Severity

The WAL retention floor is computed above a live slot's restart position, so `Apply_Retention` discards WAL that slot still needs and its next read raises `Store_Error`. The trigger is ordinary: a logical slot created on an empty managed primary restarts at zero, and any second slot created after WAL has accumulated is enough. It is confined to the bounded reference store and the test store that wraps it, not to a durability path an application ships. Deterministic.
