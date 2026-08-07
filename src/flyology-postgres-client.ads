with Flyology.Bytes;
with Flyology.IO.TLS;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Client is
   --  Stateful PostgreSQL frontend implementing startup, authentication,
   --  simple and extended queries, COPY, cancellation, and TLS negotiation.

   Database_Error : exception;
   --  Raised when the server returns an ErrorResponse for an operation.
   Unsupported_Authentication : exception;
   --  Raised when the server requests an unsupported authentication method.
   TLS_Not_Available : exception;
   --  Raised when SSLRequest is refused or TLS cannot be negotiated.

   type Session
     (Channel : not null access Transports.Transport'Class) is limited private;
   --  One stateful PostgreSQL connection over a caller-owned transport.
   --  @field Channel Open transport whose lifetime exceeds the session.

   type Operation_State is
     (Not_Started,
      Ready,
      Simple_Query_Active,
      Extended_Query_Active,
      Copy_In_Active,
      Copy_Out_Active,
      Copy_Both_Active,
      Copy_Completion_Active,
      Recovery_Required,
      Awaiting_Ready,
      Closed);
   --  Client protocol state controlling which operations are currently legal.
   --  @enum Not_Started No startup packet has been sent.
   --  @enum Ready Startup or synchronization completed; commands may begin.
   --  @enum Simple_Query_Active A simple-query response is being consumed.
   --  @enum Extended_Query_Active An extended-query cycle is in progress.
   --  @enum Copy_In_Active Client-to-server COPY data may be sent.
   --  @enum Copy_Out_Active Server-to-client COPY data is being received.
   --  @enum Copy_Both_Active Bidirectional COPY data may be exchanged.
   --  @enum Copy_Completion_Active COPY completion responses remain pending.
   --  @enum Recovery_Required An extended-query error requires Synchronize.
   --  @enum Awaiting_Ready A terminal response is pending ReadyForQuery.
   --  @enum Closed The server or client has terminated the session.

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      --  Password is consumed as its exact String octets. No SASLprep or
      --  Unicode normalization is performed by this library.
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection);
   --  Perform plaintext PostgreSQL startup and complete authentication.
   --  Password is consumed as exact String octets; no SASLprep or Unicode
   --  normalization is performed.
   --  @param Item New session in Not_Started state.
   --  @param User PostgreSQL role name sent in the startup packet.
   --  @param Database Database name, or empty to let the server choose.
   --  @param Password Credential used by cleartext or SCRAM authentication.
   --  @param Application_Name Value reported to the server for observability.
   --  @param Timeout Per-message startup and authentication timeout.
   --  @param Replication_Mode Normal, database replication, or true
   --     replication startup parameter.
   --  @exception Database_Error The server rejects startup or authentication.
   --  @exception Unsupported_Authentication The requested method is unknown.

   procedure Startup_TLS
     (Item             : in out Session;
      Backend          : in out Flyology.IO.TLS.Provider'Class;
      Server_Name      : String;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection);
   --  Require SSLRequest negotiation, then perform startup over verified TLS.
   --  Refusal is terminal and never falls back to plaintext; PostgreSQL's
   --  separate sslnegotiation=direct mode is not supported.
   --  @param Item New session over a TLS-upgradable transport.
   --  @param Backend TLS implementation and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param User PostgreSQL role name sent in the startup packet.
   --  @param Database Database name, or empty to let the server choose.
   --  @param Password Exact credential octets; no SASLprep is performed.
   --  @param Application_Name Value reported to the server for observability.
   --  @param Timeout Per-message negotiation and startup timeout.
   --  @param Replication_Mode Requested connection mode.
   --  @exception TLS_Not_Available SSLRequest is refused or TLS fails.
   --  @exception Database_Error The server rejects startup or authentication.

   procedure Send_Command
     (Item    : in out Session;
      Command : Protocol.Message;
      Timeout : Duration := 30.0);
   --  Send an already encoded frontend message and update Item's state for
   --  recognized query, extended-query, COPY, synchronization, or termination
   --  tags.
   --  @param Item Started session to write.
   --  @param Command Complete frontend protocol message.
   --  @param Timeout Maximum time allowed for the write.
   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0);
   --  Start a simple-query cycle for SQL.
   --  @param Item Ready session, transitioned to Simple_Query_Active.
   --  @param SQL One or more SQL statements encoded as a Query message.
   --  @param Timeout Maximum time allowed for the write.

   procedure Send_Cancel_Request
     (Item                 : Session;
      Cancellation_Channel : in out Transports.Transport'Class;
      Timeout              : Duration := 30.0);
   --  Send Item's cancellation credentials on a caller-opened distinct
   --  transport. The server replies only by closing that transport; callers
   --  close it after return and continue reading the active query session.
   --  @param Item Active session whose stored backend credentials are used.
   --  @param Cancellation_Channel Separate connection to the same server.
   --  @param Timeout Maximum time allowed to send the cancellation packet.
   function Receive_Message
     (Item : in out Session; Timeout : Duration := 30.0)
      return Protocol.Message;
   --  Receive one raw backend message without interpreting query sequencing.
   --  @param Item Started session to read.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return Next complete backend protocol message.

   subtype Simple_Query_Event is Protocol.Backend_Message;
   --  Typed backend event produced while consuming a simple-query cycle.
   function Receive_Query_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Simple_Query_Event;
   --  Receive one owned event for the active simple query. Continue until
   --  Ready_For_Query_Response; rows are not accumulated by the session.
   --  @param Item Session in Simple_Query_Active or Awaiting_Ready state.
   --  @param Timeout Maximum time allowed for the complete event.
   --  @return Next typed simple-query event.

   procedure Prepare_Statement
     (Item            : in out Session;
      Statement_Name  : String;
      SQL             : String;
      Parameter_Types : Protocol.Oid_Array := Protocol.No_Oids;
      Timeout         : Duration := 30.0);
   --  Send Parse for a named or unnamed prepared statement.
   --  @param Item Ready session beginning an extended-query cycle.
   --  @param Statement_Name Empty for the unnamed statement, otherwise name.
   --  @param SQL SQL text containing positional parameters when required.
   --  @param Parameter_Types Optional explicit type OIDs for parameters.
   --  @param Timeout Maximum time allowed for the write.
   procedure Bind_Portal
     (Item           : in out Session;
      Portal_Name    : String;
      Statement_Name : String;
      Parameters     : Protocol.Bind_Parameter_Array :=
        Protocol.No_Parameters;
      Result_Formats : Protocol.Field_Format_Array := Protocol.No_Formats;
      Timeout        : Duration := 30.0);
   --  Bind parameters and result formats to a portal.
   --  @param Item Session in an extended-query cycle.
   --  @param Portal_Name Empty for the unnamed portal, otherwise name.
   --  @param Statement_Name Prepared statement to bind.
   --  @param Parameters Parameter values in statement order.
   --  @param Result_Formats Zero, one, or one-per-column format codes.
   --  @param Timeout Maximum time allowed for the write.
   procedure Describe_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0);
   --  Request parameter and row metadata for a prepared statement.
   --  @param Item Session in an extended-query cycle.
   --  @param Statement_Name Prepared statement to describe.
   --  @param Timeout Maximum time allowed for the write.
   procedure Describe_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0);
   --  Request row metadata for a bound portal.
   --  @param Item Session in an extended-query cycle.
   --  @param Portal_Name Portal to describe.
   --  @param Timeout Maximum time allowed for the write.
   procedure Execute_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0);
   --  Execute a portal for at most Maximum_Rows rows.
   --  @param Item Session in an extended-query cycle.
   --  @param Portal_Name Bound portal to execute.
   --  @param Maximum_Rows Zero for all rows, otherwise a suspension limit.
   --  @param Timeout Maximum time allowed for the write.
   procedure Resume_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0);
   --  Continue a portal after PortalSuspended.
   --  @param Item Session with a suspended portal in the current cycle.
   --  @param Portal_Name Suspended portal to continue.
   --  @param Maximum_Rows Zero for all remaining rows, otherwise a new limit.
   --  @param Timeout Maximum time allowed for the write.
   procedure Close_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0);
   --  Close a prepared statement in the current extended-query cycle.
   --  @param Item Session in an extended-query cycle.
   --  @param Statement_Name Prepared statement to close.
   --  @param Timeout Maximum time allowed for the write.
   procedure Close_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0);
   --  Close a bound portal in the current extended-query cycle.
   --  @param Item Session in an extended-query cycle.
   --  @param Portal_Name Portal to close.
   --  @param Timeout Maximum time allowed for the write.
   procedure Flush
     (Item : in out Session; Timeout : Duration := 30.0);
   --  Ask the server to flush pending extended-query responses immediately.
   --  @param Item Session in an extended-query cycle.
   --  @param Timeout Maximum time allowed for the write.
   procedure Synchronize
     (Item : in out Session; Timeout : Duration := 30.0);
   --  End or recover an extended-query cycle by sending Sync.
   --  @param Item Active or recovery-required extended-query session.
   --  @param Timeout Maximum time allowed for the write.

   subtype Extended_Query_Event is Protocol.Backend_Message;
   --  Typed backend event produced during an extended-query cycle.
   function Receive_Extended_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Extended_Query_Event;
   --  Receive and validate one extended-query response event.
   --  @param Item Session in an extended-query or recovery state.
   --  @param Timeout Maximum time allowed for the complete event.
   --  @return Next typed event, updating Item's protocol state.

   subtype Copy_Event is Protocol.Backend_Message;
   --  Typed backend event produced while COPY is active or completing.
   procedure Send_Copy_Data
     (Item : in out Session;
      Data : Protocol.Byte_Array;
      Timeout : Duration := 30.0);
   --  Send one CopyData payload during COPY IN or COPY BOTH.
   --  @param Item Session whose copy send direction is open.
   --  @param Data Raw COPY payload bytes.
   --  @param Timeout Maximum time allowed for the write.
   procedure Finish_Copy
     (Item : in out Session; Timeout : Duration := 30.0);
   --  Finish the client-to-server COPY direction with CopyDone.
   --  @param Item Session whose copy send direction is open.
   --  @param Timeout Maximum time allowed for the write.
   procedure Abort_Copy
     (Item : in out Session;
      Reason : String;
      Timeout : Duration := 30.0);
   --  Abort COPY IN by sending CopyFail with a diagnostic reason.
   --  @param Item Session whose copy send direction is open.
   --  @param Reason Human-readable failure text sent to the server.
   --  @param Timeout Maximum time allowed for the write.
   function Receive_Copy_Event
     (Item    : in out Session;
      Timeout : Duration := 30.0;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Copy_Event;
   --  Receive one event while COPY is active or completing.
   --  @param Item Session in a COPY-related state.
   --  @param Timeout Maximum time allowed for the complete event.
   --  @param On_Wait Observer notified while the event is still arriving.  A
   --     replication stream needs this: a primary packs pending WAL into a
   --     single XLogData of up to 128 kB, and a standby that stays silent for
   --     the whole of it is terminated once assembly outlasts
   --     wal_sender_timeout.  The observer may send on Item's channel.
   --  @return Next typed COPY or completion event.

   function Is_Ready (Item : Session) return Boolean;
   --  Test whether Item may begin a new command cycle.
   --  @param Item Session to inspect.
   --  @return True exactly when State (Item) is Ready.
   function State (Item : Session) return Operation_State;
   --  Return Item's current protocol state.
   --  @param Item Session to inspect.
   --  @return Current operation state.
   function Backend_Process_Id (Item : Session) return Protocol.UInt32;
   --  Return the process identifier received in BackendKeyData.
   --  @param Item Authenticated session.
   --  @return Server process identifier used for cancellation.
   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array;
   --  Return a copy of the secret received in BackendKeyData.
   --  @param Item Authenticated session.
   --  @return Cancellation secret bytes; callers should avoid logging them.

   function Error_Message (Value : Protocol.Message) return String;
   --  Extract the human-readable primary text from ErrorResponse.
   --  @param Value Backend ErrorResponse message.
   --  @return Message field, or an empty string when absent.
   function SQL_State (Value : Protocol.Message) return String;
   --  Extract the five-character SQLSTATE from ErrorResponse.
   --  @param Value Backend ErrorResponse message.
   --  @return SQLSTATE field, or an empty string when absent.

private
   type Copy_Origin is (No_Copy, Simple_Copy, Extended_Copy);

   type Session
     (Channel : not null access Transports.Transport'Class) is limited record
      Current_State : Operation_State := Not_Started;
      Has_Row_Description : Boolean := False;
      Described_Columns : Natural := 0;
      Bound_In_Cycle : Boolean := False;
      Portal_Is_Suspended : Boolean := False;
      Current_Copy_Origin : Copy_Origin := No_Copy;
      Copy_Send_Open : Boolean := False;
      Copy_Receive_Open : Boolean := False;
      Copy_Bidirectional : Boolean := False;
      Copy_Sync_Pending : Boolean := False;
      Pid     : Protocol.UInt32 := 0;
      Secret  : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Client;
