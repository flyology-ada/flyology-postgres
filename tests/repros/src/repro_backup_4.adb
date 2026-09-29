--  BACKUP-4: Persistence.Generation keeps reporting the stale lease of a
--  slot that has been released.
--
--  persistence.ads:72-75 documents the accessor as
--     "Read the lease generation captured by a slot snapshot.
--      @return Nonzero generation for an acquired slot, otherwise zero."
--  and persistence.adb:43 returns the stored Lease field unconditionally.
--  Memory.Release (memory.adb:147-161) clears State.Active but leaves
--  State.Lease set, so a released slot's snapshot reports Is_Active = False
--  together with a nonzero Generation.
--
--  Application code that follows the documented accessor and uses
--  Generation (State) /= 0 as the "this slot is leased" test therefore sees
--  a free slot as held.
--
--  Correct behavior: Generation is nonzero exactly for a slot that is
--  currently acquired, so a released slot reports zero.

with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_4 is

   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   use type Persistence.Acquire_Result;
   use type Persistence.Create_Result;
   use type Persistence.UInt64;

   Store    : aliased Memory.Store;
   Created  : Persistence.Create_Result;
   Acquired : Persistence.Acquire_Result;
   Lease    : Persistence.UInt64;
   State    : Persistence.Slot_State;
   Released : Boolean;

begin
   Memory.Create
     (Store, "primary",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 10),
      Created);
   Check (Created = Persistence.Created, "slot creation (harness check)");

   State := Memory.Load (Store, "primary");
   Check (Persistence.Generation (State) = 0,
          "a never-acquired slot reports generation zero "
          & "(harness sanity check)");

   Memory.Acquire
     (Store, "primary", Persistence.Physical_Slot, Acquired, Lease, State);
   Check (Acquired = Persistence.Acquired and then Lease /= 0,
          "slot acquisition issues a nonzero lease (harness check)");
   Check (Persistence.Generation (State) = Lease,
          "an acquired slot reports its lease (harness sanity check)");

   Memory.Release (Store, "primary", Lease, Released);
   Check (Released, "the matching lease is released (harness check)");

   State := Memory.Load (Store, "primary");
   Note ("after Release: Is_Active = "
         & Boolean'Image (Persistence.Is_Active (State))
         & ", Generation ="
         & Persistence.UInt64'Image (Persistence.Generation (State)));

   Check
     (not Persistence.Is_Active (State),
      "the released slot is no longer active (harness sanity check)");
   Check
     (Persistence.Generation (State) = 0,
      "a released slot reports generation zero, as the accessor's contract "
      & "requires (nonzero only for an acquired slot)");

   Finish;
end Repro_Backup_4;
