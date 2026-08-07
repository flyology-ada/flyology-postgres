with Ada.Streams;
with Interfaces;
private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;
private with Flyology.Bytes;

package Flyology.Postgres.Replication.Logical is
   --  PostgreSQL pgoutput logical-replication messages for protocol versions
   --  1 through 4, including streaming and two-phase transaction extensions.

   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;

   subtype Byte is Ada.Streams.Stream_Element;
   --  One pgoutput wire octet.
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   --  Contiguous pgoutput wire octets.
   subtype UInt32 is Interfaces.Unsigned_32;
   --  Unsigned 32-bit pgoutput integer.
   subtype Int32 is Interfaces.Integer_32;
   --  Signed 32-bit pgoutput integer.
   subtype LSN is Replication.LSN;
   --  PostgreSQL log sequence number.
   subtype Replication_Timestamp is Replication.Replication_Timestamp;
   --  Microseconds since PostgreSQL's 2000-01-01 epoch.
   subtype Transaction_Id is Replication.Transaction_Id;
   --  PostgreSQL 32-bit transaction identifier.

   type Protocol_Version is range 1 .. 4;
   --  Supported pgoutput protocol version.
   type Streaming_Mode is (Disabled, In_Progress, Parallel);
   --  Negotiated streaming option.
   --  @enum Disabled Decode only complete, non-streamed transactions.
   --  @enum In_Progress Decode interleaved in-progress transactions.
   --  @enum Parallel Decode version-4 parallel-streaming messages.

   function Minimum_Server_Major (Version : Protocol_Version) return Positive;
   --  Return the first PostgreSQL release supporting a protocol version.
   --  @param Version pgoutput protocol version.
   --  @return First PostgreSQL major supporting Version.
   function Configuration_Is_Valid
     (Version : Protocol_Version; Streaming : Streaming_Mode) return Boolean;
   --  Check whether a protocol version supports a streaming mode.
   --  @param Version Negotiated pgoutput protocol version.
   --  @param Streaming Requested streaming behavior.
   --  @return True when the combination can be encoded and decoded.

   type Message_Kind is
     (Begin_Message,
      Commit_Message,
      Origin_Message,
      Logical_Decoding_Message,
      Relation_Message,
      Type_Message,
      Insert_Message,
      Update_Message,
      Delete_Message,
      Truncate_Message,
      Stream_Start_Message,
      Stream_Stop_Message,
      Stream_Commit_Message,
      Stream_Abort_Message,
      Begin_Prepare_Message,
      Prepare_Message,
      Commit_Prepared_Message,
      Rollback_Prepared_Message,
      Stream_Prepare_Message);
   --  Supported pgoutput message classification.
   --  @enum Begin_Message Begin a non-streamed transaction.
   --  @enum Commit_Message Commit a non-streamed transaction.
   --  @enum Origin_Message Replication-origin metadata.
   --  @enum Logical_Decoding_Message User logical decoding message.
   --  @enum Relation_Message Relation metadata.
   --  @enum Type_Message Data type metadata.
   --  @enum Insert_Message Inserted tuple.
   --  @enum Update_Message Updated tuple with optional old tuple.
   --  @enum Delete_Message Deleted tuple identity.
   --  @enum Truncate_Message One or more truncated relations.
   --  @enum Stream_Start_Message Begin or continue a streamed transaction.
   --  @enum Stream_Stop_Message End the current stream segment.
   --  @enum Stream_Commit_Message Commit a streamed transaction.
   --  @enum Stream_Abort_Message Abort a streamed transaction/subtransaction.
   --  @enum Begin_Prepare_Message Begin decoding a prepared transaction.
   --  @enum Prepare_Message Complete transaction preparation.
   --  @enum Commit_Prepared_Message Commit a prepared transaction.
   --  @enum Rollback_Prepared_Message Roll back a prepared transaction.
   --  @enum Stream_Prepare_Message Prepare a streamed transaction.

   type Message_Level is
     (Transaction_Control, Transaction_Metadata, Row_Change);
   --  Consumer-facing processing level of a pgoutput message.
   --  @enum Transaction_Control Defines transaction lifecycle boundaries.
   --  @enum Transaction_Metadata Adds metadata within a transaction.
   --  @enum Row_Change Describes relation contents or row changes.

   type Tuple_Value_Kind is
     (Null_Value, Unchanged_Toast_Value, Text_Value, Binary_Value);
   --  TupleData column marker and representation.
   --  @enum Null_Value SQL NULL.
   --  @enum Unchanged_Toast_Value External value unchanged and not included.
   --  @enum Text_Value Text-format bytes.
   --  @enum Binary_Value Binary-format bytes.
   type Tuple_Value is private;
   --  One owned TupleData column value.
   type Tuple_Value_Array is array (Positive range <>) of Tuple_Value;
   --  Tuple columns in relation order.
   type Tuple_Data is private;
   --  Owned ordered logical tuple.
   Empty_Tuple : constant Tuple_Data;
   --  Tuple with zero columns, used when no old tuple is present.

   function Null_Column return Tuple_Value;
   --  Construct a logical tuple SQL NULL marker.
   --  @return Tuple value representing SQL NULL.
   function Unchanged_Toast_Column return Tuple_Value;
   --  Construct an unchanged external TOAST marker.
   --  @return Tuple marker for an unchanged external TOAST value.
   function Text_Column (Value : String) return Tuple_Value;
   --  Construct a logical text tuple value.
   --  @param Value Exact text representation bytes.
   --  @return Owned text tuple value.
   function Binary_Column (Value : Byte_Array) return Tuple_Value;
   --  Construct a logical binary tuple value.
   --  @param Value Exact binary representation bytes.
   --  @return Owned binary tuple value.
   function Make_Tuple (Columns : Tuple_Value_Array) return Tuple_Data;
   --  Construct an owned logical tuple.
   --  @param Columns Values in relation column order.
   --  @return Tuple owning copies of Columns.

   function Column_Count (Item : Tuple_Data) return Natural;
   --  Return the number of values in a logical tuple.
   --  @param Item Tuple to inspect.
   --  @return Number of column values.
   function Column
     (Item : Tuple_Data; Index : Positive) return Tuple_Value;
   --  Return one logical tuple value by position.
   --  @param Item Tuple to inspect.
   --  @param Index One-based column index.
   --  @return Selected column value.
   --  @exception Constraint_Error Index exceeds Column_Count.
   function Kind (Item : Tuple_Value) return Tuple_Value_Kind;
   --  Return a logical tuple value's variant.
   --  @param Item Tuple value to inspect.
   --  @return Its null/TOAST/text/binary variant.
   function Value (Item : Tuple_Value) return Byte_Array;
   --  Copy the bytes carried by a text or binary tuple value.
   --  @param Item Text_Value or Binary_Value.
   --  @return Copy of its exact bytes.
   --  @exception Protocol.Protocol_Error Item carries no bytes.
   function Text (Item : Tuple_Value) return String;
   --  Interpret a text value's bytes as character codes without transcoding.
   --  @param Item Text_Value to inspect.
   --  @return String with identical byte values.
   --  @exception Protocol.Protocol_Error Item is not Text_Value.

   type Relation_Column is private;
   --  Relation-message metadata for one logical column.
   type Relation_Column_Array is
     array (Positive range <>) of Relation_Column;
   --  Logical relation columns in tuple order.

   function Make_Relation_Column
     (Name          : String;
      Type_Oid      : UInt32;
      Type_Modifier : Int32 := -1;
      Is_Key        : Boolean := False) return Relation_Column;
   --  Construct one relation column description.
   --  @param Name PostgreSQL attribute name.
   --  @param Type_Oid PostgreSQL data type OID.
   --  @param Type_Modifier Type-specific modifier, or -1.
   --  @param Is_Key Whether the column belongs to replica identity.
   --  @return Owned relation column metadata.
   function Is_Key (Item : Relation_Column) return Boolean;
   --  Test whether a relation column belongs to replica identity.
   --  @param Item Relation column metadata.
   --  @return True when it participates in replica identity.
   function Name (Item : Relation_Column) return String;
   --  Return a logical relation column's name.
   --  @param Item Relation column metadata.
   --  @return Attribute name.
   function Type_Oid (Item : Relation_Column) return UInt32;
   --  Return a logical relation column's PostgreSQL type OID.
   --  @param Item Relation column metadata.
   --  @return PostgreSQL data type OID.
   function Type_Modifier (Item : Relation_Column) return Int32;
   --  Return a logical relation column's type modifier.
   --  @param Item Relation column metadata.
   --  @return Type-specific modifier, or -1.

   type Replica_Identity is
     (Default_Identity,
      Nothing_Identity,
      Full_Identity,
      Index_Identity);
   --  Relation replica identity sent by pgoutput.
   --  @enum Default_Identity Primary key identifies old rows.
   --  @enum Nothing_Identity No old-row identity is logged.
   --  @enum Full_Identity Entire old row is logged.
   --  @enum Index_Identity Configured replica-identity index is logged.

   type Old_Tuple_Kind is
     (No_Old_Tuple, Key_Old_Tuple, Full_Old_Tuple);
   --  Presence and scope of old tuple data on update/delete.
   --  @enum No_Old_Tuple No old tuple is included.
   --  @enum Key_Old_Tuple Only replica-identity columns are included.
   --  @enum Full_Old_Tuple Full old row is included.

   type Message is private;
   --  Owned pgoutput message with validated variant-specific fields.

   type Relation_Id_Array is array (Positive range <>) of UInt32;
   --  Ordered relation OIDs in a Truncate message.
   No_Relation_Ids : constant Relation_Id_Array (1 .. 0) :=
     (others => 0);
   --  Empty relation OID list.

   function Make_Begin
     (Final_LSN : LSN;
      Commit_At : Replication_Timestamp;
      Xid       : Transaction_Id) return Message;
   --  Construct a non-streamed transaction Begin message.
   --  @param Final_LSN Transaction's final LSN.
   --  @param Commit_At Commit timestamp announced at begin.
   --  @param Xid Transaction identifier.
   --  @return Begin message.
   function Make_Commit
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message;
   --  Construct a non-streamed transaction Commit message.
   --  @param Commit_LSN LSN of the commit record.
   --  @param End_LSN LSN immediately after the commit record.
   --  @param Commit_At Commit timestamp.
   --  @return Commit message.
   function Make_Origin
     (Commit_LSN : LSN; Name : String) return Message;
   --  Construct replication-origin metadata.
   --  @param Commit_LSN Commit LSN on the origin server.
   --  @param Name Replication origin name.
   --  @return Origin message.
   function Make_Logical_Decoding_Message
     (Message_LSN   : LSN;
      Prefix        : String;
      Content       : Byte_Array;
      Transactional : Boolean := False;
      Xid           : Transaction_Id := 0) return Message;
   --  Construct a user logical-decoding message.
   --  @param Message_LSN LSN associated with the message.
   --  @param Prefix Application-defined message prefix.
   --  @param Content Arbitrary application payload bytes.
   --  @param Transactional Whether delivery is tied to transaction commit.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Logical decoding message.
   function Make_Relation
     (Relation_Id : UInt32;
      Namespace   : String;
      Name        : String;
      Identity    : Replica_Identity;
      Columns     : Relation_Column_Array;
      Xid         : Transaction_Id := 0) return Message;
   --  Construct relation metadata.
   --  @param Relation_Id Relation OID referenced by subsequent row changes.
   --  @param Namespace Schema name.
   --  @param Name Relation name.
   --  @param Identity Replica-identity policy.
   --  @param Columns Columns in tuple order.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Relation message.
   function Make_Type
     (Type_Oid  : UInt32;
      Namespace : String;
      Name      : String;
      Xid       : Transaction_Id := 0) return Message;
   --  Construct data type metadata.
   --  @param Type_Oid PostgreSQL type OID.
   --  @param Namespace Schema name.
   --  @param Name Type name.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Type message.
   function Make_Insert
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message;
   --  Construct an inserted row change.
   --  @param Relation_Id Target relation OID.
   --  @param New_Tuple Complete inserted tuple.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Insert message.
   function Make_Update
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Old_Kind    : Old_Tuple_Kind := No_Old_Tuple;
      Old_Tuple   : Tuple_Data := Empty_Tuple;
      Xid         : Transaction_Id := 0) return Message;
   --  Construct an updated row change.
   --  @param Relation_Id Target relation OID.
   --  @param New_Tuple Complete post-update tuple.
   --  @param Old_Kind Whether Old_Tuple is absent, key-only, or full.
   --  @param Old_Tuple Optional pre-update identity or full tuple.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Update message.
   function Make_Delete
     (Relation_Id : UInt32;
      Old_Kind    : Old_Tuple_Kind;
      Old_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message;
   --  Construct a deleted row change.
   --  @param Relation_Id Target relation OID.
   --  @param Old_Kind Key-only or full old tuple marker.
   --  @param Old_Tuple Deleted row identity or full tuple.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Delete message.
   --  @exception Protocol.Protocol_Error Old_Kind is No_Old_Tuple.
   function Make_Truncate
     (Relations        : Relation_Id_Array;
      Cascade          : Boolean := False;
      Restart_Identity : Boolean := False;
      Xid              : Transaction_Id := 0) return Message;
   --  Construct a truncate row change.
   --  @param Relations Relation OIDs truncated together.
   --  @param Cascade Whether TRUNCATE CASCADE was specified.
   --  @param Restart_Identity Whether sequences were restarted.
   --  @param Xid Transaction identifier required for streamed encoding.
   --  @return Truncate message.
   function Make_Stream_Start
     (Xid : Transaction_Id; First_Segment : Boolean) return Message;
   --  Construct a Stream Start transaction boundary.
   --  @param Xid Streamed transaction identifier.
   --  @param First_Segment True for the transaction's first segment.
   --  @return Stream Start message.
   function Make_Stream_Stop return Message;
   --  Construct a Stream Stop segment boundary.
   --  @return Stream Stop marker for the current segment.
   function Make_Stream_Commit
     (Xid        : Transaction_Id;
      Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message;
   --  Construct a streamed transaction commit.
   --  @param Xid Streamed transaction identifier.
   --  @param Commit_LSN LSN of the commit record.
   --  @param End_LSN LSN immediately after the commit record.
   --  @param Commit_At Commit timestamp.
   --  @return Stream Commit message.
   function Make_Stream_Abort
     (Xid        : Transaction_Id;
      Subxid     : Transaction_Id;
      Abort_LSN  : LSN := 0;
      Aborted_At : Replication_Timestamp := 0) return Message;
   --  Construct a streamed transaction or subtransaction abort.
   --  @param Xid Top-level streamed transaction identifier.
   --  @param Subxid Aborted transaction or subtransaction identifier.
   --  @param Abort_LSN Version-4 abort record LSN, otherwise zero.
   --  @param Aborted_At Version-4 abort timestamp, otherwise zero.
   --  @return Stream Abort message.
   function Make_Begin_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;
   --  Construct the begin marker for a prepared transaction.
   --  @param Prepare_LSN LSN of the prepare record.
   --  @param End_LSN LSN immediately after the prepare record.
   --  @param Prepare_At Prepare timestamp.
   --  @param Xid Transaction identifier.
   --  @param GID Global transaction identifier.
   --  @return Begin Prepare message.
   function Make_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;
   --  Construct completion of transaction preparation.
   --  @param Prepare_LSN LSN of the prepare record.
   --  @param End_LSN LSN immediately after the prepare record.
   --  @param Prepare_At Prepare timestamp.
   --  @param Xid Transaction identifier.
   --  @param GID Global transaction identifier.
   --  @return Prepare message.
   function Make_Commit_Prepared
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp;
      Xid        : Transaction_Id;
      GID        : String) return Message;
   --  Construct a prepared transaction commit.
   --  @param Commit_LSN LSN of the commit-prepared record.
   --  @param End_LSN LSN immediately after the record.
   --  @param Commit_At Commit timestamp.
   --  @param Xid Transaction identifier.
   --  @param GID Global transaction identifier.
   --  @return Commit Prepared message.
   function Make_Rollback_Prepared
     (Prepare_End_LSN  : LSN;
      Rollback_End_LSN : LSN;
      Prepare_At       : Replication_Timestamp;
      Rollback_At      : Replication_Timestamp;
      Xid              : Transaction_Id;
      GID              : String) return Message;
   --  Construct a prepared transaction rollback.
   --  @param Prepare_End_LSN End LSN recorded when transaction was prepared.
   --  @param Rollback_End_LSN LSN immediately after rollback.
   --  @param Prepare_At Original prepare timestamp.
   --  @param Rollback_At Rollback timestamp.
   --  @param Xid Transaction identifier.
   --  @param GID Global transaction identifier.
   --  @return Rollback Prepared message.
   function Make_Stream_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;
   --  Construct preparation of a streamed transaction.
   --  @param Prepare_LSN LSN of the prepare record.
   --  @param End_LSN LSN immediately after the prepare record.
   --  @param Prepare_At Prepare timestamp.
   --  @param Xid Streamed transaction identifier.
   --  @param GID Global transaction identifier.
   --  @return Stream Prepare message.

   function Encode
     (Item      : Message;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled) return Byte_Array;
   --  Encode Item according to the negotiated pgoutput configuration.
   --  @param Item Logical message to serialize.
   --  @param Version Negotiated protocol version.
   --  @param Streaming Negotiated streaming mode.
   --  @return Exact pgoutput payload bytes.
   --  @exception Protocol.Protocol_Error Item is unavailable or inconsistent
   --     with the selected configuration.

   function Decode
     (Data      : Byte_Array;
      Version   : Protocol_Version;
      Streamed  : Boolean := False;
      Streaming : Streaming_Mode := Disabled) return Message;
   --  Strictly decode one complete pgoutput message with an explicitly
   --  stated stream context.
   --
   --  Streamed is a precondition, not a hint: it must equal the message's
   --  true on-wire stream context -- True exactly when Data occurs between
   --  a decoded Stream Start ('S') and Stream Stop ('E'). It selects whether
   --  the data-bearing messages (Insert, Update, Delete, Relation, Type,
   --  Truncate, and Logical_Decoding_Message) carry a leading streamed
   --  transaction id. Supplying a value inconsistent with the bytes maps
   --  those four id bytes onto the following field and yields an undefined
   --  -- though always memory-safe and Protocol_Error-bounded -- decode;
   --  Decode cannot detect the mismatch, because the prefix is not
   --  self-describing.
   --
   --  Consumers that do not themselves track Stream Start/Stop boundaries
   --  MUST decode through the stateful Decoder below, which derives Streamed
   --  from its own In_Stream state and additionally rejects malformed stream
   --  sequencing. Reserve this stateless form for callers that already know
   --  the exact stream context of Data (for example, non-streamed version-1
   --  output).
   --  @param Data Exact bytes for one logical message.
   --  @param Version Negotiated protocol version.
   --  @param Streamed True exactly when Data lies inside a stream segment;
   --     it must match the on-wire context (see the warning above).
   --  @param Streaming Negotiated streaming mode.
   --  @return Validated owned logical message.
   --  @exception Protocol.Protocol_Error Data or configuration is invalid.

   type Decoder is private;
   --  Stateful decoder that tracks Stream Start/Stop boundaries.
   procedure Configure
     (Item      : out Decoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled);
   --  Initialize or reconfigure a decoder outside any stream segment.
   --  @param Item Decoder to initialize.
   --  @param Version Negotiated protocol version.
   --  @param Streaming Negotiated streaming mode.
   --  @exception Protocol.Protocol_Error Configuration is not valid.
   procedure Reset (Item : in out Decoder);
   --  Leave any active stream while preserving configured version and mode.
   --  @param Item Decoder whose stream state is cleared.
   function Decode
     (Item : in out Decoder; Data : Byte_Array) return Message;
   --  Decode one message and update Stream Start/Stop state atomically.
   --  @param Item Configured stateful decoder.
   --  @param Data Exact bytes for one logical message.
   --  @return Validated message annotated with stream state.
   --  @exception Protocol.Protocol_Error Data violates message or stream
   --     sequencing rules; Item retains its previous stream state.
   function Inside_Stream (Item : Decoder) return Boolean;
   --  Test whether a stateful decoder is inside a stream segment.
   --  @param Item Stateful decoder.
   --  @return True between successfully decoded Stream Start and Stream Stop.

   function Kind (Item : Message) return Message_Kind;
   --  Return a logical message's variant.
   --  @param Item Logical message.
   --  @return Its message variant.
   function Level (Item : Message) return Message_Level;
   --  Return a logical message's consumer processing level.
   --  @param Item Logical message.
   --  @return Consumer processing level for Item.
   function Version (Item : Message) return Protocol_Version;
   --  Return the pgoutput version attached to a message.
   --  @param Item Decoded or constructed logical message.
   --  @return Protocol version used during decode, or version 1 for a message
   --     created by a Make_* constructor.
   function Is_Streamed (Item : Message) return Boolean;
   --  Test whether a message belongs to a streamed transaction.
   --  @param Item Logical message.
   --  @return True when Item belongs to a streamed transaction segment.

   function Transaction (Item : Message) return Transaction_Id;
   --  Return a message's top-level transaction identifier.
   --  @param Item Message carrying a transaction identifier.
   --  @return Top-level transaction ID, or zero when not encoded.
   function Subtransaction (Item : Message) return Transaction_Id;
   --  Return the subtransaction named by Stream Abort.
   --  @param Item Stream_Abort_Message.
   --  @return Aborted transaction or subtransaction ID.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Final_LSN (Item : Message) return LSN;
   --  Return the final LSN announced by Begin.
   --  @param Item Begin_Message.
   --  @return Transaction final LSN.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Commit_LSN (Item : Message) return LSN;
   --  Return a transaction commit record's LSN.
   --  @param Item Commit, Stream Commit, or Commit Prepared message.
   --  @return Commit record LSN.
   --  @exception Protocol.Protocol_Error Item has no commit LSN.
   function Prepare_LSN (Item : Message) return LSN;
   --  Return a prepared transaction's prepare-record LSN.
   --  @param Item Begin Prepare, Prepare, or Stream Prepare message.
   --  @return Prepare record LSN.
   --  @exception Protocol.Protocol_Error Item has no prepare LSN.
   function Prepare_End_LSN (Item : Message) return LSN;
   --  Return the original prepare end LSN from Rollback Prepared.
   --  @param Item Rollback_Prepared_Message.
   --  @return End LSN captured at original prepare time.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function End_LSN (Item : Message) return LSN;
   --  Return the LSN immediately after a transaction record.
   --  @param Item Commit, prepare, or prepared-completion message.
   --  @return LSN immediately after the transaction record.
   --  @exception Protocol.Protocol_Error Item has no end LSN.
   function Origin_Commit_LSN (Item : Message) return LSN;
   --  Return the commit LSN recorded by a replication origin.
   --  @param Item Origin_Message.
   --  @return Commit LSN on the origin server.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Abort_LSN (Item : Message) return LSN;
   --  Return the version-4 stream abort record's LSN.
   --  @param Item Version-4 Stream_Abort_Message.
   --  @return Abort record LSN.
   --  @exception Protocol.Protocol_Error Item lacks version-4 abort metadata.
   function Event_Timestamp
     (Item : Message) return Replication_Timestamp;
   --  Return the primary timestamp carried by transaction-control Item.
   --  @param Item Begin, commit, prepare, or abort message.
   --  @return Commit, prepare, or abort timestamp as applicable.
   --  @exception Protocol.Protocol_Error Item has no event timestamp.
   function Rollback_Timestamp
     (Item : Message) return Replication_Timestamp;
   --  Return the rollback time carried by Rollback Prepared.
   --  @param Item Rollback_Prepared_Message.
   --  @return Rollback timestamp.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function GID (Item : Message) return String;
   --  Return a two-phase transaction's global identifier.
   --  @param Item Two-phase transaction message.
   --  @return Global transaction identifier.
   --  @exception Protocol.Protocol_Error Item has no GID.
   function Origin_Name (Item : Message) return String;
   --  Return replication-origin metadata's name.
   --  @param Item Origin_Message.
   --  @return Replication origin name.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Is_Transactional (Item : Message) return Boolean;
   --  Test whether a logical decoding message is transactional.
   --  @param Item Logical_Decoding_Message.
   --  @return True when delivery is tied to transaction commit.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Message_LSN (Item : Message) return LSN;
   --  Return a user logical message's associated LSN.
   --  @param Item Logical_Decoding_Message.
   --  @return LSN associated with the user message.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Prefix (Item : Message) return String;
   --  Return a user logical message's application prefix.
   --  @param Item Logical_Decoding_Message.
   --  @return Application-defined prefix.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Content (Item : Message) return Byte_Array;
   --  Copy a user logical message's application payload.
   --  @param Item Logical_Decoding_Message.
   --  @return Copy of application-defined payload bytes.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Relation_Id (Item : Message) return UInt32;
   --  Return the relation OID named by relation or row-change data.
   --  @param Item Relation or row-change message.
   --  @return Referenced relation OID.
   --  @exception Protocol.Protocol_Error Item has no single relation OID.
   function Type_Id (Item : Message) return UInt32;
   --  Return the data type OID named by Type.
   --  @param Item Type_Message.
   --  @return PostgreSQL data type OID.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Namespace_Name (Item : Message) return String;
   --  Return the schema name carried by Relation or Type.
   --  @param Item Relation_Message or Type_Message.
   --  @return Schema name.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Object_Name (Item : Message) return String;
   --  Return the relation or type name carried by metadata.
   --  @param Item Relation_Message or Type_Message.
   --  @return Relation or type name.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Identity (Item : Message) return Replica_Identity;
   --  Return a relation's replica-identity policy.
   --  @param Item Relation_Message.
   --  @return Replica-identity policy.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Relation_Column_Count (Item : Message) return Natural;
   --  Return the number of columns carried by Relation.
   --  @param Item Relation_Message.
   --  @return Number of relation columns.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Relation_Column_At
     (Item : Message; Index : Positive) return Relation_Column;
   --  Return one Relation metadata column by position.
   --  @param Item Relation_Message.
   --  @param Index One-based relation column index.
   --  @return Selected column metadata.
   --  @exception Constraint_Error Index exceeds Relation_Column_Count.

   function New_Tuple (Item : Message) return Tuple_Data;
   --  Return the new tuple carried by Insert or Update.
   --  @param Item Insert_Message or Update_Message.
   --  @return Inserted or post-update tuple.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Old_Kind (Item : Message) return Old_Tuple_Kind;
   --  Return the old-tuple marker carried by Update or Delete.
   --  @param Item Update_Message or Delete_Message.
   --  @return Presence and scope of old tuple data.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Old_Tuple (Item : Message) return Tuple_Data;
   --  Return the old tuple carried by Update or Delete.
   --  @param Item Update or Delete with Old_Kind other than No_Old_Tuple.
   --  @return Pre-change identity or full tuple.
   --  @exception Protocol.Protocol_Error No old tuple is present.

   function Truncated_Relation_Count (Item : Message) return Natural;
   --  Return the number of relation OIDs carried by Truncate.
   --  @param Item Truncate_Message.
   --  @return Number of truncated relation OIDs.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Truncated_Relation
     (Item : Message; Index : Positive) return UInt32;
   --  Return one truncated relation OID by position.
   --  @param Item Truncate_Message.
   --  @param Index One-based relation index.
   --  @return Selected truncated relation OID.
   --  @exception Constraint_Error Index exceeds Truncated_Relation_Count.
   function Cascade (Item : Message) return Boolean;
   --  Test whether a Truncate message used CASCADE.
   --  @param Item Truncate_Message.
   --  @return True when TRUNCATE CASCADE was used.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Restart_Identity (Item : Message) return Boolean;
   --  Test whether a Truncate message restarted sequences.
   --  @param Item Truncate_Message.
   --  @return True when sequences were restarted.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Is_First_Stream_Segment (Item : Message) return Boolean;
   --  Test whether Stream Start begins a transaction's first segment.
   --  @param Item Stream_Start_Message.
   --  @return True for a transaction's first streamed segment.
   --  @exception Protocol.Protocol_Error Item is another variant.

private
   type Tuple_Value is record
      Value_Kind : Tuple_Value_Kind := Null_Value;
      Data       : Flyology.Bytes.Unbounded_Bytes;
   end record;

   package Tuple_Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Tuple_Value);

   type Tuple_Data is record
      Columns : Tuple_Value_Vectors.Vector;
   end record;

   Empty_Tuple : constant Tuple_Data :=
     (Columns => Tuple_Value_Vectors.Empty_Vector);

   type Relation_Column is record
      Key      : Boolean := False;
      Label    : Ada.Strings.Unbounded.Unbounded_String;
      Oid      : UInt32 := 0;
      Modifier : Int32 := -1;
   end record;

   package Relation_Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Relation_Column);

   package Oid_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => UInt32);

   type Message is record
      Message_Type       : Message_Kind := Begin_Message;
      Wire_Version       : Protocol_Version := 1;
      Streamed           : Boolean := False;
      Parallel_Stream    : Boolean := False;
      Xid                : Transaction_Id := 0;
      Subxid             : Transaction_Id := 0;
      First_Position     : LSN := 0;
      Second_Position    : LSN := 0;
      First_Time         : Replication_Timestamp := 0;
      Second_Time        : Replication_Timestamp := 0;
      Flag               : Boolean := False;
      First_Text         : Ada.Strings.Unbounded.Unbounded_String;
      Second_Text        : Ada.Strings.Unbounded.Unbounded_String;
      Bytes              : Flyology.Bytes.Unbounded_Bytes;
      Relation           : UInt32 := 0;
      Replica            : Replica_Identity := Default_Identity;
      Relation_Columns   : Relation_Column_Vectors.Vector;
      Before_Kind        : Old_Tuple_Kind := No_Old_Tuple;
      Before             : Tuple_Data;
      After              : Tuple_Data;
      Relation_Oids      : Oid_Vectors.Vector;
      Truncate_Cascade   : Boolean := False;
      Truncate_Restart   : Boolean := False;
   end record;

   type Decoder is record
      Wire_Version : Protocol_Version := 1;
      Mode         : Streaming_Mode := Disabled;
      In_Stream    : Boolean := False;
   end record;

end Flyology.Postgres.Replication.Logical;
