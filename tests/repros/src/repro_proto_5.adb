--  PROTO-5: `_pq_.*` protocol options in a startup packet are discarded by
--  Decode_Initial.  The protocol requires a server to answer
--  NegotiateProtocolVersion listing every unrecognized _pq_. option, but no
--  API exposes that a client asked for one: a startup packet that requests
--  _pq_.foo decodes to exactly the same Startup_Information as one that does
--  not.

with Ada.Exceptions;
with Flyology.Bytes;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_5 is

   use type Protocol.Startup_Information;

   Version_3_0 : constant Protocol.UInt32 := 196_608;  --  major 3, minor 0

   function Plain_Startup return Protocol.Byte_Array is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, Version_3_0);
      Protocol.Append_C_String (Contents, "user");
      Protocol.Append_C_String (Contents, "alice");
      Protocol.Append_Byte (Contents, 0);
      return Flyology.Bytes.To_Array (Contents);
   end Plain_Startup;

   function Startup_With_Option return Protocol.Byte_Array is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, Version_3_0);
      Protocol.Append_C_String (Contents, "user");
      Protocol.Append_C_String (Contents, "alice");
      Protocol.Append_C_String (Contents, "_pq_.some_option");
      Protocol.Append_C_String (Contents, "1");
      Protocol.Append_Byte (Contents, 0);
      return Flyology.Bytes.To_Array (Contents);
   end Startup_With_Option;

   Without : constant Protocol.Startup_Information :=
     Protocol.Startup_Data (Protocol.Decode_Initial (Plain_Startup));
   With_Option : constant Protocol.Startup_Information :=
     Protocol.Startup_Data (Protocol.Decode_Initial (Startup_With_Option));

begin
   Note ("startup without options:   " & Hex (Plain_Startup));
   Note ("startup with _pq_.some_option=1: " & Hex (Startup_With_Option));
   Note ("Decode_Initial accepted both packets without error.");

   Check
     (With_Option /= Without,
      "a startup packet requesting _pq_.some_option decodes differently "
      & "from one that requests nothing, so a server can list the "
      & "unrecognized option in NegotiateProtocolVersion");

   if With_Option = Without then
      Note ("the two decoded Startup_Information values are identical, so "
            & "the requested protocol option is unrecoverable and");
      Note ("Send_Negotiate_Protocol can only ever encode 0 unrecognized "
            & "options (server_sessions.adb:156-157).");
   end if;

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: " & Ada.Exceptions.Exception_Name (E)
            & ": " & Ada.Exceptions.Exception_Message (E));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Proto_5;
