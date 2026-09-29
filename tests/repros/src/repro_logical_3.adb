--  LOGICAL-3: Logical.Producer rejects a NON-transactional logical decoding
--  message outside a transaction, which is exactly where pgoutput emits one.
--
--  pgoutput.c's pgoutput_message sends a BEGIN first only for transactional
--  messages ("Output BEGIN if we haven't yet.  Avoid for non-transactional
--  messages"); a message written by pg_logical_emit_message (false, ...) is
--  queued by ReorderBufferQueueMessage and streamed out immediately at decode
--  time, so it appears outside any B/C pair and outside any S/E pair --
--  including between two segments of a paused streamed transaction.
--
--  Make_Logical_Decoding_Message models this explicitly and even defaults to
--  Transactional => False, but Producer.Emit applies one blanket
--  "pgoutput data message is outside a transaction" rule to the whole
--  data-message group.
--
--  Correct behavior asserted here: a non-transactional message is emitted
--  wherever it occurs, and a transactional one outside a transaction is
--  still rejected.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Logical.Producer;
with Repro_Support; use Repro_Support;

procedure Repro_Logical_3 is

   package Logical renames Flyology.Postgres.Replication.Logical;
   package Producer renames Flyology.Postgres.Replication.Logical.Producer;

   use type Logical.LSN;
   use type Logical.Message_Kind;

   Prefix  : constant String := "app";
   Payload : constant Logical.Byte_Array := (1 => 1);

   function Non_Transactional (At_LSN : Logical.LSN) return Logical.Message is
     (Logical.Make_Logical_Decoding_Message
        (Message_LSN   => At_LSN,
         Prefix        => Prefix,
         Content       => Payload,
         Transactional => False));

   E : Producer.Encoder;

   Idle_Accepted        : Boolean := False;
   Idle_Faithful        : Boolean := False;
   Between_Accepted     : Boolean := False;
   Transactional_Barred : Boolean := False;

begin
   ------------------------------------------------------------------
   --  Outside any transaction, protocol version 1.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 1);
   begin
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit (E, Non_Transactional (16#100#), 16#100#, 16#101#);
         Read_Back : constant Logical.Message :=
           Logical.Decode (Data, Version => 1);
      begin
         Idle_Accepted := True;
         Note ("non-transactional message outside a transaction: "
               & Hex (Data));
         Idle_Faithful :=
           Logical.Kind (Read_Back) = Logical.Logical_Decoding_Message
           and then not Logical.Is_Transactional (Read_Back)
           and then Logical.Message_LSN (Read_Back) = 16#100#
           and then Logical.Prefix (Read_Back) = Prefix
           and then Hex (Logical.Content (Read_Back)) = Hex (Payload);
      end;
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("non-transactional message outside a transaction rejected: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   ------------------------------------------------------------------
   --  Between two segments of a paused streamed transaction.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
   declare
      Ignored : constant Logical.Byte_Array :=
        Producer.Emit (E, Logical.Make_Stream_Start (20, True), 200, 201);
      pragma Unreferenced (Ignored);
   begin
      null;
   end;
   declare
      Ignored : constant Logical.Byte_Array :=
        Producer.Emit (E, Logical.Make_Stream_Stop, 201, 202);
      pragma Unreferenced (Ignored);
   begin
      null;
   end;
   begin
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit (E, Non_Transactional (16#202#), 202, 203);
      begin
         Between_Accepted := True;
         Note ("non-transactional message between segments: " & Hex (Data));
      end;
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("non-transactional message between segments rejected: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   ------------------------------------------------------------------
   --  A transactional message outside a transaction must stay rejected.
   ------------------------------------------------------------------
   Producer.Configure (E, Version => 1);
   begin
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit
             (E,
              Logical.Make_Logical_Decoding_Message
                (Message_LSN   => 16#100#,
                 Prefix        => Prefix,
                 Content       => Payload,
                 Transactional => True),
              16#100#, 16#101#);
      begin
         Note ("transactional message outside a transaction accepted: "
               & Hex (Data));
      end;
   exception
      when Flyology.Postgres.Protocol.Protocol_Error =>
         Transactional_Barred := True;
   end;

   Check
     (Idle_Accepted,
      "Producer emits a non-transactional logical decoding message outside "
      & "any transaction");
   Check
     (Idle_Faithful,
      "the emitted non-transactional message decodes back to what was built");
   Check
     (Between_Accepted,
      "Producer emits a non-transactional logical decoding message between "
      & "two segments of a paused streamed transaction");
   Check
     (Transactional_Barred,
      "a transactional logical decoding message outside a transaction is "
      & "still rejected");

   Finish;
end Repro_Logical_3;
