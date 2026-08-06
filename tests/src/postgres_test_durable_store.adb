with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Replication_Persistence_Conformance;
with Replication_Test_Durable_Store;

procedure Postgres_Test_Durable_Store is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames
     Flyology.Postgres.Replication.Persistence;
   package Durable is new Replication_Test_Durable_Store (Capacity => 8);

   use type Replication.LSN;
   use type Replication.UInt32;
   use type Persistence.Byte_Array;
   use type Persistence.Acquire_Result;
   use type Persistence.Create_Result;
   use type Persistence.Prepared_Phase;

   procedure Require (Condition : Boolean; Reason : String) is
   begin
      if not Condition then
         raise Program_Error with Reason;
      end if;
   end Require;

   package Conformance is new Replication_Persistence_Conformance
     (Check => Require);

   Root : constant String := Ada.Environment_Variables.Value
     ("POSTGRES_DURABLE_STORE_DIR");
   Action : constant String := Ada.Environment_Variables.Value
     ("POSTGRES_DURABLE_STORE_ACTION");
   Item : Durable.Store;
   Created : Persistence.Create_Result;
   Acquired : Persistence.Acquire_Result;
   State : Persistence.Slot_State;
   Prepared : Persistence.Prepared_Transaction;
   Lease : Persistence.UInt64;
   Changed : Boolean;
   Timeline : Replication.UInt32;
begin
   Durable.Open (Item, Root);
   if Action = "conformance" then
      Conformance.Run (Item, Item, Item, Item);
      Durable.Close (Item);
      Ada.Text_IO.Put_Line ("durable-conformance-passed");
   elsif Action = "physical-initialize" then
      declare
         Slot_Name : constant String := Ada.Environment_Variables.Value
           ("POSTGRES_DURABLE_PHYSICAL_SLOT");
         Fork_LSN : constant Replication.LSN := Replication.Value
           (Ada.Environment_Variables.Value
              ("POSTGRES_DURABLE_FORK_LSN"));
      begin
         Durable.Create
           (Item,
            Slot_Name,
            Persistence.Make_Slot
              (Persistence.Physical_Slot, Restart_LSN => Fork_LSN),
            Created);
         Require
           (Created = Persistence.Created,
            "managed physical slot create failed");
         Durable.Promote (Item, 1, Fork_LSN, Timeline);
         Require (Timeline = 2, "managed timeline promotion failed");
         Durable.Close (Item);
         Ada.Text_IO.Put_Line
           ("physical-timeline-ready fork=" & Replication.Image (Fork_LSN));
      end;
   elsif Action = "initialize" then
      Durable.Create
        (Item,
         "physical",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 100),
         Created);
      Require (Created = Persistence.Created, "physical slot create failed");
      Durable.Create
        (Item,
         "logical",
         Persistence.Make_Slot
           (Persistence.Logical_Slot, 100, 100, "pgoutput"),
         Created);
      Require (Created = Persistence.Created, "logical slot create failed");
      Durable.Append (Item, 100, (1, 2, 3, 4, 5, 6));
      Durable.Promote (Item, 1, 105, Timeline);
      Require (Timeline = 2, "timeline promotion was not durable");
      Durable.Put
        (Item,
         "logical",
         "gid-crash",
         Persistence.Make_Prepared (77, 110, (9, 8, 7)));
      Durable.Close (Item);
      Ada.Text_IO.Put_Line ("initialized");
   elsif Action = "advance-and-wait" then
      Durable.Acquire
        (Item, "logical", Persistence.Logical_Slot,
         Acquired, Lease, State);
      Require (Acquired = Persistence.Acquired, "logical acquire failed");
      Durable.Advance
        (Item, "logical", Lease, 120, 120, Changed);
      Require (Changed, "logical acknowledgement was not persisted");
      Durable.Mark_Target_Applied
        (Item, "logical", "gid-crash", Changed);
      Require (Changed, "prepared target marker was not persisted");
      Ada.Text_IO.Put_Line ("durable-before-crash");
      Ada.Text_IO.Flush;
      delay 30.0;
      raise Program_Error with "advance process was not terminated";
   elsif Action = "verify-and-acknowledge" then
      State := Durable.Load (Item, "logical");
      Require
        (Persistence.Exists (State)
         and then not Persistence.Is_Active (State)
         and then Persistence.Restart_LSN (State) = 120
         and then Persistence.Confirmed_LSN (State) = 120,
         "crash recovery lost acknowledgement or abandoned its lease");
      Prepared := Durable.Load (Item, "logical", "gid-crash");
      Require
        (Persistence.Exists (Prepared)
         and then Persistence.Phase (Prepared) =
           Persistence.Target_Applied,
         "target-applied marker did not survive process termination");
      Durable.Acquire
        (Item, "logical", Persistence.Logical_Slot,
         Acquired, Lease, State);
      Require
        (Acquired = Persistence.Acquired and then Lease > 1,
         "recovered slot did not issue a new fencing generation");
      Durable.Release (Item, "logical", Lease, Changed);
      Require (Changed, "recovered lease was not released");
      Durable.Remove (Item, "logical", "gid-crash", Changed);
      Require (Changed, "source acknowledgement did not remove marker");
      Durable.Close (Item);
      Ada.Text_IO.Put_Line ("recovered-and-acknowledged");
   elsif Action = "inject-torn-and-wait" then
      Durable.Inject_Torn_Tail (Item, "incomplete-uncommitted-record");
      Ada.Text_IO.Put_Line ("torn-tail-durable");
      Ada.Text_IO.Flush;
      delay 30.0;
      raise Program_Error with "torn-tail process was not terminated";
   elsif Action = "verify-repair" then
      State := Durable.Load (Item, "logical");
      Require
        (Persistence.Restart_LSN (State) = 120
         and then Persistence.Confirmed_LSN (State) = 120,
         "repair changed the last acknowledged slot position");
      Require
        (Durable.Current_Timeline (Item) = 2
         and then Durable.History (Item, 2)'Length > 0,
         "repair lost persisted timeline history");
      Require
        (Durable.Read (Item, 100, 6) =
           Persistence.Byte_Array'(1, 2, 3, 4, 5, 6),
         "repair lost persisted WAL bytes");
      Prepared := Durable.Load (Item, "logical", "gid-crash");
      Require
        (not Persistence.Exists (Prepared),
         "acknowledged prepared marker reappeared after repair");
      Durable.Close (Item);
      Ada.Text_IO.Put_Line ("tail-repaired");
   elsif Action = "hold-lock" then
      Ada.Text_IO.Put_Line ("lock-held");
      Ada.Text_IO.Flush;
      delay 30.0;
      Durable.Close (Item);
   elsif Action = "open-and-close" then
      Durable.Close (Item);
      Ada.Text_IO.Put_Line ("opened");
   else
      raise Program_Error with "unknown durable-store action";
   end if;
end Postgres_Test_Durable_Store;
