--  REPL-3: Replication.Server_Sessions.Read_Standby_Message turns a legal
--  standby-initiated CopyDone into the same Protocol_Error a malformed frame
--  produces, so a primary awaiting feedback cannot tell "the standby closed
--  its direction" from "the standby sent garbage".
--
--  Read_Standby_Message is
--    server_sessions.adb:201-206
--      return Decode (Sessions.Read_Command (Client, Timeout));
--  and Decode insists on CopyData
--    replication.adb:929-931
--      Require (Protocol.Code (Item) = 'd',
--               "replication streaming requires a CopyData message");
--  Read_Command returns whatever typed frontend message arrives, so a 'c'
--  frame reaches Decode.
--
--  A standby closing its send direction mid-stream is normal PostgreSQL, not
--  an error.  walsender.c 18.4:2260-2330 loops over standby replies while
--  streaming and, on PqMsg_CopyDone, replies with its own CopyDone rather
--  than failing:
--      case PqMsg_CopyDone:
--          if (!streamingDoneSending) { pq_putmessage_noblock('c', NULL, 0);
--  PostgreSQL's own WAL-streaming clients send it that way: receivelog.c
--  18.4:1156-1163 (segment boundary) and :1213-1225 (CheckCopyStreamStop)
--  call PQputCopyEnd while the server is still sending, which is how
--  pg_receivewal and pg_basebackup's background WAL streamer stop.
--
--  The path is reachable inside this library: managed_primary.adb:80-102
--  Await_Feedback loops on Read_Standby_Message, and it runs at :161 and
--  :281 -- before Complete_Copy/Finish_Streaming at :171 and :289 switch to
--  Sessions.Read_Copy_Command, which does classify CopyDone.
--
--  Correct behavior asserted here: a standby CopyDone arriving while the
--  primary reads feedback is reported as end-of-COPY, not as a malformed
--  replication frame.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Server_Sessions;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Repl_3 is

   package Replication renames Flyology.Postgres.Replication;
   package Replication_Sessions renames
     Flyology.Postgres.Replication.Server_Sessions;
   package Sessions renames Flyology.Postgres.Server_Sessions;

   use type Protocol.Frontend_Copy_Kind;
   use type Replication.Stream_Message_Kind;

   Reported_As_Protocol_Error : Boolean := False;
   Reported_Message           : String (1 .. 200) := (others => ' ');
   Reported_Length            : Natural := 0;
   Returned_Normally          : Boolean := False;
   Session_Layer_Sees_Done    : Boolean := False;

   Feedback_First_Works : Boolean := False;

begin
   --  Control: a real StandbyStatusUpdate on the same harness decodes, so the
   --  transport and session wiring are sound.
   declare
      Channel : aliased Memory_Transport;
      Client  : Sessions.Session (Channel'Access);
   begin
      Queue
        (Channel,
         Replication.Make_Standby_Status_Update
           (Received_LSN => 16#0100#,
            Flushed_LSN  => 16#0100#,
            Applied_LSN  => 16#0100#,
            Sent_At      => 0));
      declare
         Feedback : constant Replication.Stream_Message :=
           Replication_Sessions.Read_Standby_Message (Client, 1.0);
      begin
         Feedback_First_Works :=
           Replication.Kind (Feedback) = Replication.Standby_Status_Update;
         Note ("control: a StandbyStatusUpdate decodes as "
               & Replication.Stream_Message_Kind'Image
                   (Replication.Kind (Feedback)));
      end;
   exception
      when E : others =>
         Note ("control failed: " & Ada.Exceptions.Exception_Name (E)
               & ": " & Ada.Exceptions.Exception_Message (E));
   end;

   --  The standby now closes its send direction mid-stream, exactly as
   --  receivelog.c's PQputCopyEnd does at a WAL segment boundary.
   declare
      Channel : aliased Memory_Transport;
      Client  : Sessions.Session (Channel'Access);
   begin
      Queue (Channel, Protocol.Make_Empty_Message ('c'));
      Note ("standby sends a bare CopyDone ('c') while the primary awaits "
            & "feedback");
      declare
         Feedback : constant Replication.Stream_Message :=
           Replication_Sessions.Read_Standby_Message (Client, 1.0);
      begin
         Returned_Normally := True;
         Note ("  Read_Standby_Message returned kind "
               & Replication.Stream_Message_Kind'Image
                   (Replication.Kind (Feedback)));
      end;
   exception
      when E : Protocol.Protocol_Error =>
         Reported_As_Protocol_Error := True;
         declare
            Text : constant String := Ada.Exceptions.Exception_Message (E);
            Size : constant Natural :=
              Natural'Min (Text'Length, Reported_Message'Length);
         begin
            Reported_Length := Size;
            if Size > 0 then
               Reported_Message (1 .. Size) :=
                 Text (Text'First .. Text'First + Size - 1);
            end if;
         end;
         Note ("  Read_Standby_Message raised Protocol_Error: "
               & Reported_Message (1 .. Reported_Length));
      when E : others =>
         Note ("  Read_Standby_Message raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   --  Contrast: the very same bytes are classified as end-of-COPY by the
   --  session layer the completion path uses.
   declare
      Channel : aliased Memory_Transport;
      Client  : Sessions.Session (Channel'Access);
   begin
      Queue (Channel, Protocol.Make_Empty_Message ('c'));
      declare
         Command : constant Protocol.Frontend_Copy_Message :=
           Sessions.Read_Copy_Command (Client, 1.0);
      begin
         Session_Layer_Sees_Done :=
           Protocol.Copy_Kind (Command) = Protocol.Frontend_Copy_Done;
         Note ("contrast: Sessions.Read_Copy_Command classifies the same "
               & "bytes as "
               & Protocol.Frontend_Copy_Kind'Image
                   (Protocol.Copy_Kind (Command)));
      end;
   exception
      when E : others =>
         Note ("contrast failed: " & Ada.Exceptions.Exception_Name (E)
               & ": " & Ada.Exceptions.Exception_Message (E));
   end;

   Check
     (Feedback_First_Works,
      "harness sanity check: a StandbyStatusUpdate is read and decoded");
   Check
     (Session_Layer_Sees_Done,
      "harness sanity check: the session layer classifies the queued frame "
      & "as Frontend_Copy_Done");
   Check
     (not Reported_As_Protocol_Error,
      "a standby-initiated CopyDone is not reported as a malformed "
      & "replication frame (PostgreSQL's walsender answers it with its own "
      & "CopyDone)");
   Check
     (Returned_Normally,
      "the primary can observe end-of-COPY through the feedback-reading API "
      & "instead of unwinding on Protocol_Error");

   Finish;
end Repro_Repl_3;
