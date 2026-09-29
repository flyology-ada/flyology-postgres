--  BACKUP-2: Memory.Oldest_Restart_LSN uses zero both as "nothing seen yet"
--  and as a legitimate restart position, so the WAL retention floor depends
--  on the order the slots occupy in the store.
--
--  persistence.ads:175-178 documents Oldest_Restart_LSN as "Compute the
--  retention floor across all non-invalidated slots. @return Oldest restart
--  LSN, or zero when no slot retains WAL", and
--  Managed_Primary.Apply_Retention (managed_primary.adb:104-114) feeds the
--  result straight into Retain_From, discarding every WAL byte below it.
--
--  A restart LSN of zero is reachable: Managed_Primary's
--  CREATE_REPLICATION_SLOT handler (managed_primary.adb:339-359) creates a
--  logical slot with Restart_LSN => Current_LSN, which is zero on a fresh
--  Memory store (WAL_Base = 0, no WAL appended yet).
--
--  memory.adb:163-175 then computes, for slots {0, 50}: array order [0, 50]
--  -> 50, array order [50, 0] -> 0.  The first answer is above a live slot's
--  restart position, so Apply_Retention trims WAL that slot still needs.
--
--  Correct behavior: the retention floor is the minimum restart LSN over all
--  non-invalidated slots, independent of insertion order, and never exceeds
--  any live slot's restart LSN.

with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_2 is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   use type Replication.LSN;

   Ascending  : aliased Memory.Store;
   Descending : aliased Memory.Store;
   Created    : Persistence.Create_Result;

   Floor_Ascending  : Replication.LSN;
   Floor_Descending : Replication.LSN;

begin
   --  Same two slots, created in the two possible orders.  "fresh" restarts
   --  at zero, exactly as a logical slot created on an empty managed primary
   --  does; "later" restarts at 50.
   Memory.Create
     (Ascending, "fresh",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 0),
      Created);
   Memory.Create
     (Ascending, "later",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 50),
      Created);

   Memory.Create
     (Descending, "later",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 50),
      Created);
   Memory.Create
     (Descending, "fresh",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 0),
      Created);

   Floor_Ascending := Memory.Oldest_Restart_LSN (Ascending);
   Floor_Descending := Memory.Oldest_Restart_LSN (Descending);

   Note ("slots created as (fresh=0, later=50): Oldest_Restart_LSN ="
         & Replication.LSN'Image (Floor_Ascending));
   Note ("slots created as (later=50, fresh=0): Oldest_Restart_LSN ="
         & Replication.LSN'Image (Floor_Descending));

   Check
     (Floor_Ascending = Floor_Descending,
      "the retention floor of one set of slots does not depend on the order "
      & "they were created in");
   Check
     (Floor_Ascending <= 0,
      "the retention floor never exceeds the restart LSN of a live slot "
      & "(a slot restarting at 0 still needs WAL from 0)");

   --  Consequence, spelled out with the same operations Apply_Retention
   --  performs (managed_primary.adb:104-114): WAL a live slot still needs is
   --  discarded.
   declare
      Retained : aliased Memory.Store;
      Lost     : Boolean := False;
      Floor    : Replication.LSN;
   begin
      Memory.Create
        (Retained, "fresh",
         Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 0),
         Created);
      Memory.Append (Retained, 0, (1 .. 100 => 7));
      Memory.Create
        (Retained, "later",
         Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 50),
         Created);
      Floor := Memory.Oldest_Restart_LSN (Retained);
      if Floor > Memory.First_LSN (Retained) then
         Memory.Retain_From (Retained, Floor);
      end if;
      Note ("after Apply_Retention with a live slot restarting at 0, "
            & "First_LSN =" & Replication.LSN'Image
              (Memory.First_LSN (Retained)));
      begin
         Note ("Read (0, 10) returned"
               & Natural'Image (Memory.Read (Retained, 0, 10)'Length)
               & " byte(s)");
      exception
         when Persistence.Store_Error =>
            Lost := True;
            Note ("Read (0, 10) raised Store_Error: the WAL slot ""fresh"" "
                  & "restarts from is gone");
      end;
      Check
        (not Lost,
         "WAL that the slot restarting at 0 still needs survives retention");
   end;

   Finish;
end Repro_Backup_2;
