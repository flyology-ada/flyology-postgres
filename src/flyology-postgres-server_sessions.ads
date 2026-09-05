with Flyology.Cancellation;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Server_Sessions is
   --  Stateful backend-side I/O helpers for one PostgreSQL connection.

   type Session
     (Channel : not null access Transports.Transport'Class) is limited private;
   --  Server view of a caller-owned transport and its cancellation state.
   --  @field Channel Open transport whose lifetime exceeds the session.

   function Read_Initial
     (Item : in out Session;
      Timeout : Duration) return Protocol.Initial_Request;
   --  Read a startup, SSL, GSS, or cancellation request before authentication.
   --  @param Item New server session to read.
   --  @param Timeout Maximum time allowed for the complete packet.
   --  @return Decoded initial request.
   function Read_Command
     (Item : in out Session; Timeout : Duration) return Protocol.Message;
   --  Read one complete typed frontend message after startup.
   --  @param Item Authenticated server session to read.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return Raw frontend protocol message.
   function Read_Copy_Command
     (Item : in out Session; Timeout : Duration)
      return Protocol.Frontend_Copy_Message;
   --  Read and classify one frontend message during COPY.
   --  @param Item Server session in COPY mode.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate event.

   procedure Send
     (Item    : in out Session;
      Value   : Protocol.Message;
      Timeout : Duration);
   --  Send one complete backend protocol message.
   --  @param Item Session to write.
   --  @param Value Backend message to encode and transmit.
   --  @param Timeout Maximum time allowed for the complete write.
   procedure Refuse_TLS
     (Item : in out Session; Timeout : Duration);
   --  Reply `N` to an SSLRequest.
   --  @param Item Session awaiting the negotiation response.
   --  @param Timeout Maximum time allowed for the one-byte response.
   procedure Accept_TLS
     (Item : in out Session; Timeout : Duration);
   --  Reply `S` to an SSLRequest before the transport is upgraded.
   --  @param Item Session awaiting the negotiation response.
   --  @param Timeout Maximum time allowed for the one-byte response.
   procedure Refuse_GSS
     (Item : in out Session; Timeout : Duration);
   --  Reply `N` to a GSSENCRequest because GSS encryption is unsupported.
   --  @param Item Session awaiting the negotiation response.
   --  @param Timeout Maximum time allowed for the one-byte response.

   procedure Send_Authentication_Ok
     (Item : in out Session; Timeout : Duration);
   --  Confirm successful authentication.
   --  @param Item Starting session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Authentication_Cleartext_Password
     (Item : in out Session; Timeout : Duration);
   --  Request a cleartext PasswordMessage from the client.
   --  @param Item Starting session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Authentication_SASL
     (Item : in out Session; Timeout : Duration);
   --  Advertise SCRAM-SHA-256 as the supported SASL mechanism.
   --  @param Item Starting session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Authentication_SASL_Continue
     (Item : in out Session; Data : String; Timeout : Duration);
   --  Send a SCRAM server-first challenge.
   --  @param Item Session in SASL authentication.
   --  @param Data Exact SCRAM challenge text.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Authentication_SASL_Final
     (Item : in out Session; Data : String; Timeout : Duration);
   --  Send the final SCRAM server signature or error text.
   --  @param Item Session in SASL authentication.
   --  @param Data Exact SCRAM server-final text.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Negotiate_Protocol
     (Item           : in out Session;
      Latest_Version : Protocol.UInt32;
      Timeout        : Duration);
   --  Report the newest supported protocol version.
   --  @param Item Starting session to write.
   --  @param Latest_Version Packed version word, major << 16 or minor.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Parameter_Status
     (Item    : in out Session;
      Name    : String;
      Value   : String;
      Timeout : Duration);
   --  Send one run-time parameter name/value pair.
   --  @param Item Authenticated session to write.
   --  @param Name PostgreSQL parameter name.
   --  @param Value Current textual parameter value.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Backend_Key_Data
     (Item       : in out Session;
      Process_Id : Protocol.UInt32;
      Secret_Key : Protocol.Byte_Array;
      Timeout    : Duration);
   --  Provide credentials used by a later CancelRequest.
   --  @param Item Authenticated session to write.
   --  @param Process_Id Server-assigned cancellation process identifier.
   --  @param Secret_Key Unpredictable cancellation secret bytes.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Ready
     (Item               : in out Session;
      Transaction_Status : Character := 'I';
      Timeout            : Duration);
   --  Send ReadyForQuery and its transaction-status byte.
   --  @param Item Session completing startup or a query cycle.
   --  @param Transaction_Status `I`, `T`, or `E` per PostgreSQL semantics.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Error
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "XX000";
      Severity  : String := "ERROR";
      Timeout   : Duration);
   --  Send an ErrorResponse with required severity, SQLSTATE, and message.
   --  @param Item Session to write.
   --  @param Message Human-readable primary diagnostic text.
   --  @param SQL_State Five-character SQLSTATE code.
   --  @param Severity Localized or nonlocalized severity label.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Notice
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "00000";
      Severity  : String := "NOTICE";
      Timeout   : Duration);
   --  Send an asynchronous NoticeResponse.
   --  @param Item Session to write.
   --  @param Message Human-readable primary diagnostic text.
   --  @param SQL_State Five-character SQLSTATE code.
   --  @param Severity Notice severity label.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Command_Complete
     (Item : in out Session; Tag : String; Timeout : Duration);
   --  Report successful completion of one SQL command.
   --  @param Item Session to write.
   --  @param Tag PostgreSQL command tag, including any row count.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Empty_Query_Response
     (Item : in out Session; Timeout : Duration);
   --  Report an empty simple-query string.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Parse_Complete
     (Item : in out Session; Timeout : Duration);
   --  Acknowledge successful Parse processing.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Bind_Complete
     (Item : in out Session; Timeout : Duration);
   --  Acknowledge successful Bind processing.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Close_Complete
     (Item : in out Session; Timeout : Duration);
   --  Acknowledge successful Close processing.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_No_Data
     (Item : in out Session; Timeout : Duration);
   --  Report that Describe has no row description.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Row_Description
     (Item    : in out Session;
      Columns : Protocol.Field_Description_Array;
      Timeout : Duration);
   --  Send metadata for all result columns.
   --  @param Item Session to write.
   --  @param Columns Field metadata in result order.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Row_Description
     (Item      : in out Session;
      Name      : String;
      Type_Oid  : Protocol.UInt32 := 25;
      Type_Size : Protocol.UInt16 := 16#FFFF#;
      Timeout   : Duration);
   --  Send metadata for one text-format result column.
   --  @param Item Session to write.
   --  @param Name Result-column label.
   --  @param Type_Oid PostgreSQL data type OID; defaults to text.
   --  @param Type_Size Type width, or 16#FFFF# for variable width.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Data_Row
     (Item    : in out Session;
      Values  : Protocol.Column_Value_Array;
      Timeout : Duration);
   --  Send one result row with explicit null and byte values.
   --  @param Item Session to write.
   --  @param Values Column values in row-description order.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Data_Row
     (Item : in out Session; Value : String; Timeout : Duration);
   --  Send one text result column in a one-column row.
   --  @param Item Session to write.
   --  @param Value Text column contents.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Null_Data_Row
     (Item : in out Session; Timeout : Duration);
   --  Send a one-column row whose value is SQL NULL.
   --  @param Item Session to write.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Copy_In_Response
     (Item           : in out Session;
      Overall_Format : Protocol.Field_Format;
      Column_Formats : Protocol.Field_Format_Array;
      Timeout        : Duration);
   --  Enter COPY IN and describe expected input formats.
   --  @param Item Session to write.
   --  @param Overall_Format Overall text or binary COPY format.
   --  @param Column_Formats Per-column formats in order.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Copy_Out_Response
     (Item           : in out Session;
      Overall_Format : Protocol.Field_Format;
      Column_Formats : Protocol.Field_Format_Array;
      Timeout        : Duration);
   --  Enter COPY OUT and describe emitted formats.
   --  @param Item Session to write.
   --  @param Overall_Format Overall text or binary COPY format.
   --  @param Column_Formats Per-column formats in order.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Copy_Both_Response
     (Item           : in out Session;
      Overall_Format : Protocol.Field_Format;
      Column_Formats : Protocol.Field_Format_Array;
      Timeout        : Duration);
   --  Enter bidirectional COPY and describe both directions' formats.
   --  @param Item Session to write.
   --  @param Overall_Format Overall text or binary COPY format.
   --  @param Column_Formats Per-column formats in order.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Copy_Data
     (Item : in out Session;
      Data : Protocol.Byte_Array;
      Timeout : Duration);
   --  Send one CopyData payload.
   --  @param Item Session in COPY OUT or COPY BOTH.
   --  @param Data Raw COPY payload bytes.
   --  @param Timeout Maximum time allowed for the response.
   procedure Send_Copy_Done
     (Item : in out Session; Timeout : Duration);
   --  Close the backend-to-frontend COPY direction.
   --  @param Item Session in COPY OUT or COPY BOTH.
   --  @param Timeout Maximum time allowed for the response.

   function Query_Text (Command : Protocol.Message) return String;
   --  Decode the SQL string in a Query frontend message.
   --  @param Command Query message to inspect.
   --  @return SQL text without its terminating zero byte.
   function Password_Text (Command : Protocol.Message) return String;
   --  Decode the credential in a cleartext PasswordMessage.
   --  @param Command PasswordMessage to inspect.
   --  @return Exact password octets represented as a String.
   function SASL_Initial_Response
     (Command : Protocol.Message) return String;
   --  Decode the response bytes in a SASLInitialResponse message.
   --  @param Command Initial SASL response to inspect.
   --  @return Exact SCRAM client-first message.
   function SASL_Response (Command : Protocol.Message) return String;
   --  Decode the bytes in a subsequent SASLResponse message.
   --  @param Command SASL response to inspect.
   --  @return Exact SCRAM client-final message.

   function Cancellation_Requested (Item : Session) return Boolean;
   --  Report whether the current handler operation was cancelled by a matching
   --  CancelRequest or forced structured-server shutdown.
   --  @param Item Session whose operation token is queried.
   --  @return True after cancellation has been requested.

private
   type Token_Access is access all Flyology.Cancellation.Token;

   type Session
     (Channel : not null access Transports.Transport'Class) is limited record
      Operation_Cancellation : Token_Access := null;
      Shutdown_Cancellation  : Token_Access := null;
   end record;

end Flyology.Postgres.Server_Sessions;
