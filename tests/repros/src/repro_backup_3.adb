--  BACKUP-3: Memory.Append treats a store whose bytes were all trimmed by
--  Retain_From as a brand-new empty store, so it silently rebases WAL and
--  moves Current_LSN backwards.
--
--  memory.adb:206-217 decides contiguity from the size of the retained
--  buffer alone:
--     if To_Array (Item.WAL_Data)'Length = 0 then Item.WAL_Base := Start;
--     elsif Start /= Current_LSN (Item) then raise Store_Error ...
--  Retain_From (Oldest = Current_LSN) (memory.adb:219-239) empties the
--  buffer and sets WAL_Base := Oldest, which is exactly what
--  Managed_Primary.Apply_Retention does once the only slot's restart LSN has
--  caught up with the end of WAL.  The store still has a real end position
--  (First_LSN = Current_LSN = Oldest), but the next Append is accepted at
--  any Start whatsoever.
--
--  Correct behavior: a fully drained store keeps its end position.  An
--  Append below it is rejected ("WAL append is not contiguous",
--  memory.ads:121), and in no case may Current_LSN move backwards or
--  previously issued WAL positions be reused for different bytes.

with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_3 is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   use type Replication.LSN;

   Store    : aliased Memory.Store;
   Rejected : Boolean := False;

   End_Before : Replication.LSN;

begin
   Memory.Append (Store, 100, (1, 2, 3, 4, 5, 6));
   End_Before := Memory.Current_LSN (Store);
   Check (Memory.First_LSN (Store) = 100 and then End_Before = 106,
          "the store spans 100 .. 106 after the first append "
          & "(harness sanity check)");

   --  Apply_Retention performs exactly this call once the only slot's
   --  restart LSN equals the end of available WAL.
   Memory.Retain_From (Store, 106);
   Check (Memory.First_LSN (Store) = 106
          and then Memory.Current_LSN (Store) = 106,
          "the drained store still reports its real end position 106 "
          & "(harness sanity check)");

   begin
      Memory.Append (Store, 50, (9, 9, 9, 9));
      Note ("Append (Start => 50) on the drained store was accepted");
   exception
      when Persistence.Store_Error =>
         Rejected := True;
         Note ("Append (Start => 50) on the drained store raised "
               & "Store_Error");
   end;

   Note ("after the rewinding append: First_LSN ="
         & Replication.LSN'Image (Memory.First_LSN (Store))
         & ", Current_LSN =" & Replication.LSN'Image
           (Memory.Current_LSN (Store)));

   Check
     (Rejected,
      "an append below the end position of a fully drained store is "
      & "rejected as non-contiguous");
   Check
     (Memory.Current_LSN (Store) >= End_Before,
      "Current_LSN never moves backwards, so WAL positions already handed "
      & "to a standby are not reused for different bytes");

   Finish;
end Repro_Backup_3;
