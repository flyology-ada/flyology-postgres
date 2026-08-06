with Flyology.Postgres.Replication.Persistence;

generic
   type Target_Context (<>) is limited private;
   with procedure Apply_Target
     (Context     : in out Target_Context;
      Slot_Name  : String;
      GID         : String;
      XID         : Transaction_Id;
      Payload     : Persistence.Byte_Array);
package Flyology.Postgres.Replication.Prepared_Consumer is

   package Stores renames Flyology.Postgres.Replication.Persistence;

   type Consumer
     (Store  : not null access Stores.Prepared_Store'Class;
      Target : not null access Target_Context) is limited private;

   --  Persist before acknowledging Prepare or StreamPrepare to the source.
   procedure Prepare
     (Item        : in out Consumer;
      Slot_Name   : String;
      GID         : String;
      XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Stores.Byte_Array);

   --  Apply_Target must be idempotent for (Slot_Name, GID, XID). Commit marks
   --  Target_Applied durably, so a restarted consumer will not call it again
   --  after that marker is visible. The target and marker may be made fully
   --  atomic by implementing both in the same application transaction.
   procedure Commit
     (Item       : in out Consumer;
      Slot_Name  : String;
      GID        : String;
      Applied_Now : out Boolean);

   --  Remove only after the source commit LSN has itself been durably
   --  acknowledged. Keeping the marker until then bounds replay safely.
   procedure Acknowledge_Commit
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String);

   procedure Rollback
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String);

private
   type Consumer
     (Store  : not null access Stores.Prepared_Store'Class;
      Target : not null access Target_Context) is limited null record;

end Flyology.Postgres.Replication.Prepared_Consumer;
