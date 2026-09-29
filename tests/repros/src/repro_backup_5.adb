--  BACKUP-5: Prepared_Consumer.Prepare overwrites an existing
--  Target_Applied marker for the same (slot, GID), defeating the replay
--  guard the package header promises.
--
--  prepared_consumer.ads:3-5 says durable prepared state survives consumer
--  replacement "while an applied marker prevents replay after target
--  application has been recorded", and Acknowledge_Commit's comment
--  (ads:71-72) says "Retaining the marker until then bounds replay".
--
--  prepared_consumer.adb:7-20 calls Stores.Put unconditionally, and Put is
--  documented (persistence.ads:281-286) to "insert or replace" -- so a
--  second PREPARE for the same GID silently demotes Target_Applied back to
--  Prepared.
--
--  Scenario 1 (crash replay): the consumer applies and marks a prepared
--  transaction, then fails before its feedback confirms the commit LSN.
--  PostgreSQL re-decodes from the confirmed flush position and re-sends the
--  PREPARE; the consumer's Prepare wipes the marker and the following Commit
--  applies the transaction a second time.
--
--  Scenario 2 (GID reuse): PostgreSQL lets a GID be reused once the earlier
--  prepared transaction has committed.  A second PREPARE for the same GID
--  arriving before the first commit has been acknowledged replaces the first
--  transaction's Target_Applied record, so the pending
--  Acknowledge_Commit for the first transaction raises Protocol_Error.
--
--  Correct behavior: after target application has been recorded, a repeated
--  PREPARE for the same (slot, GID) does not clear the marker, so Commit
--  does not invoke Apply_Target again and a pending Acknowledge_Commit still
--  finds the applied state it was promised.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Flyology.Postgres.Replication.Prepared_Consumer;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_5 is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   type Target_Context is limited record
      Applications : Natural := 0;
      Last_XID     : Replication.Transaction_Id := 0;
   end record;

   procedure Apply_Target
     (Context   : in out Target_Context;
      Slot_Name : String;
      GID       : String;
      XID       : Replication.Transaction_Id;
      Payload   : Persistence.Byte_Array);

   procedure Apply_Target
     (Context   : in out Target_Context;
      Slot_Name : String;
      GID       : String;
      XID       : Replication.Transaction_Id;
      Payload   : Persistence.Byte_Array)
   is
      pragma Unreferenced (Slot_Name, Payload);
   begin
      Context.Applications := Context.Applications + 1;
      Context.Last_XID := XID;
      Note ("Apply_Target invoked for GID """ & GID & """, XID ="
            & Replication.Transaction_Id'Image (XID)
            & " (application #" & Natural'Image (Context.Applications) & " )");
   end Apply_Target;

   package Consumers is new
     Flyology.Postgres.Replication.Prepared_Consumer
       (Target_Context => Target_Context,
        Apply_Target   => Apply_Target);

   ----------------------------------------------------------------------
   --  Scenario 1: replayed PREPARE after the target has been applied.
   ----------------------------------------------------------------------

   Replay_Store  : aliased Memory.Store;
   Replay_Target : aliased Target_Context;
   Replay        : Consumers.Consumer
     (Store => Replay_Store'Access, Target => Replay_Target'Access);
   Applied       : Boolean;

   ----------------------------------------------------------------------
   --  Scenario 2: the source reuses the GID before the first commit has
   --  been acknowledged.
   ----------------------------------------------------------------------

   Reuse_Store   : aliased Memory.Store;
   Reuse_Target  : aliased Target_Context;
   Reuse         : Consumers.Consumer
     (Store => Reuse_Store'Access, Target => Reuse_Target'Access);
   Acknowledged  : Boolean := False;
   Failure       : Boolean := False;

begin
   Note ("--- scenario 1: PREPARE replayed after target application ---");
   Consumers.Prepare
     (Replay, "logical", "gid-replay",
      XID => 1, Prepare_LSN => 10, Payload => (1, 2));
   Consumers.Commit (Replay, "logical", "gid-replay", Applied);
   Check (Applied and then Replay_Target.Applications = 1,
          "the first commit applies the prepared transaction once "
          & "(harness sanity check)");

   --  The consumer restarts before its feedback confirmed the commit LSN, so
   --  PostgreSQL re-sends the identical PREPARE.
   Consumers.Prepare
     (Replay, "logical", "gid-replay",
      XID => 1, Prepare_LSN => 10, Payload => (1, 2));
   Consumers.Commit (Replay, "logical", "gid-replay", Applied);

   Note ("after the replayed PREPARE and COMMIT PREPARED: Applied_Now = "
         & Boolean'Image (Applied) & ", Apply_Target calls ="
         & Natural'Image (Replay_Target.Applications));
   Check
     (not Applied and then Replay_Target.Applications = 1,
      "the durable applied marker prevents replay: a repeated PREPARE and "
      & "COMMIT PREPARED for the same GID does not re-apply the target");

   Note ("--- scenario 2: the source reuses the GID before acknowledgement "
         & "---");
   Consumers.Prepare
     (Reuse, "logical", "gid-shared",
      XID => 11, Prepare_LSN => 20, Payload => (3, 4));
   Consumers.Commit (Reuse, "logical", "gid-shared", Applied);
   Check (Applied and then Reuse_Target.Applications = 1,
          "the first transaction is applied (harness sanity check)");

   --  The source commits transaction 11, then prepares transaction 12 under
   --  the same GID.  The consumer has not yet acknowledged the commit LSN of
   --  transaction 11.
   Consumers.Prepare
     (Reuse, "logical", "gid-shared",
      XID => 12, Prepare_LSN => 30, Payload => (5, 6));

   begin
      Consumers.Acknowledge_Commit (Reuse, "logical", "gid-shared");
      Acknowledged := True;
      Note ("Acknowledge_Commit for transaction 11 returned normally");
   exception
      when Event : Flyology.Postgres.Protocol.Protocol_Error =>
         Failure := True;
         Note ("Acknowledge_Commit for transaction 11 raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Event));
   end;

   Check
     (Acknowledged and then not Failure,
      "acknowledging the commit LSN of the first transaction still finds "
      & "the applied state the consumer recorded for it");

   Finish;
end Repro_Backup_5;
