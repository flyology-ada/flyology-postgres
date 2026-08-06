with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;
with Flyology.Bytes;
private with Ada.Containers.Vectors;

package Flyology.Postgres.Protocol is
   --  Owned PostgreSQL wire messages, strict decoders, typed backend events,
   --  and constructors for frontend protocol operations.

   use type Interfaces.Integer_16;
   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;

   subtype Byte is Ada.Streams.Stream_Element;
   --  One PostgreSQL wire octet.
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   --  Contiguous PostgreSQL wire octets.
   subtype Byte_Offset is Ada.Streams.Stream_Element_Offset;
   --  Index or cursor into a Byte_Array.
   subtype UInt16 is Interfaces.Unsigned_16;
   --  Unsigned 16-bit wire integer.
   subtype UInt32 is Interfaces.Unsigned_32;
   --  Unsigned 32-bit wire integer.
   subtype Int16 is Interfaces.Integer_16;
   --  Signed 16-bit wire integer.
   subtype Int32 is Interfaces.Integer_32;
   --  Signed 32-bit wire integer.

   Protocol_Error : exception;
   --  Raised for malformed, oversized, inconsistent, or mis-typed messages.

   Maximum_Message_Size : constant := Flyology.Postgres.Maximum_Message_Size;
   --  Largest accepted complete wire message, including header bytes.

   type Frontend_Kind is
     (Bind,
      Close,
      Copy_Data,
      Copy_Done,
      Copy_Fail,
      Describe,
      Execute,
      Flush,
      Function_Call,
      Password_Or_SASL_Response,
      Parse,
      Query,
      Sync,
      Terminate_Command,
      Unknown);
   --  Frontend message classification derived from the one-byte tag.
   --  @enum Bind Bind parameters to a portal.
   --  @enum Close Close a prepared statement or portal.
   --  @enum Copy_Data Transfer one COPY payload.
   --  @enum Copy_Done Finish one COPY direction.
   --  @enum Copy_Fail Abort COPY with a reason.
   --  @enum Describe Request statement or portal metadata.
   --  @enum Execute Execute a bound portal.
   --  @enum Flush Ask the backend to flush pending responses.
   --  @enum Function_Call Legacy function-call protocol message.
   --  @enum Password_Or_SASL_Response Authentication response message.
   --  @enum Parse Create a prepared statement.
   --  @enum Query Execute simple-query SQL text.
   --  @enum Sync End or recover an extended-query cycle.
   --  @enum Terminate_Command Close the frontend connection cleanly.
   --  @enum Unknown Tag not classified by this package.

   type Message is private;
   --  Owned tagged protocol message payload, excluding encoded length bytes.

   function Make_Message
     (Code : Character; Payload : Byte_Array) return Message;
   --  Construct an owned message from a tag and payload.
   --  @param Code PostgreSQL one-byte message tag.
   --  @param Payload Bytes after the encoded length.
   --  @return Message owning a copy of Payload.
   --  @exception Protocol_Error The encoded message would exceed the limit.
   function Make_Empty_Message (Code : Character) return Message;
   --  Construct a message without payload bytes.
   --  @param Code PostgreSQL one-byte message tag.
   --  @return Message with an empty payload.
   function Code (Item : Message) return Character;
   --  Return a message's raw protocol tag.
   --  @param Item Message to inspect.
   --  @return Its raw one-byte tag.
   function Kind (Item : Message) return Frontend_Kind;
   --  Classify a frontend message by its tag.
   --  @param Item Frontend message to classify by tag.
   --  @return Known frontend kind or Unknown.
   function Payload (Item : Message) return Byte_Array;
   --  Copy a message's payload.
   --  @param Item Message to inspect.
   --  @return Copy of its payload bytes.
   function Payload_Length (Item : Message) return Natural;
   --  Return a message's payload size.
   --  @param Item Message to inspect.
   --  @return Number of bytes after the encoded length.
   function Encode (Item : Message) return Byte_Array;
   --  Encode tag, length, and payload for transport.
   --  @param Item Message to serialize.
   --  @return Complete PostgreSQL wire representation.

   type Object_Kind is (Statement_Object, Portal_Object);
   --  Extended-query object selected by Describe or Close.
   --  @enum Statement_Object Prepared statement.
   --  @enum Portal_Object Bound portal.
   subtype Row_Limit is Int32 range 0 .. Int32'Last;
   --  Execute row limit; zero requests all rows.

   type Oid_Array is array (Positive range <>) of UInt32;
   --  Ordered PostgreSQL object identifiers, typically parameter type OIDs.
   No_Oids : constant Oid_Array (1 .. 0) := (others => 0);
   --  Empty OID list requesting server-side type inference.

   type Field_Format is (Text_Format, Binary_Format);
   --  PostgreSQL field representation code.
   --  @enum Text_Format Server's textual representation.
   --  @enum Binary_Format Type-specific binary representation.
   type Field_Format_Array is array (Positive range <>) of Field_Format;
   --  Ordered parameter or result-column formats.
   No_Formats : constant Field_Format_Array (1 .. 0) :=
     (others => Text_Format);
   --  Empty format list selecting PostgreSQL's text defaults.

   type Bind_Parameter is private;
   --  Owned Bind parameter preserving nullness, format, and exact bytes.
   type Bind_Parameter_Array is
     array (Positive range <>) of Bind_Parameter;
   --  Bind parameters in prepared-statement order.
   No_Parameters : constant Bind_Parameter_Array (1 .. 0);
   --  Empty Bind parameter list.

   function Null_Parameter
     (Format : Field_Format := Text_Format) return Bind_Parameter;
   --  Construct an SQL NULL parameter.
   --  @param Format Declared format code retained for the null parameter.
   --  @return SQL NULL Bind parameter.
   function Text_Parameter (Value : String) return Bind_Parameter;
   --  Construct a non-null text-format parameter.
   --  @param Value Exact text bytes, without a terminating zero.
   --  @return Non-null text-format Bind parameter.
   function Binary_Parameter (Value : Byte_Array) return Bind_Parameter;
   --  Construct a non-null binary-format parameter.
   --  @param Value Exact type-specific binary bytes.
   --  @return Non-null binary-format Bind parameter.
   function Is_Null (Item : Bind_Parameter) return Boolean;
   --  Test whether a Bind parameter represents SQL NULL.
   --  @param Item Bind parameter to inspect.
   --  @return True when Item represents SQL NULL.
   function Parameter_Format (Item : Bind_Parameter) return Field_Format;
   --  Return a Bind parameter's representation format.
   --  @param Item Bind parameter to inspect.
   --  @return Its text or binary format.
   function Parameter_Bytes (Item : Bind_Parameter) return Byte_Array;
   --  Copy a non-null Bind parameter's exact bytes.
   --  @param Item Non-null Bind parameter to inspect.
   --  @return Copy of its exact value bytes.
   --  @exception Protocol_Error Item is null.

   function Make_Parse_Message
     (Statement_Name  : String;
      SQL             : String;
      Parameter_Types : Oid_Array := No_Oids) return Message;
   --  Construct an extended-query Parse message.
   --  @param Statement_Name Empty for the unnamed statement, otherwise name.
   --  @param SQL SQL text, possibly containing positional parameters.
   --  @param Parameter_Types Zero or one type OID per SQL parameter.
   --  @return Encoded-payload Parse message.
   function Make_Bind_Message
     (Portal_Name    : String;
      Statement_Name : String;
      Parameters     : Bind_Parameter_Array := No_Parameters;
      Result_Formats : Field_Format_Array := No_Formats) return Message;
   --  Construct an extended-query Bind message.
   --  @param Portal_Name Empty for the unnamed portal, otherwise name.
   --  @param Statement_Name Prepared statement to bind.
   --  @param Parameters Values in statement parameter order.
   --  @param Result_Formats Zero, one, or one-per-column format codes.
   --  @return Encoded-payload Bind message.
   function Make_Describe_Message
     (Object_Type : Object_Kind; Name : String) return Message;
   --  Construct a Describe message for a statement or portal.
   --  @param Object_Type Whether Name denotes a statement or portal.
   --  @param Name Object name, empty for the unnamed object.
   --  @return Describe frontend message.
   function Make_Execute_Message
     (Portal_Name : String; Maximum_Rows : Row_Limit := 0) return Message;
   --  Construct an Execute message for a bound portal.
   --  @param Portal_Name Bound portal to execute.
   --  @param Maximum_Rows Zero for all rows, otherwise suspension limit.
   --  @return Execute frontend message.
   function Make_Close_Message
     (Object_Type : Object_Kind; Name : String) return Message;
   --  Construct a Close message for a statement or portal.
   --  @param Object_Type Whether Name denotes a statement or portal.
   --  @param Name Object name, empty for the unnamed object.
   --  @return Close frontend message.
   function Make_Flush_Message return Message;
   --  Construct a Flush message.
   --  @return Empty Flush frontend message.
   function Make_Sync_Message return Message;
   --  Construct a Sync message.
   --  @return Empty Sync frontend message.
   function Make_Copy_Data_Message (Data : Byte_Array) return Message;
   --  Construct a frontend CopyData message.
   --  @param Data Raw COPY payload bytes.
   --  @return CopyData frontend message owning Data.
   function Make_Copy_Done_Message return Message;
   --  Construct a frontend CopyDone message.
   --  @return Empty CopyDone frontend message.
   function Make_Copy_Fail_Message (Reason : String) return Message;
   --  Construct a frontend CopyFail message.
   --  @param Reason Human-readable COPY failure text.
   --  @return CopyFail frontend message.

   type Frontend_Copy_Kind is
     (Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail);
   --  Frontend messages valid while COPY is active.
   --  @enum Frontend_Copy_Data One raw COPY payload.
   --  @enum Frontend_Copy_Done Client closes its COPY direction.
   --  @enum Frontend_Copy_Fail Client aborts COPY with a reason.
   type Frontend_Copy_Message is private;
   --  Strictly decoded frontend COPY message retaining its original bytes.
   function Decode_Frontend_Copy
     (Item : Message) return Frontend_Copy_Message;
   --  Decode and validate a CopyData, CopyDone, or CopyFail message.
   --  @param Item Raw frontend protocol message.
   --  @return Typed COPY message.
   --  @exception Protocol_Error Item is another kind or malformed.
   function Copy_Kind
     (Item : Frontend_Copy_Message) return Frontend_Copy_Kind;
   --  Return a decoded frontend COPY message's variant.
   --  @param Item Decoded frontend COPY message.
   --  @return Its variant.
   function Copy_Bytes (Item : Frontend_Copy_Message) return Byte_Array;
   --  Copy the payload of a frontend CopyData message.
   --  @param Item Frontend_Copy_Data message.
   --  @return Copy of its raw payload.
   --  @exception Protocol_Error Item is another variant.
   function Copy_Failure_Reason (Item : Frontend_Copy_Message) return String;
   --  Return the reason carried by a frontend CopyFail message.
   --  @param Item Frontend_Copy_Fail message.
   --  @return Client-supplied failure reason.
   --  @exception Protocol_Error Item is another variant.
   function Original_Message (Item : Frontend_Copy_Message) return Message;
   --  Return the raw message retained by a decoded frontend COPY event.
   --  @param Item Decoded frontend COPY message.
   --  @return Owned original message.

   type Backend_Message_Kind is
     (Row_Description_Response,
      Data_Row_Response,
      Command_Complete_Response,
      Empty_Query_Response,
      Error_Response,
      Notice_Response,
      Parameter_Status_Response,
      Parse_Complete_Response,
      Bind_Complete_Response,
      Close_Complete_Response,
      Parameter_Description_Response,
      No_Data_Response,
      Portal_Suspended_Response,
      Copy_In_Response,
      Copy_Out_Response,
      Copy_Both_Response,
      Copy_Data_Response,
      Copy_Done_Response,
      Ready_For_Query_Response,
      Unknown_Response);
   --  Supported backend response classification.
   --  @enum Row_Description_Response Result-column metadata.
   --  @enum Data_Row_Response One row of nullable field values.
   --  @enum Command_Complete_Response Successful command tag.
   --  @enum Empty_Query_Response Empty simple query.
   --  @enum Error_Response Error diagnostic fields.
   --  @enum Notice_Response Asynchronous notice diagnostic fields.
   --  @enum Parameter_Status_Response Run-time parameter update.
   --  @enum Parse_Complete_Response Parse acknowledgement.
   --  @enum Bind_Complete_Response Bind acknowledgement.
   --  @enum Close_Complete_Response Close acknowledgement.
   --  @enum Parameter_Description_Response Prepared parameter type OIDs.
   --  @enum No_Data_Response Describe found no row metadata.
   --  @enum Portal_Suspended_Response Execute stopped at its row limit.
   --  @enum Copy_In_Response Server is ready to receive COPY data.
   --  @enum Copy_Out_Response Server will send COPY data.
   --  @enum Copy_Both_Response Bidirectional COPY begins.
   --  @enum Copy_Data_Response One backend COPY payload.
   --  @enum Copy_Done_Response Backend closes its COPY direction.
   --  @enum Ready_For_Query_Response Query cycle completed.
   --  @enum Unknown_Response Tag intentionally retained without typed decode.

   type Copy_Format_Description is private;
   --  COPY overall and per-column text/binary format metadata.
   function Overall_Format
     (Item : Copy_Format_Description) return Field_Format;
   --  Return the overall text or binary COPY format.
   --  @param Item COPY format metadata.
   --  @return Overall COPY representation.
   function Copy_Column_Count
     (Item : Copy_Format_Description) return Natural;
   --  Return the number of per-column COPY formats.
   --  @param Item COPY format metadata.
   --  @return Number of per-column format entries.
   function Copy_Column_Format
     (Item : Copy_Format_Description; Index : Positive) return Field_Format;
   --  Return one column's COPY format.
   --  @param Item COPY format metadata.
   --  @param Index One-based column index.
   --  @return Format selected for that column.
   --  @exception Constraint_Error Index exceeds Copy_Column_Count.

   type Field_Description is private;
   --  Metadata for one RowDescription field.
   type Field_Description_Array is
     array (Positive range <>) of Field_Description;
   --  Result field metadata in wire order.

   function Make_Field_Description
     (Name                    : String;
      Table_Oid               : UInt32 := 0;
      Column_Attribute_Number : Int16 := 0;
      Type_Oid                : UInt32 := 25;
      Type_Size               : Int16 := -1;
      Type_Modifier           : Int32 := -1;
      Format                  : Field_Format := Text_Format)
      return Field_Description;
   --  Construct metadata for one result column.
   --  @param Name Column label shown to the client.
   --  @param Table_Oid Source table OID, or zero when not a table column.
   --  @param Column_Attribute_Number Source attribute number, or zero.
   --  @param Type_Oid PostgreSQL data type OID; defaults to text.
   --  @param Type_Size Type width, or -1 for variable-width types.
   --  @param Type_Modifier Type-specific modifier, or -1 when absent.
   --  @param Format Requested text or binary representation.
   --  @return Owned field description.
   function Field_Name (Item : Field_Description) return String;
   --  Return a result field's label.
   --  @param Item Field metadata.
   --  @return Column label.
   function Table_Oid (Item : Field_Description) return UInt32;
   --  Return a result field's source table OID.
   --  @param Item Field metadata.
   --  @return Source table OID, or zero.
   function Column_Attribute_Number
     (Item : Field_Description) return Int16;
   --  Return a result field's source attribute number.
   --  @param Item Field metadata.
   --  @return Source table attribute number, or zero.
   function Type_Oid (Item : Field_Description) return UInt32;
   --  Return a result field's PostgreSQL type OID.
   --  @param Item Field metadata.
   --  @return PostgreSQL data type OID.
   function Type_Size (Item : Field_Description) return Int16;
   --  Return a result field's declared type width.
   --  @param Item Field metadata.
   --  @return Type width, or -1 for variable width.
   function Type_Modifier (Item : Field_Description) return Int32;
   --  Return a result field's type-specific modifier.
   --  @param Item Field metadata.
   --  @return Type-specific modifier, or -1.
   function Format (Item : Field_Description) return Field_Format;
   --  Return a result field's text or binary format.
   --  @param Item Field metadata.
   --  @return Text or binary representation code.

   type Row_Description is private;
   --  Owned ordered field metadata decoded from RowDescription.
   function Field_Count (Item : Row_Description) return Natural;
   --  Return the number of described result fields.
   --  @param Item Row metadata to inspect.
   --  @return Number of fields.
   function Field_At
     (Item : Row_Description; Index : Positive) return Field_Description;
   --  Return one result field description by position.
   --  @param Item Row metadata to inspect.
   --  @param Index One-based field index.
   --  @return Metadata for the selected field.
   --  @exception Constraint_Error Index exceeds Field_Count.

   type Column_Value is private;
   --  Owned nullable DataRow column bytes.
   type Column_Value_Array is array (Positive range <>) of Column_Value;
   --  Column values in row order.

   Null_Column : constant Column_Value;
   --  Reusable SQL NULL column value.
   function Text_Column (Value : String) return Column_Value;
   --  Construct a non-null text result column.
   --  @param Value Exact text representation bytes.
   --  @return Non-null column containing Value.
   function Binary_Column (Value : Byte_Array) return Column_Value;
   --  Construct a non-null binary result column.
   --  @param Value Exact binary representation bytes.
   --  @return Non-null column owning Value.
   function Is_Null (Item : Column_Value) return Boolean;
   --  Test whether a result column is SQL NULL.
   --  @param Item Column to inspect.
   --  @return True when Item is SQL NULL.
   function Column_Bytes (Item : Column_Value) return Byte_Array;
   --  Copy a non-null result column's exact bytes.
   --  @param Item Non-null column to inspect.
   --  @return Copy of its exact bytes.
   --  @exception Protocol_Error Item is null.
   function Column_Text (Item : Column_Value) return String;
   --  Interpret non-null bytes as character codes without transcoding.
   --  @param Item Non-null text-format column.
   --  @return String with identical byte values.
   --  @exception Protocol_Error Item is null.

   type Data_Row is private;
   --  Owned ordered nullable columns decoded from DataRow.
   function Column_Count (Item : Data_Row) return Natural;
   --  Return the number of values in a decoded row.
   --  @param Item Row to inspect.
   --  @return Number of columns.
   function Column_At
     (Item : Data_Row; Index : Positive) return Column_Value;
   --  Return one decoded column value by position.
   --  @param Item Row to inspect.
   --  @param Index One-based column index.
   --  @return Selected nullable column.
   --  @exception Constraint_Error Index exceeds Column_Count.

   type Diagnostic is private;
   --  Ordered ErrorResponse or NoticeResponse diagnostic fields.
   function Field_Text
     (Item : Diagnostic; Code : Character) return String;
   --  Look up a diagnostic field by its protocol code.
   --  @param Item Diagnostic fields to search.
   --  @param Code PostgreSQL one-byte diagnostic field code.
   --  @return First matching field text, or empty when absent.
   function Severity (Item : Diagnostic) return String;
   --  Return the localized diagnostic severity.
   --  @param Item Diagnostic to inspect.
   --  @return Localized severity field, or empty when absent.
   function Nonlocalized_Severity (Item : Diagnostic) return String;
   --  Return the stable nonlocalized diagnostic severity.
   --  @param Item Diagnostic to inspect.
   --  @return Nonlocalized severity field, or empty when absent.
   function Diagnostic_SQL_State (Item : Diagnostic) return String;
   --  Return a diagnostic's SQLSTATE code.
   --  @param Item Diagnostic to inspect.
   --  @return Five-character SQLSTATE, or empty when absent.
   function Diagnostic_Message (Item : Diagnostic) return String;
   --  Return a diagnostic's primary human-readable message.
   --  @param Item Diagnostic to inspect.
   --  @return Primary human-readable message, or empty when absent.

   type Parameter_Status is private;
   --  One owned ParameterStatus name/value update.
   function Parameter_Name (Item : Parameter_Status) return String;
   --  Return an updated run-time parameter's name.
   --  @param Item Parameter update.
   --  @return Parameter name.
   function Parameter_Value (Item : Parameter_Status) return String;
   --  Return an updated run-time parameter's value.
   --  @param Item Parameter update.
   --  @return Current parameter value.

   type Parameter_Description is private;
   --  Ordered parameter type OIDs decoded from ParameterDescription.
   function Parameter_Count (Item : Parameter_Description) return Natural;
   --  Return the number of prepared-statement parameters.
   --  @param Item Parameter metadata.
   --  @return Number of parameter type OIDs.
   function Parameter_Type_At
     (Item : Parameter_Description; Index : Positive) return UInt32;
   --  Return one prepared parameter's PostgreSQL type OID.
   --  @param Item Parameter metadata.
   --  @param Index One-based parameter index.
   --  @return PostgreSQL type OID for the parameter.
   --  @exception Constraint_Error Index exceeds Parameter_Count.

   type Transaction_Status is
     (Idle, In_Transaction, Failed_Transaction);
   --  ReadyForQuery transaction state.
   --  @enum Idle Not inside an explicit transaction block.
   --  @enum In_Transaction Inside a valid transaction block.
   --  @enum Failed_Transaction Transaction block is aborted until rollback.

   type Backend_Message (Response : Backend_Message_Kind := Unknown_Response)
     is private;
   --  Strictly decoded backend response retaining its original message.
   --  @field Response Variant selected from the backend message tag.
   function Decode_Backend (Item : Message) return Backend_Message;
   --  Decode supported backend payloads strictly while retaining Item.
   --  Unknown tags remain Unknown_Response without payload interpretation.
   --  @param Item Raw backend protocol message.
   --  @return Typed owned backend event.
   --  @exception Protocol_Error A recognized payload is malformed.
   function Response_Kind (Item : Backend_Message) return Backend_Message_Kind;
   --  Return a decoded backend event's variant.
   --  @param Item Backend event.
   --  @return Its response variant.
   function Description (Item : Backend_Message) return Row_Description;
   --  Return metadata carried by RowDescription.
   --  @param Item Row_Description_Response event.
   --  @return Decoded result-field metadata.
   --  @exception Protocol_Error Item is another variant.
   function Row_Data (Item : Backend_Message) return Data_Row;
   --  Return columns carried by DataRow.
   --  @param Item Data_Row_Response event.
   --  @return Decoded nullable row columns.
   --  @exception Protocol_Error Item is another variant.
   function Completion_Tag (Item : Backend_Message) return String;
   --  Return text carried by CommandComplete.
   --  @param Item Command_Complete_Response event.
   --  @return PostgreSQL command tag.
   --  @exception Protocol_Error Item is another variant.
   function Diagnostic_Data (Item : Backend_Message) return Diagnostic;
   --  Return fields carried by ErrorResponse or NoticeResponse.
   --  @param Item Error_Response or Notice_Response event.
   --  @return Decoded diagnostic fields.
   --  @exception Protocol_Error Item is another variant.
   function Parameter_Data (Item : Backend_Message) return Parameter_Status;
   --  Return the update carried by ParameterStatus.
   --  @param Item Parameter_Status_Response event.
   --  @return Decoded parameter update.
   --  @exception Protocol_Error Item is another variant.
   function Parameter_Types
     (Item : Backend_Message) return Parameter_Description;
   --  Return type OIDs carried by ParameterDescription.
   --  @param Item Parameter_Description_Response event.
   --  @return Decoded parameter OIDs.
   --  @exception Protocol_Error Item is another variant.
   function Copy_Formats
     (Item : Backend_Message) return Copy_Format_Description;
   --  Return formats carried by a COPY response.
   --  @param Item Copy_In, Copy_Out, or Copy_Both response.
   --  @return Decoded COPY format metadata.
   --  @exception Protocol_Error Item is another variant.
   function Copy_Data (Item : Backend_Message) return Byte_Array;
   --  Copy bytes carried by a backend CopyData event.
   --  @param Item Copy_Data_Response event.
   --  @return Copy of raw COPY payload bytes.
   --  @exception Protocol_Error Item is another variant.
   function Transaction_State
     (Item : Backend_Message) return Transaction_Status;
   --  Return the status carried by ReadyForQuery.
   --  @param Item Ready_For_Query_Response event.
   --  @return Decoded transaction state.
   --  @exception Protocol_Error Item is another variant.
   function Original_Message (Item : Backend_Message) return Message;
   --  Return the raw message retained by a decoded backend event.
   --  @param Item Decoded backend event.
   --  @return Owned original protocol message.

   type Initial_Kind is
     (Startup, SSL_Request, GSS_Request, Cancel_Request, Unknown_Initial);
   --  Untagged initial packet classification.
   --  @enum Startup Protocol version and startup parameters.
   --  @enum SSL_Request Request PostgreSQL SSLRequest negotiation.
   --  @enum GSS_Request Request GSSAPI encryption negotiation.
   --  @enum Cancel_Request Out-of-band query cancellation credentials.
   --  @enum Unknown_Initial Unknown special request code or startup version.

   type Replication_Connection_Mode is
     (Normal_Connection,
      Physical_Replication_Connection,
      Logical_Replication_Connection);
   --  Startup `replication` parameter selection.
   --  @enum Normal_Connection Ordinary SQL connection with no parameter.
   --  @enum Physical_Replication_Connection Physical mode using `true`.
   --  @enum Logical_Replication_Connection Database-capable mode using
   --     `database`.

   type Startup_Information is record
      Protocol_Major  : UInt16 := 3;
      Protocol_Minor  : UInt16 := 0;
      User            : Ada.Strings.Unbounded.Unbounded_String;
      Database        : Ada.Strings.Unbounded.Unbounded_String;
      Application_Name : Ada.Strings.Unbounded.Unbounded_String;
      Replication_Mode : Replication_Connection_Mode := Normal_Connection;
   end record;
   --  Supported fields decoded from a version-3 startup packet.
   --  @field Protocol_Major Protocol major version, normally 3.
   --  @field Protocol_Minor Protocol minor version.
   --  @field User Required PostgreSQL role name.
   --  @field Database Optional database name.
   --  @field Application_Name Optional client application name.
   --  @field Replication_Mode Decoded replication startup parameter.

   type Initial_Request is private;
   --  Owned decoded initial packet: startup, negotiation, or cancellation.

   function Decode_Initial (Contents : Byte_Array) return Initial_Request;
   --  Strictly decode an untagged initial packet including its length field.
   --  @param Contents Complete packet bytes.
   --  @return Classified owned initial request.
   --  @exception Protocol_Error Length or recognized contents are malformed.
   function Kind (Item : Initial_Request) return Initial_Kind;
   --  Return a decoded initial packet's variant.
   --  @param Item Decoded initial request.
   --  @return Its request variant.
   function Startup_Data
     (Item : Initial_Request) return Startup_Information;
   --  Return fields carried by a startup packet.
   --  @param Item Startup request.
   --  @return Decoded supported startup fields.
   --  @exception Protocol_Error Item is not Startup.
   function Process_Id (Item : Initial_Request) return UInt32;
   --  Return the process identifier carried by CancelRequest.
   --  @param Item Cancel_Request.
   --  @return Target backend process identifier.
   --  @exception Protocol_Error Item is not Cancel_Request.
   function Secret_Key (Item : Initial_Request) return Byte_Array;
   --  Copy the secret carried by CancelRequest.
   --  @param Item Cancel_Request.
   --  @return Copy of target backend cancellation secret bytes.
   --  @exception Protocol_Error Item is not Cancel_Request.

   function Encode_Startup
     (User             : String;
      Database         : String := "";
      Application_Name : String := "flyology_postgres";
      Protocol_Major   : UInt16 := 3;
      Protocol_Minor   : UInt16 := 0;
      Replication_Mode : Replication_Connection_Mode := Normal_Connection)
      return Byte_Array;
   --  Encode a protocol-version-3 startup packet.
   --  @param User Required PostgreSQL role name.
   --  @param Database Optional database name.
   --  @param Application_Name Optional application_name value.
   --  @param Protocol_Major Protocol major version, normally 3.
   --  @param Protocol_Minor Protocol minor version.
   --  @param Replication_Mode Optional replication startup parameter.
   --  @return Complete untagged startup packet including length.
   --  @exception Protocol_Error A string contains NUL or exceeds size limits.
   function Encode_SSL_Request return Byte_Array;
   --  Encode the fixed PostgreSQL SSLRequest packet.
   --  @return Complete eight-byte PostgreSQL SSLRequest packet.
   function Encode_Cancel_Request
     (Process_Id : UInt32; Secret_Key : Byte_Array) return Byte_Array;
   --  Encode an out-of-band CancelRequest packet.
   --  @param Process_Id Target backend process identifier.
   --  @param Secret_Key Exact backend cancellation secret, 4 through 256
   --     bytes.
   --  @return Complete untagged cancellation packet.
   --  @exception Protocol_Error Secret_Key is outside the supported range.

   procedure Append_U16
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt16);
   --  Append Value in PostgreSQL network byte order.
   --  @param Target Buffer extended by two bytes.
   --  @param Value Unsigned value to encode.
   procedure Append_U32
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt32);
   --  Append Value in PostgreSQL network byte order.
   --  @param Target Buffer extended by four bytes.
   --  @param Value Unsigned value to encode.
   procedure Append_Byte
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte);
   --  Append one raw byte.
   --  @param Target Buffer extended by one byte.
   --  @param Value Byte to append.
   procedure Append_Bytes
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte_Array);
   --  Append Value in array order.
   --  @param Target Buffer extended by Value'Length bytes.
   --  @param Value Bytes to copy.
   procedure Append_C_String
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : String);
   --  Append String character codes followed by a zero terminator.
   --  @param Target Buffer to extend.
   --  @param Value Text that must not contain NUL.
   --  @exception Protocol_Error Value contains NUL.

   function Read_U16
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt16;
   --  Read one network-order unsigned 16-bit integer and advance Cursor.
   --  @param Source Buffer being decoded.
   --  @param Cursor Position of the first byte; advanced by two.
   --  @return Decoded value.
   --  @exception Protocol_Error Fewer than two bytes remain.
   function Read_U32
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt32;
   --  Read one network-order unsigned 32-bit integer and advance Cursor.
   --  @param Source Buffer being decoded.
   --  @param Cursor Position of the first byte; advanced by four.
   --  @return Decoded value.
   --  @exception Protocol_Error Fewer than four bytes remain.
   function Read_C_String
     (Source : Byte_Array; Cursor : in out Byte_Offset) return String;
   --  Read bytes through the next zero terminator and advance Cursor.
   --  @param Source Buffer being decoded.
   --  @param Cursor First text byte; advanced past the terminator.
   --  @return String containing bytes before the terminator.
   --  @exception Protocol_Error No terminator remains in Source.

private
   type Message is record
      Tag  : Character := Character'Val (0);
      Data : Flyology.Bytes.Unbounded_Bytes;
   end record;

   type Bind_Parameter is record
      Null_Value   : Boolean := True;
      Format_Value : Field_Format := Text_Format;
      Bytes        : Flyology.Bytes.Unbounded_Bytes;
   end record;

   No_Parameters : constant Bind_Parameter_Array (1 .. 0) :=
     (others =>
        (Null_Value   => True,
         Format_Value => Text_Format,
         Bytes        => Flyology.Bytes.Empty));

   type Field_Description is record
      Name_Value                    : Ada.Strings.Unbounded.Unbounded_String;
      Table_Oid_Value               : UInt32 := 0;
      Column_Attribute_Number_Value : Int16 := 0;
      Type_Oid_Value                : UInt32 := 25;
      Type_Size_Value               : Int16 := -1;
      Type_Modifier_Value           : Int32 := -1;
      Format_Value                  : Field_Format := Text_Format;
   end record;

   package Field_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field_Description);

   type Row_Description is record
      Fields : Field_Vectors.Vector;
   end record;

   type Column_Value is record
      Null_Value : Boolean := True;
      Bytes      : Flyology.Bytes.Unbounded_Bytes;
   end record;

   Null_Column : constant Column_Value :=
     (Null_Value => True, Bytes => Flyology.Bytes.Empty);

   package Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column_Value);

   type Data_Row is record
      Columns : Column_Vectors.Vector;
   end record;

   type Diagnostic_Field_Value is record
      Code : Character := Character'Val (0);
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Diagnostic_Field_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Diagnostic_Field_Value);

   type Diagnostic is record
      Fields : Diagnostic_Field_Vectors.Vector;
   end record;

   type Parameter_Status is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Oid_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => UInt32);

   type Parameter_Description is record
      Types : Oid_Vectors.Vector;
   end record;

   package Format_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field_Format);

   type Copy_Format_Description is record
      Overall : Field_Format := Text_Format;
      Columns : Format_Vectors.Vector;
   end record;

   type Frontend_Copy_Message
     (Command : Frontend_Copy_Kind := Frontend_Copy_Done)
   is record
      Raw : Message;
      case Command is
         when Frontend_Copy_Fail =>
            Failure_Value : Ada.Strings.Unbounded.Unbounded_String;
         when Frontend_Copy_Data | Frontend_Copy_Done =>
            null;
      end case;
   end record;

   type Backend_Message (Response : Backend_Message_Kind := Unknown_Response)
   is record
      Raw : Message;
      case Response is
         when Row_Description_Response =>
            Row_Description_Value : Row_Description;
         when Data_Row_Response =>
            Data_Row_Value : Data_Row;
         when Command_Complete_Response =>
            Command_Tag_Value : Ada.Strings.Unbounded.Unbounded_String;
         when Error_Response | Notice_Response =>
            Diagnostic_Value : Diagnostic;
         when Parameter_Status_Response =>
            Parameter_Status_Value : Parameter_Status;
         when Parameter_Description_Response =>
            Parameter_Description_Value : Parameter_Description;
         when Copy_In_Response | Copy_Out_Response | Copy_Both_Response =>
            Copy_Format_Value : Copy_Format_Description;
         when Ready_For_Query_Response =>
            Transaction_Status_Value : Transaction_Status := Idle;
         when Empty_Query_Response |
              Parse_Complete_Response |
              Bind_Complete_Response |
              Close_Complete_Response |
              No_Data_Response |
              Portal_Suspended_Response |
              Copy_Data_Response |
              Copy_Done_Response |
              Unknown_Response =>
            null;
      end case;
   end record;

   type Initial_Request is record
      Request_Kind : Initial_Kind := Unknown_Initial;
      Startup      : Startup_Information;
      Backend_Pid  : UInt32 := 0;
      Secret       : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Protocol;
