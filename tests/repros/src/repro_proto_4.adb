--  PROTO-4: the startup `replication` value is matched case-sensitively
--  against a closed list of exact spellings.  PostgreSQL's
--  ProcessStartupPacket uses parse_bool, which is case-insensitive and
--  accepts unique prefixes, so spellings a real server accepts are rejected
--  here with Protocol_Error.

with Ada.Exceptions;
with Flyology.Bytes;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_4 is

   use type Protocol.Replication_Connection_Mode;

   Version_3_0 : constant Protocol.UInt32 := 196_608;  --  major 3, minor 0

   function Startup_Contents (Replication : String) return Protocol.Byte_Array
   is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, Version_3_0);
      Protocol.Append_C_String (Contents, "user");
      Protocol.Append_C_String (Contents, "alice");
      Protocol.Append_C_String (Contents, "replication");
      Protocol.Append_C_String (Contents, Replication);
      Protocol.Append_Byte (Contents, 0);
      return Flyology.Bytes.To_Array (Contents);
   end Startup_Contents;

   procedure Expect
     (Value    : String;
      Expected : Protocol.Replication_Connection_Mode)
   is
      Actual : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection;
      Failed : Boolean := False;
   begin
      begin
         Actual :=
           Protocol.Startup_Data
             (Protocol.Decode_Initial (Startup_Contents (Value))).
               Replication_Mode;
      exception
         when E : Protocol.Protocol_Error =>
            Failed := True;
            Note ("replication=""" & Value & """ -> Protocol_Error: "
                  & Ada.Exceptions.Exception_Message (E));
      end;
      if not Failed then
         Note ("replication=""" & Value & """ -> " & Actual'Image);
      end if;
      Check
        (not Failed and then Actual = Expected,
         "replication=""" & Value & """ decodes as " & Expected'Image
         & ", as PostgreSQL's parse_bool accepts it");
   end Expect;

begin
   Note ("PostgreSQL matches `replication` with strcmp against ""database"""
         & " and otherwise parse_bool, which is case-insensitive and");
   Note ("accepts unique prefixes: t, tr, tru, true, y, ye, yes, on, 1 and"
         & " f, fa, fal, fals, false, n, no, of, off, 0.");

   --  Control cases: the spellings this implementation does accept.
   Expect ("true", Protocol.Physical_Replication_Connection);
   Expect ("database", Protocol.Logical_Replication_Connection);
   Expect ("false", Protocol.Normal_Connection);

   --  Spellings a real PostgreSQL server accepts and this decoder rejects.
   Expect ("TRUE", Protocol.Physical_Replication_Connection);
   Expect ("True", Protocol.Physical_Replication_Connection);
   Expect ("t", Protocol.Physical_Replication_Connection);
   Expect ("On", Protocol.Physical_Replication_Connection);
   Expect ("Yes", Protocol.Physical_Replication_Connection);
   Expect ("f", Protocol.Normal_Connection);
   Expect ("Off", Protocol.Normal_Connection);

   Note ("Framing.Read_Initial is called in the declarative part of the "
         & "server's Run_Session, so this Protocol_Error drops the");
   Note ("connection before any FATAL ErrorResponse is written.");

   Finish;
end Repro_Proto_4;
