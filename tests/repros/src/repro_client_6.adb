--  CLIENT-6: a rejected plaintext startup leaves the session in Not_Started,
--  so a retry is accepted and writes a second startup packet to a connection
--  the server has already closed.
--
--  Startup_TLS wraps its whole sequence in
--     exception when others => Item.Current_State := Closed; raise;
--  and the scoped Fail_Startup closes only the TLS stage
--     if Item.Kind = TLS_Negotiation_Stage then
--        Item.Item.Current_State := Closed;
--     end if;
--  while Complete_Startup's 'E' branch just raises Database_Error, leaving
--  Current_State = Not_Started.  Complete_Startup then accepts a new Startup
--  (Item.Current_State not in Not_Started | TLS_Negotiated).
--
--  After an authentication ErrorResponse the server closes the connection, so
--  the documented Closed state ("The server or client has terminated the
--  session", client.ads) is the accurate one, as it already is for TLS.

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Operations;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_6 is

   package Client renames Flyology.Postgres.Client;

   use type Protocol.Byte_Offset;
   use type Client.Operation_State;

   function Authentication_Failure return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('S')));
      Protocol.Append_C_String (Contents, "FATAL");
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('C')));
      Protocol.Append_C_String (Contents, "28P01");
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('M')));
      Protocol.Append_C_String
        (Contents, "password authentication failed for user ""tester""");
      Protocol.Append_Byte (Contents, 0);
      return Protocol.Make_Message
        ('E', Flyology.Bytes.To_Array (Contents));
   end Authentication_Failure;

begin
   ------------------------------------------------------------------
   --  Synchronous Startup.
   ------------------------------------------------------------------
   declare
      Channel  : aliased Memory_Transport;
      Session  : Client.Session (Channel'Access);
      Rejected : Boolean := False;
      Retried  : Boolean := False;
   begin
      Queue (Channel, Authentication_Failure);
      begin
         Client.Startup (Session, User => "tester", Timeout => 1.0);
      exception
         when Error : Client.Database_Error =>
            Rejected := True;
            Note
              ("Startup raised Database_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check (Rejected, "the server's ErrorResponse fails the startup");

      Note
        ("after the rejected startup: state = "
         & Client.State (Session)'Image
         & ", Is_Ready = " & Client.Is_Ready (Session)'Image);
      Check
        (Client.State (Session) = Client.Closed,
         "a rejected startup closes the session state, as Startup_TLS does "
         & "for the same failure");

      --  A retry must not write to a connection the server already closed.
      --  The exception the retry finally raises comes from the exhausted
      --  memory transport, not from the session: the startup packet is
      --  written first.
      Clear_Sent (Channel);
      begin
         Client.Startup (Session, User => "tester", Timeout => 1.0);
         Retried := True;
      exception
         when Error : others =>
            Note
              ("the retried Startup raised "
               & Ada.Exceptions.Exception_Name (Error) & ": "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      pragma Unreferenced (Retried);
      Note
        ("bytes written by the retried Startup ="
         & Protocol.Byte_Offset'Image (Sent (Channel)'Length));
      Check
        (Sent (Channel)'Length = 0,
         "a rejected session refuses another Startup instead of writing a "
         & "second startup packet to a connection the server has closed");
   end;

   ------------------------------------------------------------------
   --  Scoped Startup: same failure, same state.
   ------------------------------------------------------------------
   declare
      Channel  : aliased Memory_Transport;
      Session  : aliased Client.Session (Channel'Access);
      Set      : aliased Operations.Completion_Set (Capacity => 1);
      Rejected : Boolean := False;
   begin
      Queue (Channel, Authentication_Failure);
      declare
         Start : Client.Startup_Operation :=
           Client.Startup
             (Set'Access, Session'Access, User => "tester", Timeout => 1.0);
      begin
         Operations.Wait_All (Set);
         begin
            Client.Finish (Start);
         exception
            when Error : Client.Database_Error =>
               Rejected := True;
               Note
                 ("scoped Finish raised Database_Error: "
                  & Ada.Exceptions.Exception_Message (Error));
         end;
      end;
      Check (Rejected, "the scoped startup reports the same failure");
      Note
        ("after the rejected scoped startup: state = "
         & Client.State (Session)'Image);
      Check
        (Client.State (Session) = Client.Closed,
         "the scoped startup closes the session state too");
   end;

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_6;
