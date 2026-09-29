--  PROTO-7: Maximum_Message_Size is documented as the largest complete wire
--  message "including its type byte and encoded length"
--  (flyology-postgres.ads:6-8), but Make_Message accepts a payload of
--  Maximum_Message_Size - 4 and Valid_Typed_Length accepts a length field of
--  Maximum_Message_Size, both of which describe a frame of
--  Maximum_Message_Size + 1 bytes.

with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Flyology.Postgres.Wire;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_7 is

   use type Protocol.Byte_Offset;

   package Wire renames Flyology.Postgres.Wire;

   Max : constant := Protocol.Maximum_Message_Size;

   type Payload_Access is access Protocol.Byte_Array;
   procedure Free is new Ada.Unchecked_Deallocation
     (Protocol.Byte_Array, Payload_Access);

   Largest_Payload : constant Protocol.Byte_Offset :=
     Protocol.Byte_Offset (Max) - 4;
   --  The largest payload Make_Message currently admits.

   Buffer : Payload_Access;
   Raised : Boolean := False;
   Frame  : Protocol.Byte_Offset := 0;

begin
   Note ("Maximum_Message_Size =" & Integer'Image (Max)
         & "; documented as the largest complete message INCLUDING the "
         & "type byte and the encoded length");

   --  Read side: a typed length field of Maximum_Message_Size means a frame
   --  of 1 + Maximum_Message_Size bytes on the wire.
   Note ("Wire.Valid_Typed_Length (" & Integer'Image (Max) & " ) -> "
         & Boolean'Image
             (Wire.Valid_Typed_Length (Protocol.UInt32 (Max)))
         & "; that length describes a"
         & Integer'Image (Max + 1) & "-byte frame");
   Check
     (not Wire.Valid_Typed_Length (Protocol.UInt32 (Max)),
      "a typed length field of Maximum_Message_Size is rejected, because "
      & "the resulting frame is Maximum_Message_Size + 1 bytes");
   Check
     (Wire.Valid_Typed_Length (Protocol.UInt32 (Max - 1)),
      "a typed length field of Maximum_Message_Size - 1 is still accepted");

   --  Write side: Make_Message admits a payload that encodes to
   --  Maximum_Message_Size + 1 bytes.
   Buffer := new Protocol.Byte_Array'(1 .. Largest_Payload => 0);
   begin
      declare
         Item : constant Protocol.Message :=
           Protocol.Make_Message ('d', Buffer.all);
      begin
         Frame :=
           Protocol.Byte_Offset (Protocol.Payload_Length (Item)) + 5;
         Note ("Make_Message ('d', payload of"
               & Protocol.Byte_Offset'Image (Largest_Payload)
               & " bytes) succeeded; Encode would emit"
               & Protocol.Byte_Offset'Image (Frame) & " bytes");
      end;
   exception
      when Protocol.Protocol_Error =>
         Raised := True;
         Note ("Make_Message rejected the oversized payload");
   end;
   Free (Buffer);

   Check
     (Raised,
      "Make_Message rejects a payload whose complete frame would exceed "
      & "Maximum_Message_Size");
   if not Raised then
      Note ("the encoded frame would be"
            & Protocol.Byte_Offset'Image (Frame - Protocol.Byte_Offset (Max))
            & " byte(s) larger than the documented maximum");
   end if;

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: " & Ada.Exceptions.Exception_Name (E)
            & ": " & Ada.Exceptions.Exception_Message (E));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Proto_7;
