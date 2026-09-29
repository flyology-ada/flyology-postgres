--  CLIENT-5: Portal_Is_Suspended is one session-wide Boolean carrying no
--  portal name, so a PortalSuspended for one portal blocks Execute_Portal of
--  every other bound portal, and binding another portal forgets that the
--  first one is still suspended server-side.
--
--    Execute_Portal:  if Item.Portal_Is_Suspended then
--                        raise Program_Error with
--                          "use Resume_Portal for a suspended portal";
--    Bind_Portal:     Item.Portal_Is_Suspended := False;
--    Resume_Portal:   if Item.Current_State /= Extended_Query_Active
--                       or else not Item.Portal_Is_Suspended then
--                        raise Program_Error ...
--
--  Both sequences below are legal extended-query traffic inside one
--  Flush-driven batch, which client.ads describes as the resumable case
--  ("Sync ends the batch that owns the portal, so only a batch whose
--  responses arrive through Flush can be resumed").

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_5 is

   package Client renames Flyology.Postgres.Client;

   use type Protocol.Backend_Message_Kind;

   Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
     (1 => Protocol.Byte (Character'Pos ('I')));

   function Single_Column_Row return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_U32 (Contents, 1);
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('1')));
      return Protocol.Make_Message
        ('D', Flyology.Bytes.To_Array (Contents));
   end Single_Column_Row;

   function Command_Complete return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, "SELECT 1");
      return Protocol.Make_Message
        ('C', Flyology.Bytes.To_Array (Contents));
   end Command_Complete;

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
      Client.Prepare_Statement (Item, "s", "select 1", Timeout => 1.0);
   end Start;

   procedure Drain
     (Item : in out Client.Session; Channel : in out Memory_Transport) is
   begin
      while Bytes_Remaining (Channel) > 0 loop
         declare
            Event : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Item, Timeout => 1.0);
         begin
            if Protocol.Response_Kind (Event) =
              Protocol.Portal_Suspended_Response
            then
               Note ("PortalSuspended received");
            end if;
         end;
      end loop;
   end Drain;

begin
   ------------------------------------------------------------------
   --  (a) Two portals bound in one batch; the first suspends, so the
   --      second - bound, never executed - cannot be executed.
   ------------------------------------------------------------------
   Note ("(a) Bind p1, Bind p2, Execute p1 (Maximum_Rows => 1), Flush");
   declare
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Refused : Boolean := False;
   begin
      Start (Session, Channel);
      Client.Bind_Portal (Session, "p1", "s", Timeout => 1.0);
      Client.Bind_Portal (Session, "p2", "s", Timeout => 1.0);
      Client.Execute_Portal
        (Session, "p1", Maximum_Rows => 1, Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);

      Queue (Channel, Protocol.Make_Empty_Message ('1'));  --  Parse
      Queue (Channel, Protocol.Make_Empty_Message ('2'));  --  Bind p1
      Queue (Channel, Protocol.Make_Empty_Message ('2'));  --  Bind p2
      Queue (Channel, Single_Column_Row);
      Queue (Channel, Protocol.Make_Empty_Message ('s'));  --  PortalSuspended
      Drain (Session, Channel);

      begin
         Client.Execute_Portal (Session, "p2", Timeout => 1.0);
      exception
         when Error : Program_Error =>
            Refused := True;
            Note
              ("Execute_Portal (""p2"") raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Refused,
         "a bound, never executed portal can be executed while another "
         & "portal of the same batch is suspended");
   end;

   ------------------------------------------------------------------
   --  (b) Binding and running a second portal forgets that the first
   --      one is still suspended, so Resume_Portal is refused.
   ------------------------------------------------------------------
   Note ("(b) Execute p1 to suspension, then bind and run p2, then resume p1");
   declare
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Refused : Boolean := False;
   begin
      Start (Session, Channel);
      Client.Bind_Portal (Session, "p1", "s", Timeout => 1.0);
      Client.Execute_Portal
        (Session, "p1", Maximum_Rows => 1, Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);

      Queue (Channel, Protocol.Make_Empty_Message ('1'));  --  Parse
      Queue (Channel, Protocol.Make_Empty_Message ('2'));  --  Bind p1
      Queue (Channel, Single_Column_Row);
      Queue (Channel, Protocol.Make_Empty_Message ('s'));  --  PortalSuspended
      Drain (Session, Channel);

      Client.Bind_Portal (Session, "p2", "s", Timeout => 1.0);
      Client.Execute_Portal (Session, "p2", Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Empty_Message ('2'));  --  Bind p2
      Queue (Channel, Single_Column_Row);
      Queue (Channel, Command_Complete);
      Drain (Session, Channel);

      begin
         Client.Resume_Portal (Session, "p1", Timeout => 1.0);
      exception
         when Error : Program_Error =>
            Refused := True;
            Note
              ("Resume_Portal (""p1"") raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Refused,
         "a portal suspended earlier in the same Flush-driven batch can "
         & "still be resumed after another portal ran");
   end;

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_5;
