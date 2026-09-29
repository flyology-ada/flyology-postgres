--  CLIENT-1: the scoped receive path derives its "an earlier batch owns this
--  response" flag from the session STATE
--    (client.adb, Start_Receive: Operation.Sync_Pending :=
--     Item.Current_State = Awaiting_Ready)
--  while the synchronous path derives it from the outstanding Sync COUNT
--    (client.adb, Receive_Extended_Event:
--     Sync_Pending : constant Boolean := Item.Pending_Syncs > 0).
--
--  In pipeline mode the two differ exactly when a later batch is already open
--  while an earlier batch is still outstanding: writing batch 2's Parse/Bind
--  moves the state from Awaiting_Ready to Extended_Query_Active but leaves
--  Pending_Syncs > 0.  Batch 1's ErrorResponse then wrongly puts the open
--  batch 2 into Recovery_Required on the scoped path.
--
--  README "Pipelined batches": "Each batch's own Sync contains its failure:
--  ... so the session does not enter Recovery_Required."

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Operations;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_1 is

   package Client renames Flyology.Postgres.Client;

   use type Client.Operation_State;
   use type Protocol.Backend_Message_Kind;

   Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
     (1 => Protocol.Byte (Character'Pos ('I')));

   --  ErrorResponse payload: field 'M' with text "x", then the terminator.
   Failure : constant Protocol.Byte_Array (1 .. 4) :=
     (1 => Protocol.Byte (Character'Pos ('M')),
      2 => Protocol.Byte (Character'Pos ('x')),
      3 => 0,
      4 => 0);

   procedure Start
     (Item : in out Client.Session; Channel : in out Memory_Transport) is
      Authentication : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Authentication, 0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Item, User => "tester", Timeout => 1.0);
   end Start;

   procedure Write_Two_Batches (Item : in out Client.Session) is
      --  Batch 1 is written and Sync-terminated; batch 2 is opened but its
      --  Sync has not been written yet.  Both are valid pipeline traffic.
   begin
      Client.Enter_Pipeline_Mode (Item);
      Client.Prepare_Statement (Item, "first", "select 1", Timeout => 1.0);
      Client.Bind_Portal (Item, "first", "first", Timeout => 1.0);
      Client.Execute_Portal (Item, "first", Timeout => 1.0);
      Client.Synchronize (Item, Timeout => 1.0);
      Client.Prepare_Statement (Item, "second", "select 1", Timeout => 1.0);
      Client.Bind_Portal (Item, "second", "second", Timeout => 1.0);
   end Write_Two_Batches;

begin
   --  Control: the identical byte sequence through the synchronous receive.
   declare
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Kind    : Protocol.Backend_Message_Kind;
   begin
      Start (Session, Channel);
      Write_Two_Batches (Session);
      Queue (Channel, Protocol.Make_Message ('E', Failure));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         Kind := Protocol.Response_Kind (Event);
      end;
      Note
        ("synchronous receive: kind = " & Kind'Image
         & ", state = " & Client.State (Session)'Image
         & ", pending =" & Client.Pending_Synchronizations (Session)'Image);
      Check
        (Kind = Protocol.Error_Response
         and then Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 1,
         "control: the synchronous receive leaves the open batch active");
   end;

   --  The scoped (Flyology.Operations) receive path, same bytes.
   declare
      Channel : aliased Memory_Transport;
      Session : aliased Client.Session (Channel'Access);
      Set     : aliased Operations.Completion_Set (Capacity => 1);
      Kind    : Protocol.Backend_Message_Kind;
      Refused : Boolean := False;
   begin
      Start (Session, Channel);
      Write_Two_Batches (Session);
      Queue (Channel, Protocol.Make_Message ('E', Failure));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));

      declare
         Receive : Client.Receive_Operation :=
           Client.Receive_Extended_Event
             (Set'Access, Session'Access, Timeout => 1.0);
         Event : Protocol.Backend_Message;
      begin
         Operations.Wait_All (Set);
         Client.Finish (Receive, Event);
         Kind := Protocol.Response_Kind (Event);
      end;

      Note
        ("scoped receive:      kind = " & Kind'Image
         & ", state = " & Client.State (Session)'Image
         & ", pending =" & Client.Pending_Synchronizations (Session)'Image);

      Check
        (Kind = Protocol.Error_Response,
         "the scoped receive returns batch 1's ErrorResponse");
      Check
        (Client.Pending_Synchronizations (Session) = 1,
         "batch 1's ReadyForQuery is still outstanding");
      Check
        (Client.State (Session) = Client.Extended_Query_Active,
         "an earlier pipelined batch's ErrorResponse does not put the open "
         & "batch into Recovery_Required (README: 'the session does not "
         & "enter Recovery_Required')");

      --  Consequence 1: the open batch's already bound portal is refused.
      begin
         Client.Execute_Portal (Session, "second", Timeout => 1.0);
      exception
         when Error : Program_Error =>
            Refused := True;
            Note
              ("Execute_Portal (""second"") raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Refused,
         "the open batch's bound portal can still be executed");

      --  Consequence 2: batch 1's ReadyForQuery is the next byte on the wire
      --  but cannot be received any more.
      Refused := False;
      begin
         declare
            Event : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Session, Timeout => 1.0);
         begin
            Kind := Protocol.Response_Kind (Event);
         end;
      exception
         when Error : Program_Error =>
            Refused := True;
            Kind := Protocol.Unknown_Response;
            Note
              ("the follow-up receive raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Refused and then Kind = Protocol.Ready_For_Query_Response,
         "batch 1's ReadyForQuery can still be consumed");
   end;

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_1;
