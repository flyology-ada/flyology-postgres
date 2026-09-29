--  CLIENT-3: the scoped Send_Query overload has no pipeline-mode check.
--
--  Synchronous Send_Query (client.adb) starts with
--     if Item.Pipelined then
--        raise Program_Error with
--          "simple queries are not allowed in Postgres pipeline mode";
--  and Send_Command repeats the same rejection for a raw Query message.  The
--  scoped overload checks only Item.Current_State /= Ready, so it writes the
--  Query and moves the session to Simple_Query_Active with Pipelined still
--  True.
--
--  Contract: Enter_Pipeline_Mode (client.ads) and README "Pipelined batches"
--  both state "Simple queries are rejected while the mode is active".

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Operations;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_3 is

   package Client renames Flyology.Postgres.Client;

   use type Protocol.Byte;
   use type Client.Operation_State;

   Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
     (1 => Protocol.Byte (Character'Pos ('I')));

   Channel : aliased Memory_Transport;
   Session : aliased Client.Session (Channel'Access);
   Set     : aliased Operations.Completion_Set (Capacity => 1);

   Authentication : Flyology.Bytes.Unbounded_Bytes;
   Rejected       : Boolean;

   function Wrote_A_Query return Boolean is
      Data : constant Protocol.Byte_Array := Sent (Channel);
   begin
      return Data'Length > 0
        and then Data (Data'First) = Protocol.Byte (Character'Pos ('Q'));
   end Wrote_A_Query;

begin
   Protocol.Append_U32 (Authentication, 0);
   Queue
     (Channel,
      Protocol.Make_Message ('R', Flyology.Bytes.To_Array (Authentication)));
   Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
   Client.Startup (Session, User => "tester", Timeout => 1.0);
   Client.Enter_Pipeline_Mode (Session);
   Clear_Sent (Channel);

   --  Control: the synchronous overload rejects the call.
   Rejected := False;
   begin
      Client.Send_Query (Session, "select 1", Timeout => 1.0);
   exception
      when Error : Program_Error =>
         Rejected := True;
         Note
           ("synchronous Send_Query raised Program_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;
   Check
     (Rejected,
      "control: the synchronous Send_Query rejects a simple query in "
      & "pipeline mode");
   Check
     (not Wrote_A_Query,
      "control: the rejected synchronous call wrote nothing");

   --  The scoped overload, same session, same state.
   Rejected := False;
   begin
      declare
         Send : Client.Send_Operation :=
           Client.Send_Query
             (Set'Access, Session'Access, "select 1", Timeout => 1.0);
      begin
         Operations.Wait_All (Set);
         Client.Finish (Send);
      end;
   exception
      when Error : Program_Error =>
         Rejected := True;
         Note
           ("scoped Send_Query raised Program_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   Note
     ("after the scoped call: state = " & Client.State (Session)'Image
      & ", In_Pipeline_Mode = " & Client.In_Pipeline_Mode (Session)'Image
      & ", frontend bytes written =" & Sent (Channel)'Length'Image);

   Check
     (Rejected,
      "the scoped Send_Query rejects a simple query in pipeline mode "
      & "(Enter_Pipeline_Mode: 'Simple queries are rejected while the mode "
      & "is active')");
   Check
     (not Wrote_A_Query,
      "no Query message reaches the wire while pipeline mode is active");
   Check
     (Client.State (Session) = Client.Ready,
      "the refused simple query leaves the session state untouched");

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_3;
