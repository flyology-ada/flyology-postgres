with Flyology.Postgres.Replication;

package body Replication_Persistence_Conformance is

   package Replication renames Flyology.Postgres.Replication;

   use type Replication.LSN;
   use type Replication.UInt32;
   use type Persistence.Acquire_Result;
   use type Persistence.Byte_Array;
   use type Persistence.Create_Result;
   use type Persistence.Prepared_Phase;

   procedure Run
     (Slots    : in out Persistence.Slot_Store'Class;
      WAL      : in out Persistence.WAL_Store'Class;
      Timelines : in out Persistence.Timeline_Store'Class;
      Prepared : in out Persistence.Prepared_Store'Class) is
      Created  : Persistence.Create_Result;
      Acquired : Persistence.Acquire_Result;
      State    : Persistence.Slot_State;
      Lease_1  : Persistence.UInt64;
      Lease_2  : Persistence.UInt64;
      Changed  : Boolean;
      Timeline : Replication.UInt32;
      Prepared_State : Persistence.Prepared_Transaction;
   begin
      Persistence.Create
        (Slots,
         "conformance_physical",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 100),
         Created);
      Check (Created = Persistence.Created, "slot creation");
      Persistence.Create
        (Slots,
         "conformance_physical",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 100),
         Created);
      Check (Created = Persistence.Already_Exists, "idempotent slot creation");

      Persistence.Acquire
        (Slots, "conformance_physical", Persistence.Physical_Slot,
         Acquired, Lease_1, State);
      Check
        (Acquired = Persistence.Acquired and then Lease_1 /= 0
         and then Persistence.Is_Active (State),
         "exclusive slot acquisition");
      Persistence.Acquire
        (Slots, "conformance_physical", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Check
        (Acquired = Persistence.Already_Active and then Lease_2 = 0,
         "active slot rejection");
      Persistence.Drop (Slots, "conformance_physical", Changed);
      Check (not Changed, "active slot drop rejection");
      Persistence.Advance
        (Slots, "conformance_physical", Lease_1, 120, 0, Changed);
      Check (Changed, "monotonic slot advancement");
      Persistence.Advance
        (Slots, "conformance_physical", Lease_1, 119, 0, Changed);
      Check (not Changed, "backward slot advancement rejection");
      Persistence.Release
        (Slots, "conformance_physical", Lease_1, Changed);
      Check (Changed, "matching lease release");
      Persistence.Acquire
        (Slots, "conformance_physical", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Check
        (Acquired = Persistence.Acquired and then Lease_2 > Lease_1,
         "increasing lease generation");
      Persistence.Advance
        (Slots, "conformance_physical", Lease_1, 130, 0, Changed);
      Check (not Changed, "stale lease fencing");
      Persistence.Release
        (Slots, "conformance_physical", Lease_2, Changed);
      Check (Changed, "replacement lease release");
      Persistence.Acquire
        (Slots, "missing", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Check
        (Acquired = Persistence.Missing and then Lease_2 = 0,
         "missing slot acquisition");
      Persistence.Acquire
        (Slots, "conformance_physical", Persistence.Logical_Slot,
         Acquired, Lease_2, State);
      Check
        (Acquired = Persistence.Kind_Mismatch and then Lease_2 = 0,
         "slot kind mismatch");
      Persistence.Drop
        (Slots, "conformance_physical", Changed);
      Check
        (Changed
         and then not Persistence.Exists
           (Persistence.Load (Slots, "conformance_physical")),
         "inactive slot drop");

      Persistence.Create
        (Slots,
         "conformance_invalid",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 108),
         Created);
      Persistence.Invalidate (Slots, "conformance_invalid", Changed);
      Check (Changed, "slot invalidation");
      Persistence.Acquire
        (Slots, "conformance_invalid", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Check
        (Acquired = Persistence.Invalidated and then Lease_2 = 0,
         "invalidated slot acquisition");
      Persistence.Drop (Slots, "conformance_invalid", Changed);
      Check (Changed, "invalidated inactive slot drop");

      Persistence.Create
        (Slots,
         "conformance_logical",
         Persistence.Make_Slot
           (Persistence.Logical_Slot, 110, 115, "pgoutput"),
         Created);
      Check
        (Persistence.Oldest_Restart_LSN (Slots) = 110,
         "oldest restart retention floor");

      Persistence.Append (WAL, 100, (1, 2, 3, 4, 5, 6));
      Check
        (Persistence.First_LSN (WAL) = 100
         and then Persistence.Current_LSN (WAL) = 106
         and then Persistence.Read (WAL, 102, 3) =
           Persistence.Byte_Array'(3, 4, 5),
         "exact WAL append and read");
      Persistence.Retain_From (WAL, 103);
      Check
        (Persistence.First_LSN (WAL) = 103
         and then Persistence.Read (WAL, 103, 10) =
           Persistence.Byte_Array'(4, 5, 6),
         "exact WAL prefix retention");

      Persistence.Promote (Timelines, 1, 105, Timeline);
      Check
        (Timeline = 2
         and then Persistence.Current_Timeline (Timelines) = 2
         and then Persistence.History (Timelines, 2)'Length > 0,
         "timeline promotion and history persistence");

      Prepared_State := Persistence.Make_Prepared
        (77, 150, (9, 8, 7));
      Persistence.Put
        (Prepared, "conformance_logical", "conformance_gid",
         Prepared_State);
      Prepared_State := Persistence.Load
        (Prepared, "conformance_logical", "conformance_gid");
      Check
        (Persistence.Exists (Prepared_State)
         and then Persistence.XID (Prepared_State) = 77
         and then Persistence.Payload (Prepared_State) =
           Persistence.Byte_Array'(9, 8, 7)
         and then Persistence.Phase (Prepared_State) = Persistence.Prepared,
         "prepared payload persistence");
      Persistence.Mark_Target_Applied
        (Prepared, "conformance_logical", "conformance_gid", Changed);
      Check (Changed, "prepared applied transition");
      Persistence.Mark_Target_Applied
        (Prepared, "conformance_logical", "conformance_gid", Changed);
      Check (not Changed, "prepared applied idempotency");
      Persistence.Remove
        (Prepared, "conformance_logical", "conformance_gid", Changed);
      Check
        (Changed
         and then not Persistence.Exists
           (Persistence.Load
              (Prepared, "conformance_logical", "conformance_gid")),
         "prepared removal after acknowledgement");
   end Run;

end Replication_Persistence_Conformance;
