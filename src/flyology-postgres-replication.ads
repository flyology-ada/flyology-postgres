with Ada.Streams;
with Interfaces;
with Flyology.Postgres.Protocol;
private with Flyology.Bytes;

package Flyology.Postgres.Replication is

   subtype Byte is Ada.Streams.Stream_Element;
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype UInt32 is Interfaces.Unsigned_32;
   subtype UInt64 is Interfaces.Unsigned_64;
   subtype Int64 is Interfaces.Integer_64;

   subtype LSN is UInt64;
   subtype Replication_Timestamp is Int64;
   subtype Transaction_Id is UInt32;

   function Image (Value : LSN) return String;
   function Value (Text : String) return LSN;

   type Logical_Option is private;
   type Logical_Option_Array is array (Positive range <>) of Logical_Option;
   No_Logical_Options : constant Logical_Option_Array (1 .. 0);

   function Option (Name : String) return Logical_Option;
   function Option (Name : String; Value : String) return Logical_Option;
   function Option_Name (Item : Logical_Option) return String;
   function Option_Value (Item : Logical_Option) return String;
   function Option_Has_Value (Item : Logical_Option) return Boolean;

   function Identify_System return Protocol.Message;
   function Show (Parameter : String) return Protocol.Message;
   function Timeline_History (Timeline : UInt32) return Protocol.Message;

   function Start_Physical
     (Position  : LSN;
      Slot_Name : String := "";
      Timeline  : UInt32 := 0) return Protocol.Message;

   function Start_Logical
     (Slot_Name : String;
      Position  : LSN;
      Options   : Logical_Option_Array := No_Logical_Options)
      return Protocol.Message;

   type Command_Kind is
     (Identify_System_Command,
      Show_Command,
      Timeline_History_Command,
      Start_Physical_Command,
      Start_Logical_Command);

   type Command is private;

   --  Decode a replication-mode simple Query.  The accepted grammar is the
   --  command grammar emitted by PostgreSQL and by the constructors above;
   --  malformed or non-replication queries raise Protocol_Error.
   function Decode_Command (Item : Protocol.Message) return Command;
   function Kind (Item : Command) return Command_Kind;
   function Original_Message (Item : Command) return Protocol.Message;

   --  SHOW parameter.  Other command kinds raise Protocol_Error.
   function Parameter (Item : Command) return String;

   --  Empty for a physical START_REPLICATION without a slot.  Logical
   --  replication always has a slot.
   function Slot_Name (Item : Command) return String;
   function Position (Item : Command) return LSN;

   --  TIMELINE_HISTORY always has a timeline.  A physical start only has one
   --  when Has_Timeline is true.
   function Has_Timeline (Item : Command) return Boolean;
   function Timeline (Item : Command) return UInt32;

   --  Logical START_REPLICATION options, preserving the distinction between
   --  a valueless option and an option whose value is the empty string.
   function Options (Item : Command) return Logical_Option_Array;

   type Stream_Message_Kind is
     (XLog_Data,
      Primary_Keepalive,
      Standby_Status_Update,
      Hot_Standby_Feedback);

   type Stream_Message is private;

   --  Decode the payload of a CopyData message used by physical or logical
   --  streaming replication. Logical output is the Data of XLog_Data.
   function Decode (Item : Protocol.Message) return Stream_Message;
   function Kind (Item : Stream_Message) return Stream_Message_Kind;
   function Original_Message (Item : Stream_Message) return Protocol.Message;

   function WAL_Start (Item : Stream_Message) return LSN;
   function WAL_End (Item : Stream_Message) return LSN;
   function Sent_At (Item : Stream_Message) return Replication_Timestamp;
   function Data (Item : Stream_Message) return Byte_Array;
   function Reply_Requested (Item : Stream_Message) return Boolean;

   function Received_LSN (Item : Stream_Message) return LSN;
   function Flushed_LSN (Item : Stream_Message) return LSN;
   function Applied_LSN (Item : Stream_Message) return LSN;

   function Feedback_Xmin (Item : Stream_Message) return Transaction_Id;
   function Feedback_Xmin_Epoch (Item : Stream_Message) return UInt32;
   function Feedback_Catalog_Xmin
     (Item : Stream_Message) return Transaction_Id;
   function Feedback_Catalog_Xmin_Epoch
     (Item : Stream_Message) return UInt32;

   function Make_XLog_Data
     (WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array) return Protocol.Message;

   function Make_Primary_Keepalive
     (WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message;

   function Make_Standby_Status_Update
     (Received_LSN    : LSN;
      Flushed_LSN     : LSN;
      Applied_LSN     : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message;

   function Make_Hot_Standby_Feedback
     (Sent_At            : Replication_Timestamp;
      Xmin               : Transaction_Id;
      Xmin_Epoch         : UInt32;
      Catalog_Xmin       : Transaction_Id;
      Catalog_Xmin_Epoch : UInt32) return Protocol.Message;

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
      Start_Position   : LSN := 0;
      Timeline_Value   : UInt32 := 0;
      Timeline_Present : Boolean := False;
      Options_Data     : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Replication;
