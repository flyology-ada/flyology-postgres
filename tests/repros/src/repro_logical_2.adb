--  LOGICAL-2: Logical.Producer models a single in-flight transaction and
--  treats every StreamAbort as terminal.
--
--  (a) Subtransaction abort.  pgoutput's pgoutput_stream_abort writes
--      'A' with the *top-level* xid and the aborted (sub)transaction id;
--      when a ROLLBACK TO SAVEPOINT aborts a streamed subtransaction, subxid
--      differs from xid and the top-level transaction stays streamed, so
--      further S(xid, first_segment = false) segments and finally c(xid)
--      follow.  PostgreSQL's apply_handle_stream_abort mirrors that: only
--      when xid = subxid does it finish the transaction; otherwise it merely
--      truncates the spool file back to the subxact's start offset and stays
--      inside the transaction.  The Producer ignores Subtransaction (Message)
--      entirely and returns to Idle with XID 0, losing the still-open
--      top-level transaction.
--
--  (b) Interleaving.  Streaming exists precisely so that other work continues
--      while a large transaction is in progress: after 'E' the walsender goes
--      on decoding, so a small transaction can be sent as B..C, or another
--      large transaction can start its own segment, before S(xid, false)
--      resumes the paused one.  The Producer's Stream_Paused state admits
--      only S/c/A/p for the *same* xid.
--
--  Correct behavior asserted here: the subtransaction abort leaves the
--  top-level transaction paused and lets it continue, and an unrelated
--  transaction may be produced between two segments.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Logical.Producer;
with Repro_Support; use Repro_Support;

procedure Repro_Logical_2 is

   package Logical renames Flyology.Postgres.Replication.Logical;
   package Producer renames Flyology.Postgres.Replication.Logical.Producer;

   use type Logical.Transaction_Id;
   use type Producer.Transaction_State;

   Top_Xid : constant Logical.Transaction_Id := 20;
   Sub_Xid : constant Logical.Transaction_Id := 21;

   Row : constant Logical.Tuple_Data :=
     Logical.Make_Tuple ((1 => Logical.Text_Column ("42")));

   E : Producer.Encoder;

   Paused_After_Sub_Abort : Boolean := False;
   Xid_Kept               : Boolean := False;
   Continued              : Boolean := False;
   Interleaved_Begin      : Boolean := False;
   Interleaved_Stream     : Boolean := False;

   procedure Emit (Message : Logical.Message; Start, Stop : Logical.LSN) is
      Data : constant Logical.Byte_Array :=
        Producer.Emit (E, Message, Start, Stop);
      pragma Unreferenced (Data);
   begin
      null;
   end Emit;

   procedure Report_State (Label : String) is
   begin
      Note (Label & ": state = "
            & Producer.Transaction_State'Image (Producer.State (E))
            & ", Transaction ="
            & Producer.Transaction (E)'Image);
   end Report_State;

begin
   ------------------------------------------------------------------
   --  (a) subtransaction abort inside a streamed transaction
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
   Emit (Logical.Make_Stream_Start (Top_Xid, True), 200, 201);
   Emit (Logical.Make_Insert (42, Row, Xid => Top_Xid), 201, 202);
   Emit (Logical.Make_Stream_Stop, 202, 203);
   Report_State ("after StreamStop");

   Emit
     (Logical.Make_Stream_Abort (Xid => Top_Xid, Subxid => Sub_Xid),
      203, 204);
   Report_State ("after StreamAbort (xid 20, subxid 21)");

   Paused_After_Sub_Abort :=
     Producer.State (E) = Producer.Stream_Paused;
   Xid_Kept := Producer.Transaction (E) = Top_Xid;

   begin
      Emit (Logical.Make_Stream_Start (Top_Xid, False), 204, 205);
      Continued := True;
      Note ("continuation segment for xid 20 accepted");
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("continuation segment for xid 20 rejected: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   ------------------------------------------------------------------
   --  (b) other work between two segments of a paused transaction
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
   Emit (Logical.Make_Stream_Start (30, True), 300, 301);
   Emit (Logical.Make_Insert (42, Row, Xid => 30), 301, 302);
   Emit (Logical.Make_Stream_Stop, 302, 303);
   Report_State ("xid 30 paused");

   begin
      Emit (Logical.Make_Begin (400, 0, 31), 303, 304);
      Emit (Logical.Make_Insert (42, Row), 304, 305);
      Emit (Logical.Make_Commit (400, 401, 0), 305, 306);
      Interleaved_Begin := True;
      Note ("small transaction 31 produced while xid 30 is paused");
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("small transaction 31 rejected while xid 30 is paused: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
   Emit (Logical.Make_Stream_Start (40, True), 500, 501);
   Emit (Logical.Make_Stream_Stop, 501, 502);
   begin
      Emit (Logical.Make_Stream_Start (41, True), 502, 503);
      Interleaved_Stream := True;
      Note ("second streamed transaction 41 started while xid 40 is paused");
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("second streamed transaction 41 rejected: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   Check
     (Paused_After_Sub_Abort,
      "a StreamAbort naming a subtransaction leaves the top-level streamed "
      & "transaction paused");
   Check
     (Xid_Kept,
      "a StreamAbort naming a subtransaction keeps the top-level xid");
   Check
     (Continued,
      "the top-level transaction may continue with a further segment after "
      & "one of its subtransactions aborts");
   Check
     (Interleaved_Begin,
      "an unrelated transaction may be produced between two segments of a "
      & "paused streamed transaction");
   Check
     (Interleaved_Stream,
      "a second streamed transaction may start while another is paused");

   Finish;
end Repro_Logical_2;
