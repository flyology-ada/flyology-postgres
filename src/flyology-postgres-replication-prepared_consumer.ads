with Flyology.Postgres.Replication.Persistence;

--  Recovery coordinator for pgoutput two-phase transactions. Durable prepared
--  state survives consumer replacement, while an applied marker prevents
--  replay after target application has been recorded.
--
--  Apply_Target must be idempotent for (Slot_Name, GID, XID), because a
--  process can fail after target commit but before Mark_Target_Applied. An
--  application can eliminate that interval by committing the target change
--  and marker in one transaction.
--
--  @formal Target_Context Application target state.
--  @formal Apply_Target Applies one deterministic prepared payload.
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
   --  Consumer bound to shared prepared state and an application target.
   --  @field Store Durable prepared-transaction store.
   --  @field Target Application context passed to Apply_Target.

   procedure Prepare
     (Item        : in out Consumer;
      Slot_Name   : String;
      GID         : String;
      XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Stores.Byte_Array);
   --  Persist a prepared payload before acknowledging Prepare or StreamPrepare
   --  to the source.
   --  @param Item Consumer coordinator.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @param XID Nonzero source transaction identifier.
   --  @param Prepare_LSN Nonzero source prepare position.
   --  @param Payload Deterministic data required by Apply_Target.
   --  @exception Constraint_Error XID or Prepare_LSN is zero.
   --  @exception Store_Error The backend cannot durably store the
   --     transaction.

   procedure Commit
     (Item        : in out Consumer;
      Slot_Name   : String;
      GID         : String;
      Applied_Now : out Boolean);
   --  Apply a prepared transaction once per durable recovery state, then mark
   --  Target_Applied. A replacement Consumer sharing Store observes the marker
   --  and does not invoke Apply_Target again.
   --  @param Item Consumer coordinator.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @param Applied_Now True when this call invoked Apply_Target.
   --  @exception Protocol_Error No durable prepared state exists.
   --  @exception Store_Error The applied marker cannot be persisted.

   procedure Acknowledge_Commit
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String);
   --  Remove Target_Applied state after the source commit LSN has itself been
   --  durably acknowledged. Retaining the marker until then bounds replay.
   --  @param Item Consumer coordinator.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @exception Protocol_Error Target application is not durably
   --     marked.
   --  @exception Store_Error Durable state disappears before removal.

   procedure Rollback
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String);
   --  Remove a prepared transaction that has not been applied to the target.
   --  @param Item Consumer coordinator.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @exception Protocol_Error State is missing or already applied.
   --  @exception Store_Error Durable state disappears before removal.

private
   type Consumer
     (Store  : not null access Stores.Prepared_Store'Class;
      Target : not null access Target_Context) is limited null record;

end Flyology.Postgres.Replication.Prepared_Consumer;
