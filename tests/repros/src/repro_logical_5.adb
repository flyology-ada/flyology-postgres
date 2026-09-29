--  LOGICAL-5: Abort_LSN and Event_Timestamp raise Protocol_Error on a
--  Stream Abort built by Make_Stream_Abort even when the caller supplied the
--  version-4 abort metadata.
--
--  Make_Stream_Abort stores Abort_LSN and Aborted_At in the message and
--  Encode (Item, 4, Parallel) serialises them, but the private
--  Parallel_Stream flag that both accessors require is set only by Decode.
--  The accessors document "@exception Protocol_Error Item lacks version-4
--  abort metadata", which is false for a message that carries it.
--
--  Correct behavior asserted here: what Make_Stream_Abort accepted and
--  Encode wrote out can be read back from the same message object.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical;
with Repro_Support; use Repro_Support;

procedure Repro_Logical_5 is

   package Logical renames Flyology.Postgres.Replication.Logical;

   use type Logical.LSN;
   use type Logical.Replication_Timestamp;

   Top_Xid    : constant Logical.Transaction_Id := 51;
   Sub_Xid    : constant Logical.Transaction_Id := 52;
   Abort_At   : constant Logical.LSN := 53;
   Aborted_At : constant Logical.Replication_Timestamp := 54;

   Built : constant Logical.Message :=
     Logical.Make_Stream_Abort (Top_Xid, Sub_Xid, Abort_At, Aborted_At);

   Wire : constant Logical.Byte_Array :=
     Logical.Encode (Built, 4, Logical.Parallel);

   LSN_Readable  : Boolean := False;
   Time_Readable : Boolean := False;

begin
   Note ("Make_Stream_Abort (51, 52, 53, 54) encodes at v4/parallel as: "
         & Hex (Wire));

   begin
      Note ("Abort_LSN (built) =" & Logical.Abort_LSN (Built)'Image);
      LSN_Readable := Logical.Abort_LSN (Built) = Abort_At;
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("Abort_LSN (built) raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   begin
      Note ("Event_Timestamp (built) ="
            & Logical.Event_Timestamp (Built)'Image);
      Time_Readable := Logical.Event_Timestamp (Built) = Aborted_At;
   exception
      when Err : Flyology.Postgres.Protocol.Protocol_Error =>
         Note ("Event_Timestamp (built) raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Err));
   end;

   --  The same values are readable once the bytes have made a round trip,
   --  which shows the metadata really is present and correctly encoded.
   declare
      Decoded : constant Logical.Message :=
        Logical.Decode
          (Wire, Version => 4, Streaming => Logical.Parallel);
   begin
      Note ("after a v4/parallel round trip: Abort_LSN ="
            & Logical.Abort_LSN (Decoded)'Image
            & ", Event_Timestamp ="
            & Logical.Event_Timestamp (Decoded)'Image);
   end;

   Check
     (LSN_Readable,
      "Abort_LSN returns the abort LSN supplied to Make_Stream_Abort");
   Check
     (Time_Readable,
      "Event_Timestamp returns the abort time supplied to Make_Stream_Abort");

   Finish;
end Repro_Logical_5;
