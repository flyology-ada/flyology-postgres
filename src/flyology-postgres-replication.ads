with Ada.Streams;
with Interfaces;
with Flyology.Postgres.Protocol;
private with Flyology.Bytes;

package Flyology.Postgres.Replication is
   --  PostgreSQL physical and logical replication command and streaming-frame
   --  encoding, decoding, and accessors.

   subtype Byte is Ada.Streams.Stream_Element;
   --  One protocol payload octet.
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   --  Contiguous protocol payload octets.
   subtype UInt32 is Interfaces.Unsigned_32;
   --  Unsigned 32-bit wire integer.
   subtype UInt64 is Interfaces.Unsigned_64;
   --  Unsigned 64-bit wire integer.
   subtype Int64 is Interfaces.Integer_64;
   --  Signed 64-bit wire integer.

   subtype LSN is UInt64;
   --  PostgreSQL log sequence number represented as a 64-bit byte position.
   subtype Replication_Timestamp is Int64;
   --  Microseconds since PostgreSQL's 2000-01-01 epoch.
   subtype Transaction_Id is UInt32;
   --  PostgreSQL 32-bit transaction identifier.

   function Image (Value : LSN) return String;
   --  Render an LSN in canonical hexadecimal `X/Y` notation.
   --  @param Value Log sequence number to render.
   --  @return Uppercase PostgreSQL LSN text.
   function Value (Text : String) return LSN;
   --  Parse canonical or case-insensitive hexadecimal `X/Y` LSN text.
   --  @param Text PostgreSQL LSN representation.
   --  @return Numeric log sequence number.
   --  @exception Protocol.Protocol_Error Text is malformed or overflows.

   type Logical_Option is private;
   --  One START_REPLICATION logical plugin option, with optional value.
   type Logical_Option_Array is array (Positive range <>) of Logical_Option;
   --  Ordered logical plugin options.
   No_Logical_Options : constant Logical_Option_Array (1 .. 0);
   --  Empty default option list.

   function Option (Name : String) return Logical_Option;
   --  Construct a valueless logical plugin option.
   --  @param Name Nonempty ASCII letter, digit, or underscore identifier.
   --  @return Option preserving absence of a value.
   --  @exception Protocol.Protocol_Error Name is invalid.
   function Option (Name : String; Value : String) return Logical_Option;
   --  Construct a valued logical plugin option.
   --  @param Name Nonempty ASCII letter, digit, or underscore identifier.
   --  @param Value Option text, which may be empty and is SQL-quoted safely.
   --  @return Option preserving the supplied value.
   --  @exception Protocol.Protocol_Error Name is invalid.
   function Option_Name (Item : Logical_Option) return String;
   --  Return a logical option's identifier.
   --  @param Item Logical option to inspect.
   --  @return Its identifier.
   function Option_Value (Item : Logical_Option) return String;
   --  Return a valued logical option's text.
   --  @param Item Logical option to inspect.
   --  @return Its value; empty both for a valueless option and an explicitly
   --     empty value. Use Option_Has_Value to distinguish those cases.
   function Option_Has_Value (Item : Logical_Option) return Boolean;
   --  Test whether a logical option explicitly carries a value.
   --  @param Item Logical option to inspect.
   --  @return True when a value was explicitly supplied.

   function Identify_System return Protocol.Message;
   --  Construct an IDENTIFY_SYSTEM command.
   --  @return Simple Query message containing IDENTIFY_SYSTEM.
   function Show (Parameter : String) return Protocol.Message;
   --  Construct a replication-mode SHOW command.
   --  @param Parameter Nonempty ASCII letter, digit, or underscore identifier.
   --  @return Simple Query message containing SHOW.
   --  @exception Protocol.Protocol_Error Parameter is invalid.
   function Timeline_History (Timeline : UInt32) return Protocol.Message;
   --  Construct a TIMELINE_HISTORY command.
   --  @param Timeline Nonzero timeline whose history is requested.
   --  @return Simple Query message containing TIMELINE_HISTORY.
   --  @exception Protocol.Protocol_Error Timeline is zero.

   type Snapshot_Action is (Export_Snapshot, No_Snapshot, Use_Snapshot);
   --  Snapshot policy requested while creating a logical replication slot.
   --  @enum Export_Snapshot Export a new snapshot to a separate SQL session.
   --  @enum No_Snapshot Create the slot without exporting a snapshot.
   --  @enum Use_Snapshot Bind the slot to the repeatable-read snapshot of the
   --     current SQL session.

   function Create_Logical_Slot
     (Slot_Name : String;
      Plugin    : String := "pgoutput";
      Snapshot  : Snapshot_Action := Export_Snapshot) return Protocol.Message;
   --  Construct PostgreSQL 15-or-newer logical slot creation syntax.
   --  @param Slot_Name Valid lowercase replication slot identifier.
   --  @param Plugin Logical output plugin name.
   --  @param Snapshot Snapshot policy for slot consistency.
   --  @return Simple Query message containing CREATE_REPLICATION_SLOT.
   --  @exception Protocol_Error A name is invalid.

   function Drop_Replication_Slot
     (Slot_Name : String; Wait : Boolean := False) return Protocol.Message;
   --  Construct a replication slot drop command.
   --  @param Slot_Name Valid lowercase replication slot identifier.
   --  @param Wait Include WAIT when an active owner should be awaited.
   --  @return Simple Query message containing DROP_REPLICATION_SLOT.
   --  @exception Protocol_Error Slot_Name is invalid.

   function Start_Physical
     (Position  : LSN;
      Slot_Name : String := "";
      Timeline  : UInt32 := 0) return Protocol.Message;
   --  Construct physical START_REPLICATION syntax.
   --  @param Position First WAL position requested from the primary.
   --  @param Slot_Name Optional physical replication slot identifier.
   --  @param Timeline Optional nonzero timeline; zero omits TIMELINE.
   --  @return Simple Query message containing START_REPLICATION.
   --  @exception Protocol.Protocol_Error Slot_Name is invalid.

   function Start_Logical
     (Slot_Name : String;
      Position  : LSN;
      Options   : Logical_Option_Array := No_Logical_Options)
      return Protocol.Message;
   --  Construct logical START_REPLICATION syntax.
   --  @param Slot_Name Required logical replication slot identifier.
   --  @param Position First logical decoding position requested.
   --  @param Options Ordered output-plugin options.
   --  @return Simple Query message containing START_REPLICATION SLOT.
   --  @exception Protocol.Protocol_Error Slot_Name or an option is invalid.

   type Command_Kind is
     (Identify_System_Command,
      Show_Command,
      Timeline_History_Command,
      Create_Logical_Slot_Command,
      Drop_Replication_Slot_Command,
      Start_Physical_Command,
      Start_Logical_Command);
   --  Replication-mode simple-query command classification.
   --  @enum Identify_System_Command IDENTIFY_SYSTEM.
   --  @enum Show_Command SHOW parameter.
   --  @enum Timeline_History_Command TIMELINE_HISTORY timeline.
   --  @enum Create_Logical_Slot_Command CREATE_REPLICATION_SLOT LOGICAL.
   --  @enum Drop_Replication_Slot_Command DROP_REPLICATION_SLOT.
   --  @enum Start_Physical_Command Physical START_REPLICATION.
   --  @enum Start_Logical_Command Logical START_REPLICATION SLOT.

   type Command is private;
   --  Validated decoded replication-mode command with owned source message.

   function Decode_Command (Item : Protocol.Message) return Command;
   --  Decode the command grammar emitted by PostgreSQL and the constructors in
   --  this package.
   --  @param Item Simple Query message containing one replication command.
   --  @return Validated decoded command.
   --  @exception Protocol.Protocol_Error The message or command is malformed.
   function Kind (Item : Command) return Command_Kind;
   --  Return a decoded replication command's variant.
   --  @param Item Decoded command.
   --  @return Its command variant.
   function Original_Message (Item : Command) return Protocol.Message;
   --  Return the Query message retained by a decoded command.
   --  @param Item Decoded command.
   --  @return Owned copy of the original Query message.

   function Parameter (Item : Command) return String;
   --  Return the parameter named by a SHOW command.
   --  @param Item SHOW command.
   --  @return SHOW parameter name.
   --  @exception Protocol.Protocol_Error Item is not a SHOW command.

   function Slot_Name (Item : Command) return String;
   --  Return the slot named by create, drop, or START_REPLICATION. A physical
   --  start without a slot returns the empty string.
   --  @param Item Command with an applicable slot field.
   --  @return Slot name, possibly empty for physical streaming.
   --  @exception Protocol.Protocol_Error Item has no slot field.
   function Plugin (Item : Command) return String;
   --  Return the plugin named by CREATE_REPLICATION_SLOT.
   --  @param Item CREATE_REPLICATION_SLOT command.
   --  @return Output plugin name.
   --  @exception Protocol.Protocol_Error Item is another command kind.
   function Snapshot (Item : Command) return Snapshot_Action;
   --  Return the snapshot policy named by CREATE_REPLICATION_SLOT.
   --  @param Item CREATE_REPLICATION_SLOT command.
   --  @return Requested snapshot policy.
   --  @exception Protocol.Protocol_Error Item is another command kind.
   function Wait (Item : Command) return Boolean;
   --  Test whether DROP_REPLICATION_SLOT included WAIT.
   --  @param Item DROP_REPLICATION_SLOT command.
   --  @return True when the command included WAIT.
   --  @exception Protocol.Protocol_Error Item is another command kind.
   function Position (Item : Command) return LSN;
   --  Return the position named by START_REPLICATION.
   --  @param Item START_REPLICATION command.
   --  @return Requested start LSN.
   --  @exception Protocol.Protocol_Error Item is not a start command.

   function Has_Timeline (Item : Command) return Boolean;
   --  Test whether a command includes a timeline value.
   --  @param Item TIMELINE_HISTORY or physical START_REPLICATION command.
   --  @return True when a timeline value is present.
   --  @exception Protocol.Protocol_Error Item cannot contain a timeline.
   function Timeline (Item : Command) return UInt32;
   --  Return a command's timeline identifier.
   --  @param Item Command for which Has_Timeline is True.
   --  @return Requested timeline identifier.
   --  @exception Protocol.Protocol_Error No timeline is present.

   function Options (Item : Command) return Logical_Option_Array;
   --  Return logical START_REPLICATION options, preserving valueless options
   --  versus options whose explicit value is empty.
   --  @param Item Logical START_REPLICATION command.
   --  @return Ordered plugin options.
   --  @exception Protocol.Protocol_Error Item is not a logical start command.

   type Stream_Message_Kind is
     (XLog_Data,
      Primary_Keepalive,
      Standby_Status_Update,
      Hot_Standby_Feedback);
   --  Replication CopyData payload classification.
   --  @enum XLog_Data Primary WAL or logical output data.
   --  @enum Primary_Keepalive Primary liveness and WAL-end update.
   --  @enum Standby_Status_Update Standby's write, flush, and apply progress.
   --  @enum Hot_Standby_Feedback Standby's oldest required transaction IDs.

   type Stream_Message is private;
   --  Validated decoded replication streaming message with owned payload.

   function Decode (Item : Protocol.Message) return Stream_Message;
   --  Decode the payload of a CopyData message used by physical or logical
   --  streaming replication.
   --  @param Item CopyData protocol message.
   --  @return Classified replication stream message.
   --  @exception Protocol.Protocol_Error The payload is malformed or unknown.
   function Kind (Item : Stream_Message) return Stream_Message_Kind;
   --  Return a decoded replication stream message's variant.
   --  @param Item Decoded stream message.
   --  @return Its payload variant.
   function Original_Message (Item : Stream_Message) return Protocol.Message;
   --  Return the CopyData message retained by a decoded stream event.
   --  @param Item Decoded stream message.
   --  @return Owned copy of the original CopyData message.

   function WAL_Start (Item : Stream_Message) return LSN;
   --  Return the first LSN represented by an XLogData message.
   --  @param Item XLog_Data message.
   --  @return LSN of the first byte represented by Data.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function WAL_End (Item : Stream_Message) return LSN;
   --  Return the primary's advertised end-of-WAL position.
   --  @param Item XLog_Data or Primary_Keepalive message.
   --  @return Primary's current end-of-WAL position.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Sent_At (Item : Stream_Message) return Replication_Timestamp;
   --  Return a stream message's sender timestamp.
   --  @param Item Any decoded stream message.
   --  @return Sender's PostgreSQL-epoch timestamp.
   function Data (Item : Stream_Message) return Byte_Array;
   --  Copy the WAL or logical payload carried by XLogData.
   --  @param Item XLog_Data message.
   --  @return WAL or logical-output bytes.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Reply_Requested (Item : Stream_Message) return Boolean;
   --  Test whether a stream message requests an immediate response.
   --  @param Item Keepalive or standby-status message.
   --  @return True when an immediate response was requested.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Received_LSN (Item : Stream_Message) return LSN;
   --  Return the standby's last written WAL position.
   --  @param Item Standby_Status_Update message.
   --  @return Last WAL byte written by the standby.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Flushed_LSN (Item : Stream_Message) return LSN;
   --  Return the standby's last durably flushed WAL position.
   --  @param Item Standby_Status_Update message.
   --  @return Last WAL byte flushed durably by the standby.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Applied_LSN (Item : Stream_Message) return LSN;
   --  Return the standby's last applied WAL position.
   --  @param Item Standby_Status_Update message.
   --  @return Last WAL byte applied by the standby.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Feedback_Xmin (Item : Stream_Message) return Transaction_Id;
   --  Return the standby's oldest required regular transaction ID.
   --  @param Item Hot_Standby_Feedback message.
   --  @return Oldest regular transaction still needed by the standby.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Feedback_Xmin_Epoch (Item : Stream_Message) return UInt32;
   --  Return the epoch associated with feedback Xmin.
   --  @param Item Hot_Standby_Feedback message.
   --  @return Epoch disambiguating Feedback_Xmin wraparound.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Feedback_Catalog_Xmin
     (Item : Stream_Message) return Transaction_Id;
   --  Return the standby's oldest required catalog transaction ID.
   --  @param Item Hot_Standby_Feedback message.
   --  @return Oldest catalog transaction still needed by the standby.
   --  @exception Protocol.Protocol_Error Item is another variant.
   function Feedback_Catalog_Xmin_Epoch
     (Item : Stream_Message) return UInt32;
   --  Return the epoch associated with feedback catalog Xmin.
   --  @param Item Hot_Standby_Feedback message.
   --  @return Epoch disambiguating catalog-Xmin wraparound.
   --  @exception Protocol.Protocol_Error Item is another variant.

   function Make_XLog_Data
     (WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array) return Protocol.Message;
   --  Construct a primary XLogData CopyData message.
   --  @param WAL_Start LSN of the first byte represented by Data.
   --  @param WAL_End Primary's current end-of-WAL position.
   --  @param Sent_At Current PostgreSQL replication timestamp.
   --  @param Data Raw WAL or logical-output bytes.
   --  @return Encoded CopyData protocol message.

   function Make_Primary_Keepalive
     (WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message;
   --  Construct a primary keepalive CopyData message.
   --  @param WAL_End Primary's current end-of-WAL position.
   --  @param Sent_At Current PostgreSQL replication timestamp.
   --  @param Reply_Requested Ask the standby for immediate status feedback.
   --  @return Encoded CopyData protocol message.

   function Make_Standby_Status_Update
     (Received_LSN    : LSN;
      Flushed_LSN     : LSN;
      Applied_LSN     : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message;
   --  Construct a standby status-update CopyData message.
   --  @param Received_LSN Last WAL byte written locally.
   --  @param Flushed_LSN Last WAL byte flushed durably.
   --  @param Applied_LSN Last WAL byte applied.
   --  @param Sent_At Current PostgreSQL replication timestamp.
   --  @param Reply_Requested Request an immediate primary reply.
   --  @return Encoded CopyData protocol message.

   function Make_Hot_Standby_Feedback
     (Sent_At            : Replication_Timestamp;
      Xmin               : Transaction_Id;
      Xmin_Epoch         : UInt32;
      Catalog_Xmin       : Transaction_Id;
      Catalog_Xmin_Epoch : UInt32) return Protocol.Message;
   --  Construct a hot-standby feedback CopyData message.
   --  @param Sent_At Current PostgreSQL replication timestamp.
   --  @param Xmin Oldest regular transaction still required.
   --  @param Xmin_Epoch Epoch disambiguating Xmin wraparound.
   --  @param Catalog_Xmin Oldest catalog transaction still required.
   --  @param Catalog_Xmin_Epoch Epoch disambiguating catalog-Xmin wraparound.
   --  @return Encoded CopyData protocol message.

private
   type Logical_Option is record
      Name : Flyology.Bytes.Unbounded_Bytes;
      Data : Flyology.Bytes.Unbounded_Bytes;
      Has_Value : Boolean := False;
   end record;

   No_Logical_Options : constant Logical_Option_Array (1 .. 0) :=
     (others =>
        (Name => Flyology.Bytes.Empty,
         Data => Flyology.Bytes.Empty,
         Has_Value => False));

   type Stream_Message is record
      Message_Kind       : Stream_Message_Kind := XLog_Data;
      Raw                : Protocol.Message;
      First_LSN          : LSN := 0;
      Second_LSN         : LSN := 0;
      Third_LSN          : LSN := 0;
      Timestamp          : Replication_Timestamp := 0;
      Reply              : Boolean := False;
      Bytes              : Flyology.Bytes.Unbounded_Bytes;
      Xmin_Value         : Transaction_Id := 0;
      Xmin_Epoch_Value   : UInt32 := 0;
      Catalog_Xmin_Value : Transaction_Id := 0;
      Catalog_Epoch      : UInt32 := 0;
   end record;

   type Command is record
      Message_Kind     : Command_Kind := Identify_System_Command;
      Raw              : Protocol.Message;
      Parameter_Data   : Flyology.Bytes.Unbounded_Bytes;
      Slot_Data        : Flyology.Bytes.Unbounded_Bytes;
      Plugin_Data      : Flyology.Bytes.Unbounded_Bytes;
      Start_Position   : LSN := 0;
      Timeline_Value   : UInt32 := 0;
      Timeline_Present : Boolean := False;
      Snapshot_Value   : Snapshot_Action := Export_Snapshot;
      Wait_Value       : Boolean := False;
      Options_Data     : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Replication;
