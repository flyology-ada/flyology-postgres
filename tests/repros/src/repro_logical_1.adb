--  LOGICAL-1: Logical.Producer accepts a data message that carries no
--  streamed transaction id while a stream segment is open, and encodes it
--  without the four-byte xid prefix.
--
--  pgoutput writes the top-level xid on every Relation, Type, Insert, Update,
--  Delete, Truncate and Message emitted between StreamStart ('S') and
--  StreamStop ('E'): pgoutput.c sets `xid = txn->xid` whenever `in_streaming`
--  is set, and proto.c's logicalrep_write_* then prefixes it.  A consumer
--  that is inside the segment therefore reads four bytes of xid first --
--  PostgreSQL's apply worker via logicalrep_read_* while
--  in_streamed_transaction, and this library's own stateful Decoder via its
--  In_Stream flag.  Bytes emitted without the prefix are shifted by four
--  bytes and are either rejected or silently misread.
--
--  Correct behavior asserted here: Producer.Emit rejects a non-streamed data
--  message while a segment is open, and whatever bytes it does return are
--  read back unchanged by a consumer sitting inside that same segment.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Logical.Producer;
with Repro_Support; use Repro_Support;

procedure Repro_Logical_1 is

   package Logical renames Flyology.Postgres.Replication.Logical;
   package Producer renames Flyology.Postgres.Replication.Logical.Producer;

   use type Logical.LSN;
   use type Logical.UInt32;
   use type Logical.Transaction_Id;

   Segment_Xid : constant Logical.Transaction_Id := 20;
   Relation    : constant Logical.UInt32 := 42;

   Row : constant Logical.Tuple_Data :=
     Logical.Make_Tuple ((1 => Logical.Text_Column ("42")));

   --  A logical decoding message chosen so that dropping the xid prefix
   --  produces a *valid but different* message when it is re-read inside the
   --  segment: the fourth LSN byte is zero, so it lands on the flags octet,
   --  and the prefix is eight characters, so the shifted C string still
   --  terminates in the right place.
   Message_Position : constant Logical.LSN := 16#0102_0300_0102_0304#;
   Message_Prefix   : constant String := "abcdefgh";
   Message_Content  : constant Logical.Byte_Array := (1, 2, 3, 4);

   function Hex_LSN (Value : Logical.LSN) return String is
      Digits_16 : constant String := "0123456789ABCDEF";
      Result    : String (1 .. 16);
      Shifted   : Logical.LSN := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Digits_16 (Natural (Shifted mod 16) + 1);
         Shifted := Shifted / 16;
      end loop;
      return Result;
   end Hex_LSN;

   E : Producer.Encoder;
   D : Logical.Decoder;

   Insert_Rejected  : Boolean := False;
   Message_Rejected : Boolean := False;
   Insert_Faithful  : Boolean := True;
   Message_Faithful : Boolean := True;

begin
   Producer.Configure
     (E, Version => 2, Streaming => Logical.In_Progress);
   Logical.Configure
     (D, Version => 2, Streaming => Logical.In_Progress);

   --  Open one stream segment on both sides.
   declare
      Start_Bytes : constant Logical.Byte_Array :=
        Producer.Emit
          (E, Logical.Make_Stream_Start (Segment_Xid, True), 200, 201);
      Ignored : constant Logical.Message := Logical.Decode (D, Start_Bytes);
      pragma Unreferenced (Ignored);
   begin
      Note ("StreamStart bytes: " & Hex (Start_Bytes));
   end;
   Note ("producer state = "
         & Producer.Transaction_State'Image (Producer.State (E))
         & ", consumer inside stream = "
         & Boolean'Image (Logical.Inside_Stream (D)));

   --  Case A: an Insert built with the default Xid => 0.
   begin
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit (E, Logical.Make_Insert (Relation, Row), 201, 202);
      begin
         Note ("Insert accepted inside the segment: " & Hex (Data));
         Note ("  producer state stays "
               & Producer.Transaction_State'Image (Producer.State (E)));
         begin
            declare
               M : constant Logical.Message := Logical.Decode (D, Data);
            begin
               Note ("  in-stream consumer read xid ="
                     & Logical.Transaction (M)'Image
                     & ", relation =" & Logical.Relation_Id (M)'Image);
               Insert_Faithful :=
                 Logical.Transaction (M) = Segment_Xid
                 and then Logical.Relation_Id (M) = Relation;
            end;
         exception
            when Err : Flyology.Postgres.Protocol.Protocol_Error =>
               Insert_Faithful := False;
               Note ("  in-stream consumer rejected those bytes: "
                     & Ada.Exceptions.Exception_Message (Err));
         end;
      end;
   exception
      when Flyology.Postgres.Protocol.Protocol_Error =>
         Insert_Rejected := True;
         Note ("Producer rejected the non-streamed Insert (correct)");
   end;

   --  Case B: a logical decoding message built with the default Xid => 0.
   begin
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit
             (E,
              Logical.Make_Logical_Decoding_Message
                (Message_LSN   => Message_Position,
                 Prefix        => Message_Prefix,
                 Content       => Message_Content,
                 Transactional => True),
              202, 203);
      begin
         Note ("Message accepted inside the segment: " & Hex (Data));
         begin
            declare
               M : constant Logical.Message := Logical.Decode (D, Data);
            begin
               Note ("  in-stream consumer read xid ="
                     & Logical.Transaction (M)'Image
                     & ", transactional = "
                     & Boolean'Image (Logical.Is_Transactional (M)));
               Note ("  in-stream consumer read LSN = 16#"
                     & Hex_LSN (Logical.Message_LSN (M)) & "# (sent 16#"
                     & Hex_LSN (Message_Position) & "#)");
               Note ("  in-stream consumer read prefix """
                     & Logical.Prefix (M) & """ (sent """
                     & Message_Prefix & """)");
               Message_Faithful :=
                 Logical.Transaction (M) = Segment_Xid
                 and then Logical.Is_Transactional (M)
                 and then Logical.Message_LSN (M) = Message_Position
                 and then Logical.Prefix (M) = Message_Prefix
                 and then Hex (Logical.Content (M)) = Hex (Message_Content);
            end;
         exception
            when Err : Flyology.Postgres.Protocol.Protocol_Error =>
               Message_Faithful := False;
               Note ("  in-stream consumer rejected those bytes: "
                     & Ada.Exceptions.Exception_Message (Err));
         end;
      end;
   exception
      when Flyology.Postgres.Protocol.Protocol_Error =>
         Message_Rejected := True;
         Note ("Producer rejected the non-streamed Message (correct)");
   end;

   Check
     (Insert_Rejected,
      "Producer rejects an Insert without a streamed xid while a stream "
      & "segment is open");
   Check
     (Insert_Faithful,
      "bytes the Producer emits inside a segment are read back unchanged by "
      & "an in-stream consumer (Insert)");
   Check
     (Message_Rejected,
      "Producer rejects a logical decoding message without a streamed xid "
      & "while a stream segment is open");
   Check
     (Message_Faithful,
      "bytes the Producer emits inside a segment are read back unchanged by "
      & "an in-stream consumer (Message)");

   Finish;
end Repro_Logical_1;
