--  SERVER-4: Read_Copy_Command rejects a Sync (and a Flush) received during
--  COPY IN with Protocol_Error, although
--    * its own contract (src/flyology-postgres-server_sessions.ads:32) says
--      "@return CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate
--      event" -- values Protocol.Frontend_Copy_Kind cannot even represent,
--      and
--    * PostgreSQL's CopyGetData (src/backend/commands/copyfromparse.c)
--      accepts PqMsg_Flush and PqMsg_Sync during COPY from stdin and skips
--      them: "Ignore Flush/Sync for the convenience of client libraries
--      (such as libpq) that may send those without noticing that the command
--      they just sent was COPY."
--
--  This is reachable from ordinary clients: libpq's PQexecParams /
--  PQsendQueryParams pipeline Parse/Bind/Describe/Execute/Sync in one flush,
--  so when the command turns out to be COPY ... FROM STDIN the Sync is
--  already queued ahead of the first CopyData.
--
--  Correct behavior: Read_Command/Read_Copy_Command consumes the Sync and
--  returns the following CopyData (PostgreSQL's behavior), or at minimum
--  classifies it as the .ads promises.  Either way it must not raise.

with Ada.Exceptions;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Server_4 is

   package Sessions renames Flyology.Postgres.Server_Sessions;

   use type Protocol.Byte;
   use type Protocol.Frontend_Copy_Kind;
   use type Protocol.Byte_Array;

   Chunk : constant Protocol.Byte_Array (1 .. 2) :=
     (Protocol.Byte (Character'Pos ('a')),
      Protocol.Byte (Character'Pos (ASCII.LF)));

   Channel : aliased Memory_Transport;
   Session : Sessions.Session (Channel'Access);

   Raised  : Boolean := False;
   Got_Data : Boolean := False;

begin
   --  What libpq leaves in the stream when PQexecParams issued the COPY:
   --  the trailing Sync of the extended-query cycle, then the COPY payload.
   Queue (Channel, Protocol.Make_Sync_Message);
   Queue (Channel, Protocol.Make_Copy_Data_Message (Chunk));

   Note ("queued frontend bytes: " & Hex (Protocol.Encode
     (Protocol.Make_Sync_Message)) & "| "
     & Hex (Protocol.Encode (Protocol.Make_Copy_Data_Message (Chunk))));

   begin
      declare
         Command : constant Protocol.Frontend_Copy_Message :=
           Sessions.Read_Copy_Command (Session, 1.0);
      begin
         Note ("Read_Copy_Command classified the message as "
               & Protocol.Copy_Kind (Command)'Image);
         if Protocol.Copy_Kind (Command) = Protocol.Frontend_Copy_Data
           and then Protocol.Copy_Bytes (Command) = Chunk
         then
            Got_Data := True;
         end if;
      end;
   exception
      when E : others =>
         Raised := True;
         Note ("Read_Copy_Command raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   Check
     (not Raised,
      "a Sync arriving during COPY IN does not make Read_Copy_Command "
      & "raise; PostgreSQL ignores Flush/Sync there (copyfromparse.c)");
   Check
     (Got_Data,
      "the CopyData that follows the ignored Sync is delivered to the "
      & "COPY handler");

   if Raised then
      Note ("Server.Run_Session turns this into FATAL 08P01 'message is not"
            & " a frontend COPY command' and drops the connection"
            & " (src/flyology-postgres-server.adb:524-535)");
      Note ("Protocol.Frontend_Copy_Kind is (Frontend_Copy_Data,"
            & " Frontend_Copy_Done, Frontend_Copy_Fail) only, so the Flush,"
            & " Sync and Terminate results promised by"
            & " server_sessions.ads:32 are unrepresentable");
   end if;

   Finish;
end Repro_Server_4;
