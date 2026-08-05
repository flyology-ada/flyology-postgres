with Flyology.Bytes;
with Flyology.IO.TLS;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Client is

   Database_Error : exception;
   Unsupported_Authentication : exception;
   TLS_Not_Available : exception;

   type Session
     (Channel : not null access Transports.Transport'Class) is limited private;

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

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      --  Password is consumed as its exact String octets. No SASLprep or
      --  Unicode normalization is performed by this library.
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0);

   --  Require PostgreSQL SSLRequest negotiation before startup. Backend
   --  verifies both the server certificate chain and Server_Name. Refusal is
   --  terminal; this procedure never falls back to plaintext. PostgreSQL's
   --  separate sslnegotiation=direct mode is not supported.
   procedure Startup_TLS
     (Item             : in out Session;
      Backend          : in out Flyology.IO.TLS.Provider'Class;
      Server_Name      : String;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0);

   procedure Send_Command
     (Item    : in out Session;
      Command : Protocol.Message;
      Timeout : Duration := 30.0);
   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0);
   --  Send a cancellation packet on a caller-opened distinct transport.
   --  The server replies only by closing that transport; callers must close it
   --  after this procedure returns and keep reading the active query session.
   procedure Send_Cancel_Request
     (Item                 : Session;
      Cancellation_Channel : in out Transports.Transport'Class;
      Timeout              : Duration := 30.0);
   function Receive_Message
     (Item : in out Session; Timeout : Duration := 30.0)
      return Protocol.Message;

   subtype Simple_Query_Event is Protocol.Backend_Message;
   --  Receive one owned typed event for the active simple query. Continue
   --  until Ready_For_Query_Response; rows are not accumulated by the session.
   function Receive_Query_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Simple_Query_Event;

   procedure Prepare_Statement
     (Item            : in out Session;
      Statement_Name  : String;
      SQL             : String;
      Parameter_Types : Protocol.Oid_Array := Protocol.No_Oids;
      Timeout         : Duration := 30.0);
   procedure Bind_Portal
     (Item           : in out Session;
      Portal_Name    : String;
      Statement_Name : String;
      Parameters     : Protocol.Bind_Parameter_Array :=
        Protocol.No_Parameters;
      Result_Formats : Protocol.Field_Format_Array := Protocol.No_Formats;
      Timeout        : Duration := 30.0);
   procedure Describe_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0);
   procedure Describe_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0);
   procedure Execute_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0);
   procedure Resume_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0);
   procedure Close_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0);
   procedure Close_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0);
   procedure Flush
     (Item : in out Session; Timeout : Duration := 30.0);
   procedure Synchronize
     (Item : in out Session; Timeout : Duration := 30.0);

   subtype Extended_Query_Event is Protocol.Backend_Message;
   function Receive_Extended_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Extended_Query_Event;

   subtype Copy_Event is Protocol.Backend_Message;
   procedure Send_Copy_Data
     (Item : in out Session;
      Data : Protocol.Byte_Array;
      Timeout : Duration := 30.0);
   procedure Finish_Copy
     (Item : in out Session; Timeout : Duration := 30.0);
   procedure Abort_Copy
     (Item : in out Session;
      Reason : String;
      Timeout : Duration := 30.0);
   function Receive_Copy_Event
     (Item : in out Session; Timeout : Duration := 30.0) return Copy_Event;

   function Is_Ready (Item : Session) return Boolean;
   function State (Item : Session) return Operation_State;
   function Backend_Process_Id (Item : Session) return Protocol.UInt32;
   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array;

   function Error_Message (Value : Protocol.Message) return String;
   function SQL_State (Value : Protocol.Message) return String;

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
      Copy_Sync_Pending : Boolean := False;
      Pid     : Protocol.UInt32 := 0;
      Secret  : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Client;
