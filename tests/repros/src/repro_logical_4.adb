--  LOGICAL-4: Logical.Producer does not check that Commit.commit_lsn equals
--  the pending Begin.final_lsn (nor Prepare.prepare_lsn against
--  BeginPrepare.prepare_lsn), so it validates a sequence that a real
--  PostgreSQL subscriber rejects.
--
--  PostgreSQL's apply worker stores begin_data.final_lsn in remote_final_lsn
--  in apply_handle_begin, and apply_handle_commit raises
--  ERRCODE_PROTOCOL_VIOLATION -- "incorrect commit LSN %X/%X in commit
--  message (expected %X/%X)" -- when commit_data.commit_lsn differs (an
--  Assert before PostgreSQL 14, an ereport since).  apply_handle_prepare
--  performs the same comparison against prepare_data.prepare_lsn.  pgoutput
--  itself writes txn->final_lsn into both Begin.final_lsn and
--  Commit.commit_lsn, so the two always agree on the wire.
--
--  Correct behavior asserted here: the Producer refuses the mismatched pair
--  and still accepts the matching one.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Logical.Producer;
with Repro_Support; use Repro_Support;

procedure Repro_Logical_4 is

   package Logical renames Flyology.Postgres.Replication.Logical;
   package Producer renames Flyology.Postgres.Replication.Logical.Producer;

   E : Producer.Encoder;

   Commit_Mismatch_Barred  : Boolean := False;
   Prepare_Mismatch_Barred : Boolean := False;
   Matching_Commit_Kept    : Boolean := False;

   procedure Emit (Message : Logical.Message; Start, Stop : Logical.LSN) is
      Data : constant Logical.Byte_Array :=
        Producer.Emit (E, Message, Start, Stop);
   begin
      Note ("  emitted " & Hex (Data));
   end Emit;

begin
   ------------------------------------------------------------------
   --  Begin final_lsn 16#101# followed by Commit commit_lsn 16#103#.
   --  This is the sequence tests/src/replication_tests.adb already uses.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 1);
   Note ("Begin final_lsn = 16#101#");
   Emit (Logical.Make_Begin (16#101#, 0, 10), 16#100#, 16#101#);
   begin
      Note ("Commit commit_lsn = 16#103# (does not match the Begin)");
      Emit (Logical.Make_Commit (16#103#, 16#104#, 0), 16#103#, 16#104#);
      Note ("  accepted; a PostgreSQL apply worker would raise "
            & "ERRCODE_PROTOCOL_VIOLATION on these bytes");
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Commit_Mismatch_Barred := True;
         Note ("  rejected: " & Ada.Exceptions.Exception_Message (Err));
   end;

   ------------------------------------------------------------------
   --  BeginPrepare prepare_lsn 16#301# followed by Prepare 16#302#.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 3);
   Note ("BeginPrepare prepare_lsn = 16#301#");
   Emit
     (Logical.Make_Begin_Prepare (16#301#, 16#302#, 0, 11, "gid-11"),
      16#300#, 16#301#);
   begin
      Note ("Prepare prepare_lsn = 16#302# (does not match BeginPrepare)");
      Emit
        (Logical.Make_Prepare (16#302#, 16#303#, 0, 11, "gid-11"),
         16#302#, 16#303#);
      Note ("  accepted; a PostgreSQL apply worker would raise "
            & "ERRCODE_PROTOCOL_VIOLATION on these bytes");
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Prepare_Mismatch_Barred := True;
         Note ("  rejected: " & Ada.Exceptions.Exception_Message (Err));
   end;

   ------------------------------------------------------------------
   --  The agreeing pair pgoutput actually produces must stay accepted.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 1);
   begin
      Note ("Begin/Commit both at final_lsn 16#130#");
      Emit (Logical.Make_Begin (16#130#, 0, 12), 16#120#, 16#130#);
      Emit (Logical.Make_Commit (16#130#, 16#140#, 0), 16#130#, 16#140#);
      Matching_Commit_Kept := True;
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("  unexpectedly rejected: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   Check
     (Commit_Mismatch_Barred,
      "Producer rejects a Commit whose commit LSN differs from the pending "
      & "Begin's final LSN");
   Check
     (Prepare_Mismatch_Barred,
      "Producer rejects a Prepare whose prepare LSN differs from the pending "
      & "BeginPrepare's prepare LSN");
   Check
     (Matching_Commit_Kept,
      "Producer still accepts the agreeing Begin/Commit pair pgoutput emits");

   Finish;
end Repro_Logical_4;
