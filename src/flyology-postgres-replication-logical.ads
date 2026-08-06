with Ada.Streams;
with Interfaces;
private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;
private with Flyology.Bytes;

package Flyology.Postgres.Replication.Logical is

   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;

   subtype Byte is Ada.Streams.Stream_Element;
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype UInt32 is Interfaces.Unsigned_32;
   subtype Int32 is Interfaces.Integer_32;
   subtype LSN is Replication.LSN;
   subtype Replication_Timestamp is Replication.Replication_Timestamp;
   subtype Transaction_Id is Replication.Transaction_Id;

   type Protocol_Version is range 1 .. 4;
   type Streaming_Mode is (Disabled, In_Progress, Parallel);

   function Minimum_Server_Major (Version : Protocol_Version) return Positive;
   function Configuration_Is_Valid
     (Version : Protocol_Version; Streaming : Streaming_Mode) return Boolean;

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

   type Message_Level is
     (Transaction_Control, Transaction_Metadata, Row_Change);

   type Tuple_Value_Kind is
     (Null_Value, Unchanged_Toast_Value, Text_Value, Binary_Value);
   type Tuple_Value is private;
   type Tuple_Value_Array is array (Positive range <>) of Tuple_Value;
   type Tuple_Data is private;
   Empty_Tuple : constant Tuple_Data;

   function Null_Column return Tuple_Value;
   function Unchanged_Toast_Column return Tuple_Value;
   function Text_Column (Value : String) return Tuple_Value;
   function Binary_Column (Value : Byte_Array) return Tuple_Value;
   function Make_Tuple (Columns : Tuple_Value_Array) return Tuple_Data;

   function Column_Count (Item : Tuple_Data) return Natural;
   function Column
     (Item : Tuple_Data; Index : Positive) return Tuple_Value;
   function Kind (Item : Tuple_Value) return Tuple_Value_Kind;
   function Value (Item : Tuple_Value) return Byte_Array;
   function Text (Item : Tuple_Value) return String;

   type Relation_Column is private;
   type Relation_Column_Array is
     array (Positive range <>) of Relation_Column;

   function Make_Relation_Column
     (Name          : String;
      Type_Oid      : UInt32;
      Type_Modifier : Int32 := -1;
      Is_Key        : Boolean := False) return Relation_Column;
   function Is_Key (Item : Relation_Column) return Boolean;
   function Name (Item : Relation_Column) return String;
   function Type_Oid (Item : Relation_Column) return UInt32;
   function Type_Modifier (Item : Relation_Column) return Int32;

   type Replica_Identity is
     (Default_Identity,
      Nothing_Identity,
      Full_Identity,
      Index_Identity);

   type Old_Tuple_Kind is
     (No_Old_Tuple, Key_Old_Tuple, Full_Old_Tuple);

   type Message is private;

   type Relation_Id_Array is array (Positive range <>) of UInt32;
   No_Relation_Ids : constant Relation_Id_Array (1 .. 0) :=
     (others => 0);

   function Make_Begin
     (Final_LSN : LSN;
      Commit_At : Replication_Timestamp;
      Xid       : Transaction_Id) return Message;
   function Make_Commit
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message;
   function Make_Origin
     (Commit_LSN : LSN; Name : String) return Message;
   function Make_Logical_Decoding_Message
     (Message_LSN   : LSN;
      Prefix        : String;
      Content       : Byte_Array;
      Transactional : Boolean := False;
      Xid           : Transaction_Id := 0) return Message;
   function Make_Relation
     (Relation_Id : UInt32;
      Namespace   : String;
      Name        : String;
      Identity    : Replica_Identity;
      Columns     : Relation_Column_Array;
      Xid         : Transaction_Id := 0) return Message;
   function Make_Type
     (Type_Oid  : UInt32;
      Namespace : String;
      Name      : String;
      Xid       : Transaction_Id := 0) return Message;
   function Make_Insert
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message;
   function Make_Update
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Old_Kind    : Old_Tuple_Kind := No_Old_Tuple;
      Old_Tuple   : Tuple_Data := Empty_Tuple;
      Xid         : Transaction_Id := 0) return Message;
   function Make_Delete
     (Relation_Id : UInt32;
      Old_Kind    : Old_Tuple_Kind;
      Old_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message;
   function Make_Truncate
     (Relations        : Relation_Id_Array;
      Cascade          : Boolean := False;
      Restart_Identity : Boolean := False;
      Xid              : Transaction_Id := 0) return Message;
   function Make_Stream_Start
     (Xid : Transaction_Id; First_Segment : Boolean) return Message;
   function Make_Stream_Stop return Message;
   function Make_Stream_Commit
     (Xid        : Transaction_Id;
      Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message;
   function Make_Stream_Abort
     (Xid        : Transaction_Id;
      Subxid     : Transaction_Id;
      Abort_LSN  : LSN := 0;
      Aborted_At : Replication_Timestamp := 0) return Message;
   function Make_Begin_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;
   function Make_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;
   function Make_Commit_Prepared
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp;
      Xid        : Transaction_Id;
      GID        : String) return Message;
   function Make_Rollback_Prepared
     (Prepare_End_LSN  : LSN;
      Rollback_End_LSN : LSN;
      Prepare_At       : Replication_Timestamp;
      Rollback_At      : Replication_Timestamp;
      Xid              : Transaction_Id;
      GID              : String) return Message;
   function Make_Stream_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message;

   function Encode
     (Item      : Message;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled) return Byte_Array;

   function Decode
     (Data      : Byte_Array;
      Version   : Protocol_Version;
      Streamed  : Boolean := False;
      Streaming : Streaming_Mode := Disabled) return Message;

   type Decoder is private;
   procedure Configure
     (Item      : out Decoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled);
   procedure Reset (Item : in out Decoder);
   function Decode
     (Item : in out Decoder; Data : Byte_Array) return Message;
   function Inside_Stream (Item : Decoder) return Boolean;

   function Kind (Item : Message) return Message_Kind;
   function Level (Item : Message) return Message_Level;
   function Version (Item : Message) return Protocol_Version;
   function Is_Streamed (Item : Message) return Boolean;

   function Transaction (Item : Message) return Transaction_Id;
   function Subtransaction (Item : Message) return Transaction_Id;

   function Final_LSN (Item : Message) return LSN;
   function Commit_LSN (Item : Message) return LSN;
   function Prepare_LSN (Item : Message) return LSN;
   function Prepare_End_LSN (Item : Message) return LSN;
   function End_LSN (Item : Message) return LSN;
   function Origin_Commit_LSN (Item : Message) return LSN;
   function Abort_LSN (Item : Message) return LSN;
   function Event_Timestamp
     (Item : Message) return Replication_Timestamp;
   function Rollback_Timestamp
     (Item : Message) return Replication_Timestamp;

   function GID (Item : Message) return String;
   function Origin_Name (Item : Message) return String;
   function Is_Transactional (Item : Message) return Boolean;
   function Message_LSN (Item : Message) return LSN;
   function Prefix (Item : Message) return String;
   function Content (Item : Message) return Byte_Array;

   function Relation_Id (Item : Message) return UInt32;
   function Type_Id (Item : Message) return UInt32;
   function Namespace_Name (Item : Message) return String;
   function Object_Name (Item : Message) return String;
   function Identity (Item : Message) return Replica_Identity;
   function Relation_Column_Count (Item : Message) return Natural;
   function Relation_Column_At
     (Item : Message; Index : Positive) return Relation_Column;

   function New_Tuple (Item : Message) return Tuple_Data;
   function Old_Kind (Item : Message) return Old_Tuple_Kind;
   function Old_Tuple (Item : Message) return Tuple_Data;

   function Truncated_Relation_Count (Item : Message) return Natural;
   function Truncated_Relation
     (Item : Message; Index : Positive) return UInt32;
   function Cascade (Item : Message) return Boolean;
   function Restart_Identity (Item : Message) return Boolean;

   function Is_First_Stream_Segment (Item : Message) return Boolean;

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
