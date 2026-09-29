--  CLIENT-2: an extended-protocol COPY IN whose Sync was pipelined before the
--  CopyInResponse is modelled as if the server had honoured that Sync.
--
--  PostgreSQL's copy-in reader (src/backend/commands/copyfromparse.c,
--  CopyGetData) consumes and DISCARDS 'S' (Sync) and 'H' (Flush) while the
--  backend is in copy-in mode: "Ignore Flush/Sync for the convenience of
--  client libraries (such as libpq) that may send those without noticing that
--  the command they just sent was COPY."  The COPY runs inside
--  exec_execute_message, so a Sync written straight after Execute never
--  produces a ReadyForQuery.  Only the Sync that follows CopyDone does.
--
--  That is exactly the sequence libpq uses: PQsendQueryParams writes
--  Parse/Bind/Describe/Execute/Sync in one go, and PQputCopyEnd then writes
--  CopyDone followed by a SECOND Sync ("If we sent the COPY command in
--  extended-query mode, we must issue a Sync as well").  Two Syncs are
--  written; exactly one ReadyForQuery comes back.
--
--  Flyology counts both.  Send_Command increments Pending_Syncs for the first
--  Sync and Enter_Copy records it as Copy_Sync_Pending, so the session ends
--  one ReadyForQuery short and is left permanently in Awaiting_Ready.
--
--  The bytes queued below are exactly what a real backend sends for each
--  sequence; nothing here depends on Memory_Transport behaviour.

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_2 is

   package Client renames Flyology.Postgres.Client;

   use type Protocol.Byte_Offset;
   use type Client.Operation_State;
   use type Protocol.Backend_Message_Kind;

   Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
     (1 => Protocol.Byte (Character'Pos ('I')));

   Chunk : constant Protocol.Byte_Array (1 .. 2) :=
     (Protocol.Byte (Character'Pos ('a')),
      Protocol.Byte (Character'Pos (ASCII.LF)));

   function Copy_In_Response return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_Byte (Contents, 0);     --  overall text format
      Protocol.Append_U16 (Contents, 1);      --  one column
      Protocol.Append_U16 (Contents, 0);      --  column format text
      return Protocol.Make_Message
        ('G', Flyology.Bytes.To_Array (Contents));
   end Copy_In_Response;

   function Command_Complete return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, "COPY 1");
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
      Clear_Sent (Channel);
   end Start;

   function Frontend_Tags (Channel : Memory_Transport) return String is
      --  Tag byte + 4-byte self-inclusive length + payload, repeated.
      Data   : constant Protocol.Byte_Array := Sent (Channel);
      Result : String (1 .. Natural (Data'Length));
      Used   : Natural := 0;
      Cursor : Protocol.Byte_Offset := Data'First;
      Length : Natural;
   begin
      while Cursor + 4 <= Data'Last loop
         Used := Used + 1;
         Result (Used) := Character'Val (Data (Cursor));
         Length :=
           Natural (Data (Cursor + 1)) * 16_777_216
           + Natural (Data (Cursor + 2)) * 65_536
           + Natural (Data (Cursor + 3)) * 256
           + Natural (Data (Cursor + 4));
         exit when Length < 4;
         Cursor := Cursor + Protocol.Byte_Offset (Length) + 1;
      end loop;
      return Result (1 .. Used);
   end Frontend_Tags;

   procedure Begin_Copy_In
     (Item : in out Client.Session; Channel : in out Memory_Transport) is
      --  Prepare/Bind/Execute/Sync, then read the CopyInResponse: the libpq
      --  ordering.  Synchronize is accepted here and Receive_Extended_Event
      --  accepts Awaiting_Ready, so this is a permitted use of the API.
   begin
      Client.Prepare_Statement
        (Item, "c", "copy t from stdin", Timeout => 1.0);
      Client.Bind_Portal (Item, "", "c", Timeout => 1.0);
      Client.Execute_Portal (Item, "", Timeout => 1.0);
      Client.Synchronize (Item, Timeout => 1.0);
      Queue (Channel, Copy_In_Response);
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Item, Timeout => 1.0);
      begin
         Check
           (Protocol.Response_Kind (Event) = Protocol.Copy_In_Response
            and then Client.State (Item) = Client.Copy_In_Active,
            "the extended COPY IN starts from CopyInResponse");
      end;
   end Begin_Copy_In;

begin
   ------------------------------------------------------------------
   --  (a) The libpq sequence: Sync after Execute, Sync after CopyDone.
   ------------------------------------------------------------------
   Note ("(a) Execute, Sync, CopyData, CopyDone, Sync -- the libpq order");
   declare
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Blocked : Boolean := False;
   begin
      Start (Session, Channel);
      Begin_Copy_In (Session, Channel);

      Client.Send_Copy_Data (Session, Chunk, Timeout => 1.0);
      Client.Finish_Copy (Session, Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Note ("frontend tags written: " & Frontend_Tags (Channel));
      Note
        ("Pending_Synchronizations after both Syncs ="
         & Client.Pending_Synchronizations (Session)'Image
         & " (the server discarded the first Sync, so one "
         & "ReadyForQuery is owed)");

      --  What a real backend now sends: CommandComplete, then exactly one
      --  ReadyForQuery (for the Sync that followed CopyDone).
      Queue (Channel, Command_Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));

      declare
         Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, Timeout => 1.0);
      begin
         Check
           (Protocol.Response_Kind (Event) =
              Protocol.Command_Complete_Response,
            "CommandComplete ends the COPY");
      end;
      declare
         Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, Timeout => 1.0);
      begin
         Check
           (Protocol.Response_Kind (Event) =
              Protocol.Ready_For_Query_Response,
            "the single ReadyForQuery is delivered");
      end;

      Note
        ("after the exchange: state = " & Client.State (Session)'Image
         & ", pending =" & Client.Pending_Synchronizations (Session)'Image
         & ", unconsumed backend bytes ="
         & Natural'Image (Bytes_Remaining (Channel)));

      Check
        (Bytes_Remaining (Channel) = 0,
         "the whole server response was consumed");
      Check
        (Client.Pending_Synchronizations (Session) = 0,
         "no ReadyForQuery remains outstanding: the server discarded the "
         & "Sync it received while in copy-in mode");
      Check
        (Client.Is_Ready (Session),
         "the COPY IN batch leaves the session ready for the next command");

      --  Consequence: nothing but Terminate is accepted any more.
      begin
         Client.Prepare_Statement
           (Session, "next", "select 1", Timeout => 1.0);
      exception
         when Error : Program_Error =>
            Blocked := True;
            Note
              ("Prepare_Statement raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Blocked,
         "a following command is accepted after the COPY IN batch");
      Note
        ("on a real socket the phantom outstanding batch also makes the "
         & "next Receive_Extended_Event block until Timeout_Error");
   end;

   ------------------------------------------------------------------
   --  (b) The caller trusts Pending_Synchronizations and sends no
   --      second Sync.  The backend is then waiting for a message
   --      that no API call can send.
   ------------------------------------------------------------------
   Note ("(b) Execute, Sync, CopyData, CopyDone -- no second Sync");
   declare
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Blocked : Boolean := False;
   begin
      Start (Session, Channel);
      Begin_Copy_In (Session, Channel);

      Client.Send_Copy_Data (Session, Chunk, Timeout => 1.0);
      Client.Finish_Copy (Session, Timeout => 1.0);
      Note ("frontend tags written: " & Frontend_Tags (Channel));

      --  A real backend completes the COPY and then waits for a message:
      --  the only Sync it saw was swallowed by CopyGetData.
      Queue (Channel, Command_Complete);
      declare
         Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, Timeout => 1.0);
      begin
         Check
           (Protocol.Response_Kind (Event) =
              Protocol.Command_Complete_Response,
            "CommandComplete ends the COPY");
      end;

      Note
        ("after CommandComplete: state = " & Client.State (Session)'Image
         & ", pending =" & Client.Pending_Synchronizations (Session)'Image);
      Check
        (Client.Pending_Synchronizations (Session) = 0,
         "the discarded Sync is not counted as outstanding");

      --  The server is waiting for Sync.  A correct model lets the caller
      --  send it; the current one reports a Sync already pending and then
      --  refuses to write one.
      begin
         Client.Synchronize (Session, Timeout => 1.0);
      exception
         when Error : Program_Error =>
            Blocked := True;
            Note
              ("Synchronize raised Program_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Check
        (not Blocked,
         "the Sync the backend is waiting for can still be written; "
         & "otherwise the session can only be discarded");
   end;

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_2;
