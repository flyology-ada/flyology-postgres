--  PROTO-2: Startup_Data, Process_Id and Secret_Key document
--  "@exception Protocol_Error Item is not <variant>" but perform no variant
--  check; they silently return the default record components.

with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_2 is

   use type Protocol.Byte_Offset;
   use type Protocol.Initial_Kind;
   use type Protocol.UInt32;

   Packet : constant Protocol.Byte_Array := Protocol.Encode_SSL_Request;
   --  Framing.Read_Initial strips the length word before decoding, so the
   --  contents an SSLRequest actually decodes from are bytes 5 .. 8.
   Contents : constant Protocol.Byte_Array :=
     Packet (Packet'First + 4 .. Packet'Last);

   Item : constant Protocol.Initial_Request :=
     Protocol.Decode_Initial (Contents);

   Raised : Boolean;

begin
   Note ("SSLRequest contents: " & Hex (Contents));
   Note ("Protocol.Kind = " & Protocol.Kind (Item)'Image);
   Check
     (Protocol.Kind (Item) = Protocol.SSL_Request,
      "the packet decodes as SSL_Request (so it is neither Startup nor "
      & "Cancel_Request)");

   Raised := False;
   begin
      declare
         Info : constant Protocol.Startup_Information :=
           Protocol.Startup_Data (Item);
      begin
         Note ("Startup_Data returned a record instead of raising: major ="
               & Protocol.UInt16'Image (Info.Protocol_Major)
               & ", user = """
               & Ada.Strings.Unbounded.To_String (Info.User) & """");
      end;
   exception
      when Protocol.Protocol_Error =>
         Raised := True;
   end;
   Check
     (Raised,
      "Startup_Data raises Protocol_Error when Item is not Startup "
      & "(protocol.ads:602)");

   Raised := False;
   begin
      declare
         Pid : constant Protocol.UInt32 := Protocol.Process_Id (Item);
      begin
         Note ("Process_Id returned" & Protocol.UInt32'Image (Pid)
               & " instead of raising");
      end;
   exception
      when Protocol.Protocol_Error =>
         Raised := True;
   end;
   Check
     (Raised,
      "Process_Id raises Protocol_Error when Item is not Cancel_Request "
      & "(protocol.ads:607)");

   Raised := False;
   begin
      declare
         Secret : constant Protocol.Byte_Array := Protocol.Secret_Key (Item);
      begin
         Note ("Secret_Key returned a"
               & Protocol.Byte_Offset'Image (Secret'Length)
               & "-byte array instead of raising");
      end;
   exception
      when Protocol.Protocol_Error =>
         Raised := True;
   end;
   Check
     (Raised,
      "Secret_Key raises Protocol_Error when Item is not Cancel_Request "
      & "(protocol.ads:612)");

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: " & Ada.Exceptions.Exception_Name (E)
            & ": " & Ada.Exceptions.Exception_Message (E));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Proto_2;
