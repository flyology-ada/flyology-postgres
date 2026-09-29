--  BACKUP-6: Memory.Create validates only the Present flag of the supplied
--  snapshot, so an active, leased, or invalidated snapshot can be stored as
--  the initial state of a new slot.
--
--  memory.adb:36-57 checks "Name'Length = 0 or else not State.Present" and
--  then copies the whole record, Active / Lease / Invalid included.  The
--  interface documents the parameter as "Initial state created by
--  Make_Slot" (persistence.ads:101) and the Memory child documents
--  "@exception Store_Error State is invalid or capacity is exhausted"
--  (memory.ads:29), but no such check exists.
--
--  Copying a Load-ed snapshot -- for instance while seeding a second store
--  from a first one -- therefore creates a slot that nobody can acquire
--  (Already_Active forever), nobody can drop (Drop refuses active slots),
--  and whose restart LSN keeps pinning the WAL retention floor, because the
--  lease that would release it belongs to another store.
--
--  Correct behavior: Create rejects a snapshot that is not an inactive,
--  unleased, valid initial state with Store_Error.

with Ada.Exceptions;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_6 is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   use type Persistence.Acquire_Result;
   use type Persistence.Create_Result;
   use type Persistence.UInt64;

   Source   : aliased Memory.Store;
   Copy     : aliased Memory.Store;
   Created  : Persistence.Create_Result;
   Acquired : Persistence.Acquire_Result;
   Lease    : Persistence.UInt64;
   State    : Persistence.Slot_State;
   Rejected : Boolean := False;
   Dropped  : Boolean;

begin
   Memory.Create
     (Source, "held",
      Persistence.Make_Slot (Persistence.Physical_Slot, Restart_LSN => 10),
      Created);
   Memory.Acquire
     (Source, "held", Persistence.Physical_Slot, Acquired, Lease, State);
   Check (Acquired = Persistence.Acquired
          and then Persistence.Is_Active (State),
          "the source store holds an active lease (harness sanity check)");

   --  Seed a second store from the first store's snapshot.
   begin
      Memory.Create (Copy, "copied", State, Created);
      Note ("Create with an active, leased snapshot returned "
            & Persistence.Create_Result'Image (Created));
   exception
      when Event : Persistence.Store_Error =>
         Rejected := True;
         Note ("Create with an active, leased snapshot raised Store_Error: "
               & Ada.Exceptions.Exception_Message (Event));
   end;

   Check
     (Rejected,
      "Create rejects a snapshot that is not an inactive, unleased initial "
      & "state, as its documented Store_Error requires");

   if not Rejected then
      Memory.Acquire
        (Copy, "copied", Persistence.Physical_Slot, Acquired, Lease, State);
      Note ("Acquire on the copied slot returned "
            & Persistence.Acquire_Result'Image (Acquired)
            & ", lease =" & Persistence.UInt64'Image (Lease));
      Memory.Drop (Copy, "copied", Dropped);
      Note ("Drop on the copied slot returned " & Boolean'Image (Dropped));
      Note ("the copied slot still pins the retention floor at"
            & Replication.LSN'Image (Memory.Oldest_Restart_LSN (Copy)));

      Check
        (Acquired = Persistence.Acquired or else Dropped,
         "a stored slot can always be either acquired or dropped, so it "
         & "cannot be stranded active with a lease no owner of this store "
         & "holds");
   end if;

   Finish;
end Repro_Backup_6;
