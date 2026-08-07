with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Replication.Logical is

   use type Ada.Containers.Count_Type;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;

   package Protocol renames Flyology.Postgres.Protocol;
   package Wire renames Flyology.Postgres.Wire;

   subtype UInt16 is Interfaces.Unsigned_16;
   subtype UInt64 is Interfaces.Unsigned_64;

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Information;
      end if;
   end Require;

   function Minimum_Server_Major
     (Version : Protocol_Version) return Positive is
     (case Version is
         when 1 => 10,
         when 2 => 14,
         when 3 => 15,
         when 4 => 16);

   function Configuration_Is_Valid
     (Version : Protocol_Version; Streaming : Streaming_Mode) return Boolean is
     (case Streaming is
         when Disabled    => True,
         when In_Progress => Version >= 2,
         when Parallel    => Version = 4);

   function View_To_Bytes
     (Source : Byte_Array; View : Wire.Byte_View) return Byte_Array is
      Result : Byte_Array (1 .. Ada.Streams.Stream_Element_Offset
        (View.Length));
   begin
      for Index in Result'Range loop
         Result (Index) := Wire.Element_At
           (Source,
            View.First + Wire.Wire_Length (Index - Result'First));
      end loop;
      return Result;
   end View_To_Bytes;

   function View_To_String
     (Source : Byte_Array; View : Wire.Byte_View) return String is
      Result : String (1 .. Natural (View.Length));
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (Wire.Element_At
              (Source,
               View.First + Wire.Wire_Length (Index - Result'First)));
      end loop;
      return Result;
   end View_To_String;

   function Read_Byte
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return Byte is
   begin
      Require (Cursor < Data'Length, "truncated " & Context);
      declare
         Result : constant Byte := Wire.Element_At (Data, Cursor);
      begin
         Cursor := Cursor + 1;
         return Result;
      end;
   end Read_Byte;

   function Read_U16
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return UInt16 is
      Result  : UInt16;
      Success : Boolean;
   begin
      Wire.Try_Read_U16 (Data, Cursor, Result, Success);
      Require (Success, "truncated " & Context);
      return Result;
   end Read_U16;

   function Read_U32
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return UInt32 is
      Result  : UInt32;
      Success : Boolean;
   begin
      Wire.Try_Read_U32 (Data, Cursor, Result, Success);
      Require (Success, "truncated " & Context);
      return Result;
   end Read_U32;

   function Read_U64
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return UInt64 is
      Result  : UInt64;
      Success : Boolean;
   begin
      Wire.Try_Read_U64 (Data, Cursor, Result, Success);
      Require (Success, "truncated " & Context);
      return Result;
   end Read_U64;

   function Read_LSN
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return LSN is
     (LSN (Read_U64 (Data, Cursor, Context)));

   function Read_Time
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return Replication_Timestamp is
     (Wire.To_Int64_Bits (Read_U64 (Data, Cursor, Context)));

   function Read_String
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Context : String) return String is
      View    : Wire.Byte_View;
      Success : Boolean;
   begin
      Wire.Try_Read_C_String (Data, Cursor, View, Success);
      Require (Success, "unterminated " & Context);
      return View_To_String (Data, View);
   end Read_String;

   function Read_Bytes
     (Data    : Byte_Array;
      Cursor  : in out Wire.Wire_Length;
      Count   : Wire.Wire_Length;
      Context : String) return Byte_Array is
      View    : Wire.Byte_View;
      Success : Boolean;
   begin
      Wire.Try_Read_Bytes (Data, Cursor, Count, View, Success);
      Require (Success, "truncated " & Context);
      return View_To_Bytes (Data, View);
   end Read_Bytes;

   procedure Require_End
     (Data : Byte_Array; Cursor : Wire.Wire_Length; Context : String) is
   begin
      Require (Cursor = Data'Length, Context & " has trailing data");
   end Require_End;

   function Read_Tuple
     (Data : Byte_Array; Cursor : in out Wire.Wire_Length) return Tuple_Data is
      Count  : constant UInt16 :=
        Read_U16 (Data, Cursor, "TupleData column count");
      Result : Tuple_Data;
   begin
      Require
        (Wire.Count_Fits
           (Data'Length - Cursor, Count, Minimum_Item_Length => 1),
         "TupleData column count exceeds its payload");
      Result.Columns.Reserve_Capacity
        (Ada.Containers.Count_Type (Count));
      for Index in 1 .. Natural (Count) loop
         pragma Unreferenced (Index);
         declare
            Tag : constant Character := Character'Val
              (Read_Byte (Data, Cursor, "TupleData column tag"));
         begin
            case Tag is
               when 'n' =>
                  Result.Columns.Append
                    ((Value_Kind => Null_Value,
                      Data       => Flyology.Bytes.Empty));
               when 'u' =>
                  Result.Columns.Append
                    ((Value_Kind => Unchanged_Toast_Value,
                      Data       => Flyology.Bytes.Empty));
               when 't' | 'b' =>
                  declare
                     Length : constant UInt32 :=
                       Read_U32 (Data, Cursor, "TupleData value length");
                  begin
                     Require
                       (UInt64 (Length) <= UInt64 (Data'Length - Cursor),
                        "TupleData value length exceeds its payload");
                     Result.Columns.Append
                       ((Value_Kind =>
                           (if Tag = 't' then Text_Value else Binary_Value),
                         Data       => Flyology.Bytes.To_Unbounded_Bytes
                           (Read_Bytes
                              (Data,
                               Cursor,
                               Wire.Wire_Length (Length),
                               "TupleData value"))));
                  end;
               when others =>
                  raise Protocol.Protocol_Error with
                    "invalid TupleData column tag";
            end case;
         end;
      end loop;
      return Result;
   end Read_Tuple;

   procedure Read_Stream_Xid
     (Result   : in out Message;
      Data     : Byte_Array;
      Cursor   : in out Wire.Wire_Length;
      Streamed : Boolean) is
   begin
      Result.Streamed := Streamed;
      if Streamed then
         Result.Xid := Read_U32 (Data, Cursor, "streamed transaction ID");
      end if;
   end Read_Stream_Xid;

   function Null_Column return Tuple_Value is
     ((Value_Kind => Null_Value, Data => Flyology.Bytes.Empty));

   function Unchanged_Toast_Column return Tuple_Value is
     ((Value_Kind => Unchanged_Toast_Value, Data => Flyology.Bytes.Empty));

   function Text_Column (Value : String) return Tuple_Value is
     ((Value_Kind => Text_Value,
       Data       => Flyology.Bytes.From_Byte_String (Value)));

   function Binary_Column (Value : Byte_Array) return Tuple_Value is
     ((Value_Kind => Binary_Value,
       Data       => Flyology.Bytes.To_Unbounded_Bytes (Value)));

   function Make_Tuple (Columns : Tuple_Value_Array) return Tuple_Data is
      Result : Tuple_Data;
   begin
      Result.Columns.Reserve_Capacity
        (Ada.Containers.Count_Type (Columns'Length));
      for Item of Columns loop
         Result.Columns.Append (Item);
      end loop;
      return Result;
   end Make_Tuple;

   function Make_Relation_Column
     (Name          : String;
      Type_Oid      : UInt32;
      Type_Modifier : Int32 := -1;
      Is_Key        : Boolean := False) return Relation_Column is
   begin
      return
        (Key      => Is_Key,
         Label    => To_Unbounded_String (Name),
         Oid      => Type_Oid,
         Modifier => Type_Modifier);
   end Make_Relation_Column;

   function Make_Begin
     (Final_LSN : LSN;
      Commit_At : Replication_Timestamp;
      Xid       : Transaction_Id) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Begin_Message;
      Result.First_Position := Final_LSN;
      Result.First_Time := Commit_At;
      Result.Xid := Xid;
      return Result;
   end Make_Begin;

   function Make_Commit
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Commit_Message;
      Result.First_Position := Commit_LSN;
      Result.Second_Position := End_LSN;
      Result.First_Time := Commit_At;
      return Result;
   end Make_Commit;

   function Make_Origin
     (Commit_LSN : LSN; Name : String) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Origin_Message;
      Result.First_Position := Commit_LSN;
      Result.First_Text := To_Unbounded_String (Name);
      return Result;
   end Make_Origin;

   function Make_Logical_Decoding_Message
     (Message_LSN   : LSN;
      Prefix        : String;
      Content       : Byte_Array;
      Transactional : Boolean := False;
      Xid           : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Logical_Decoding_Message;
      Result.First_Position := Message_LSN;
      Result.First_Text := To_Unbounded_String (Prefix);
      Result.Bytes := Flyology.Bytes.To_Unbounded_Bytes (Content);
      Result.Flag := Transactional;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      return Result;
   end Make_Logical_Decoding_Message;

   function Make_Relation
     (Relation_Id : UInt32;
      Namespace   : String;
      Name        : String;
      Identity    : Replica_Identity;
      Columns     : Relation_Column_Array;
      Xid         : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Relation_Message;
      Result.Relation := Relation_Id;
      Result.First_Text := To_Unbounded_String (Namespace);
      Result.Second_Text := To_Unbounded_String (Name);
      Result.Replica := Identity;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      Result.Relation_Columns.Reserve_Capacity
        (Ada.Containers.Count_Type (Columns'Length));
      for Item of Columns loop
         Result.Relation_Columns.Append (Item);
      end loop;
      return Result;
   end Make_Relation;

   function Make_Type
     (Type_Oid  : UInt32;
      Namespace : String;
      Name      : String;
      Xid       : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Type_Message;
      Result.Relation := Type_Oid;
      Result.First_Text := To_Unbounded_String (Namespace);
      Result.Second_Text := To_Unbounded_String (Name);
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      return Result;
   end Make_Type;

   function Make_Insert
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Insert_Message;
      Result.Relation := Relation_Id;
      Result.After := New_Tuple;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      return Result;
   end Make_Insert;

   function Make_Update
     (Relation_Id : UInt32;
      New_Tuple   : Tuple_Data;
      Old_Kind    : Old_Tuple_Kind := No_Old_Tuple;
      Old_Tuple   : Tuple_Data := Empty_Tuple;
      Xid         : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Update_Message;
      Result.Relation := Relation_Id;
      Result.After := New_Tuple;
      Result.Before_Kind := Old_Kind;
      Result.Before := Old_Tuple;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      return Result;
   end Make_Update;

   function Make_Delete
     (Relation_Id : UInt32;
      Old_Kind    : Old_Tuple_Kind;
      Old_Tuple   : Tuple_Data;
      Xid         : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Require
        (Old_Kind /= No_Old_Tuple,
         "Delete requires a key or full old tuple");
      Result.Message_Type := Delete_Message;
      Result.Relation := Relation_Id;
      Result.Before_Kind := Old_Kind;
      Result.Before := Old_Tuple;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      return Result;
   end Make_Delete;

   function Make_Truncate
     (Relations        : Relation_Id_Array;
      Cascade          : Boolean := False;
      Restart_Identity : Boolean := False;
      Xid              : Transaction_Id := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Truncate_Message;
      Result.Truncate_Cascade := Cascade;
      Result.Truncate_Restart := Restart_Identity;
      Result.Xid := Xid;
      Result.Streamed := Xid /= 0;
      Result.Relation_Oids.Reserve_Capacity
        (Ada.Containers.Count_Type (Relations'Length));
      for Item of Relations loop
         Result.Relation_Oids.Append (Item);
      end loop;
      return Result;
   end Make_Truncate;

   function Make_Stream_Start
     (Xid : Transaction_Id; First_Segment : Boolean) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Stream_Start_Message;
      Result.Xid := Xid;
      Result.Flag := First_Segment;
      return Result;
   end Make_Stream_Start;

   function Make_Stream_Stop return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Stream_Stop_Message;
      return Result;
   end Make_Stream_Stop;

   function Make_Stream_Commit
     (Xid        : Transaction_Id;
      Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Stream_Commit_Message;
      Result.Xid := Xid;
      Result.First_Position := Commit_LSN;
      Result.Second_Position := End_LSN;
      Result.First_Time := Commit_At;
      return Result;
   end Make_Stream_Commit;

   function Make_Stream_Abort
     (Xid        : Transaction_Id;
      Subxid     : Transaction_Id;
      Abort_LSN  : LSN := 0;
      Aborted_At : Replication_Timestamp := 0) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Stream_Abort_Message;
      Result.Xid := Xid;
      Result.Subxid := Subxid;
      Result.First_Position := Abort_LSN;
      Result.First_Time := Aborted_At;
      return Result;
   end Make_Stream_Abort;

   function Make_Prepared_Message
     (Kind       : Message_Kind;
      First_LSN  : LSN;
      End_LSN    : LSN;
      Event_At   : Replication_Timestamp;
      Xid        : Transaction_Id;
      GID        : String) return Message is
      Result : Message := (others => <>);
   begin
      Result.Message_Type := Kind;
      Result.First_Position := First_LSN;
      Result.Second_Position := End_LSN;
      Result.First_Time := Event_At;
      Result.Xid := Xid;
      Result.First_Text := To_Unbounded_String (GID);
      return Result;
   end Make_Prepared_Message;

   function Make_Begin_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message is
     (Make_Prepared_Message
        (Begin_Prepare_Message,
         Prepare_LSN,
         End_LSN,
         Prepare_At,
         Xid,
         GID));

   function Make_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message is
     (Make_Prepared_Message
        (Prepare_Message,
         Prepare_LSN,
         End_LSN,
         Prepare_At,
         Xid,
         GID));

   function Make_Commit_Prepared
     (Commit_LSN : LSN;
      End_LSN    : LSN;
      Commit_At  : Replication_Timestamp;
      Xid        : Transaction_Id;
      GID        : String) return Message is
     (Make_Prepared_Message
        (Commit_Prepared_Message,
         Commit_LSN,
         End_LSN,
         Commit_At,
         Xid,
         GID));

   function Make_Rollback_Prepared
     (Prepare_End_LSN  : LSN;
      Rollback_End_LSN : LSN;
      Prepare_At       : Replication_Timestamp;
      Rollback_At      : Replication_Timestamp;
      Xid              : Transaction_Id;
      GID              : String) return Message is
      Result : Message := Make_Prepared_Message
        (Rollback_Prepared_Message,
         Prepare_End_LSN,
         Rollback_End_LSN,
         Prepare_At,
         Xid,
         GID);
   begin
      Result.Second_Time := Rollback_At;
      return Result;
   end Make_Rollback_Prepared;

   function Make_Stream_Prepare
     (Prepare_LSN : LSN;
      End_LSN     : LSN;
      Prepare_At  : Replication_Timestamp;
      Xid         : Transaction_Id;
      GID         : String) return Message is
     (Make_Prepared_Message
        (Stream_Prepare_Message,
         Prepare_LSN,
         End_LSN,
         Prepare_At,
         Xid,
         GID));

   procedure Append_U64
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt64) is
      Data : Byte_Array (1 .. 8);
   begin
      Wire.Encode_U64 (Data, Position => 0, Value => Value);
      Protocol.Append_Bytes (Target, Data);
   end Append_U64;

   procedure Append_LSN
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : LSN) is
   begin
      Append_U64 (Target, UInt64 (Value));
   end Append_LSN;

   procedure Append_Time
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication_Timestamp) is
   begin
      Append_U64 (Target, Wire.To_UInt64_Bits (Value));
   end Append_Time;

   procedure Append_Tag
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Tag : Character) is
   begin
      Protocol.Append_Byte (Target, Byte (Character'Pos (Tag)));
   end Append_Tag;

   procedure Append_Tuple
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Item : Tuple_Data) is
   begin
      Require
        (Item.Columns.Length <=
           Ada.Containers.Count_Type (UInt16'Last),
         "TupleData has too many columns");
      Protocol.Append_U16 (Target, UInt16 (Item.Columns.Length));
      for Column of Item.Columns loop
         case Column.Value_Kind is
            when Null_Value =>
               Append_Tag (Target, 'n');
            when Unchanged_Toast_Value =>
               Append_Tag (Target, 'u');
            when Text_Value | Binary_Value =>
               Append_Tag
                 (Target,
                  (if Column.Value_Kind = Text_Value then 't' else 'b'));
               Require
                 (Flyology.Bytes.Length (Column.Data) <=
                    Protocol.Maximum_Message_Size,
                  "TupleData value exceeds the configured limit");
               Protocol.Append_U32
                 (Target, UInt32 (Flyology.Bytes.Length (Column.Data)));
               Protocol.Append_Bytes
                 (Target, Flyology.Bytes.To_Array (Column.Data));
         end case;
      end loop;
   end Append_Tuple;

   function Identity_Tag (Item : Replica_Identity) return Character is
     (case Item is
         when Default_Identity => 'd',
         when Nothing_Identity => 'n',
         when Full_Identity    => 'f',
         when Index_Identity   => 'i');

   function Encode
     (Item      : Message;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled) return Byte_Array is
      Result : Flyology.Bytes.Unbounded_Bytes;

      procedure Append_Stream_Xid is
      begin
         if Item.Streamed then
            Protocol.Append_U32 (Result, Item.Xid);
         end if;
      end Append_Stream_Xid;

      procedure Append_Prepared is
      begin
         Protocol.Append_Byte (Result, 0);
         Append_LSN (Result, Item.First_Position);
         Append_LSN (Result, Item.Second_Position);
         Append_Time (Result, Item.First_Time);
         Protocol.Append_U32 (Result, Item.Xid);
         Protocol.Append_C_String (Result, To_String (Item.First_Text));
      end Append_Prepared;
   begin
      Require
        (Configuration_Is_Valid (Version, Streaming),
         "logical replication version does not support the streaming mode");
      Require
        (not Item.Streamed
         or else (Version >= 2 and then Streaming /= Disabled),
         "streamed fields require protocol version 2 and streaming");
      Require
        (Item.Message_Type not in Stream_Start_Message |
           Stream_Stop_Message | Stream_Commit_Message |
           Stream_Abort_Message | Stream_Prepare_Message
         or else (Version >= 2 and then Streaming /= Disabled),
         "stream control message requires protocol version 2 and streaming");
      Require
        (Item.Message_Type not in Begin_Prepare_Message | Prepare_Message |
           Commit_Prepared_Message | Rollback_Prepared_Message |
           Stream_Prepare_Message
         or else Version >= 3,
         "prepared message requires protocol version 3");

      case Item.Message_Type is
         when Begin_Message =>
            Append_Tag (Result, 'B');
            Append_LSN (Result, Item.First_Position);
            Append_Time (Result, Item.First_Time);
            Protocol.Append_U32 (Result, Item.Xid);

         when Commit_Message =>
            Append_Tag (Result, 'C');
            Protocol.Append_Byte (Result, 0);
            Append_LSN (Result, Item.First_Position);
            Append_LSN (Result, Item.Second_Position);
            Append_Time (Result, Item.First_Time);

         when Origin_Message =>
            Append_Tag (Result, 'O');
            Append_LSN (Result, Item.First_Position);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));

         when Logical_Decoding_Message =>
            Append_Tag (Result, 'M');
            Append_Stream_Xid;
            Protocol.Append_Byte (Result, (if Item.Flag then 1 else 0));
            Append_LSN (Result, Item.First_Position);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));
            Require
              (Flyology.Bytes.Length (Item.Bytes) <=
                 Protocol.Maximum_Message_Size,
               "logical message content exceeds the configured limit");
            Protocol.Append_U32
              (Result, UInt32 (Flyology.Bytes.Length (Item.Bytes)));
            Protocol.Append_Bytes
              (Result, Flyology.Bytes.To_Array (Item.Bytes));

         when Relation_Message =>
            Append_Tag (Result, 'R');
            Append_Stream_Xid;
            Protocol.Append_U32 (Result, Item.Relation);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));
            Protocol.Append_C_String (Result, To_String (Item.Second_Text));
            Append_Tag (Result, Identity_Tag (Item.Replica));
            Require
              (Item.Relation_Columns.Length <=
                 Ada.Containers.Count_Type (UInt16'Last),
               "Relation has too many columns");
            Protocol.Append_U16
              (Result, UInt16 (Item.Relation_Columns.Length));
            for Column of Item.Relation_Columns loop
               Protocol.Append_Byte
                 (Result, (if Column.Key then 1 else 0));
               Protocol.Append_C_String (Result, To_String (Column.Label));
               Protocol.Append_U32 (Result, Column.Oid);
               Protocol.Append_U32
                 (Result, Wire.To_UInt32_Bits (Column.Modifier));
            end loop;

         when Type_Message =>
            Append_Tag (Result, 'Y');
            Append_Stream_Xid;
            Protocol.Append_U32 (Result, Item.Relation);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));
            Protocol.Append_C_String (Result, To_String (Item.Second_Text));

         when Insert_Message =>
            Append_Tag (Result, 'I');
            Append_Stream_Xid;
            Protocol.Append_U32 (Result, Item.Relation);
            Append_Tag (Result, 'N');
            Append_Tuple (Result, Item.After);

         when Update_Message =>
            Append_Tag (Result, 'U');
            Append_Stream_Xid;
            Protocol.Append_U32 (Result, Item.Relation);
            if Item.Before_Kind /= No_Old_Tuple then
               Append_Tag
                 (Result,
                  (if Item.Before_Kind = Key_Old_Tuple then 'K' else 'O'));
               Append_Tuple (Result, Item.Before);
            end if;
            Append_Tag (Result, 'N');
            Append_Tuple (Result, Item.After);

         when Delete_Message =>
            Append_Tag (Result, 'D');
            Append_Stream_Xid;
            Protocol.Append_U32 (Result, Item.Relation);
            Require
              (Item.Before_Kind /= No_Old_Tuple,
               "Delete requires a key or full old tuple");
            Append_Tag
              (Result,
               (if Item.Before_Kind = Key_Old_Tuple then 'K' else 'O'));
            Append_Tuple (Result, Item.Before);

         when Truncate_Message =>
            Append_Tag (Result, 'T');
            Append_Stream_Xid;
            Protocol.Append_U32
              (Result, UInt32 (Item.Relation_Oids.Length));
            Protocol.Append_Byte
              (Result,
               (if Item.Truncate_Cascade then 1 else 0)
               + (if Item.Truncate_Restart then 2 else 0));
            for Relation of Item.Relation_Oids loop
               Protocol.Append_U32 (Result, Relation);
            end loop;

         when Stream_Start_Message =>
            Append_Tag (Result, 'S');
            Protocol.Append_U32 (Result, Item.Xid);
            Protocol.Append_Byte (Result, (if Item.Flag then 1 else 0));

         when Stream_Stop_Message =>
            Append_Tag (Result, 'E');

         when Stream_Commit_Message =>
            Append_Tag (Result, 'c');
            Protocol.Append_U32 (Result, Item.Xid);
            Protocol.Append_Byte (Result, 0);
            Append_LSN (Result, Item.First_Position);
            Append_LSN (Result, Item.Second_Position);
            Append_Time (Result, Item.First_Time);

         when Stream_Abort_Message =>
            Append_Tag (Result, 'A');
            Protocol.Append_U32 (Result, Item.Xid);
            Protocol.Append_U32 (Result, Item.Subxid);
            if Streaming = Parallel then
               Append_LSN (Result, Item.First_Position);
               Append_Time (Result, Item.First_Time);
            end if;

         when Begin_Prepare_Message =>
            Append_Tag (Result, 'b');
            Append_LSN (Result, Item.First_Position);
            Append_LSN (Result, Item.Second_Position);
            Append_Time (Result, Item.First_Time);
            Protocol.Append_U32 (Result, Item.Xid);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));

         when Prepare_Message =>
            Append_Tag (Result, 'P');
            Append_Prepared;

         when Commit_Prepared_Message =>
            Append_Tag (Result, 'K');
            Append_Prepared;

         when Rollback_Prepared_Message =>
            Append_Tag (Result, 'r');
            Protocol.Append_Byte (Result, 0);
            Append_LSN (Result, Item.First_Position);
            Append_LSN (Result, Item.Second_Position);
            Append_Time (Result, Item.First_Time);
            Append_Time (Result, Item.Second_Time);
            Protocol.Append_U32 (Result, Item.Xid);
            Protocol.Append_C_String (Result, To_String (Item.First_Text));

         when Stream_Prepare_Message =>
            Append_Tag (Result, 'p');
            Append_Prepared;
      end case;

      Require
        (Flyology.Bytes.Length (Result) <=
           Protocol.Maximum_Message_Size - 29,
         "logical replication message exceeds the configured limit");
      return Flyology.Bytes.To_Array (Result);
   end Encode;

   function Decode
     (Data      : Byte_Array;
      Version   : Protocol_Version;
      Streamed  : Boolean := False;
      Streaming : Streaming_Mode := Disabled) return Message is
      Cursor : Wire.Wire_Length := 0;
      Tag    : Character;
      Result : Message := (others => <>);
   begin
      --  Streamed is a caller-asserted precondition describing the on-wire
      --  stream context; it cannot be derived from Data because the streamed
      --  transaction-id prefix is not self-describing. Callers that do not
      --  track Stream Start/Stop themselves must decode through the stateful
      --  Decoder, which supplies Streamed from its In_Stream state. The checks
      --  below only reject a Streamed value that is impossible for the
      --  negotiated configuration, not one that merely disagrees with Data.
      Require
        (Configuration_Is_Valid (Version, Streaming),
         "logical replication version does not support the streaming mode");
      Require
        (not Streamed or else Version >= 2,
         "protocol version 1 has no streamed transaction fields");
      Require
        (not Streamed or else Streaming /= Disabled,
         "streamed transaction fields require transaction streaming");
      Require (Data'Length > 0, "empty logical replication message");
      Tag := Character'Val (Read_Byte (Data, Cursor, "logical message tag"));
      Result.Wire_Version := Version;
      Result.Parallel_Stream := Streaming = Parallel;

      case Tag is
         when 'B' =>
            Result.Message_Type := Begin_Message;
            Result.First_Position := Read_LSN
              (Data, Cursor, "Begin final LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "Begin commit timestamp");
            Result.Xid := Read_U32 (Data, Cursor, "Begin transaction ID");

         when 'C' =>
            Result.Message_Type := Commit_Message;
            Require
              (Read_Byte (Data, Cursor, "Commit flags") = 0,
               "Commit flags must be zero");
            Result.First_Position := Read_LSN
              (Data, Cursor, "Commit LSN");
            Result.Second_Position := Read_LSN
              (Data, Cursor, "Commit end LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "Commit timestamp");

         when 'O' =>
            Result.Message_Type := Origin_Message;
            Result.First_Position := Read_LSN
              (Data, Cursor, "Origin commit LSN");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "Origin name"));

         when 'M' =>
            Result.Message_Type := Logical_Decoding_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            declare
               Flags : constant Byte :=
                 Read_Byte (Data, Cursor, "logical message flags");
               Length : UInt32;
            begin
               Require
                 (Flags in 0 | 1, "invalid logical message flags");
               Result.Flag := Flags = 1;
               Result.First_Position := Read_LSN
                 (Data, Cursor, "logical message LSN");
               Result.First_Text := To_Unbounded_String
                 (Read_String (Data, Cursor, "logical message prefix"));
               Length := Read_U32
                 (Data, Cursor, "logical message content length");
               Require
                 (UInt64 (Length) <= UInt64 (Data'Length - Cursor),
                  "logical message content length exceeds its payload");
               Result.Bytes := Flyology.Bytes.To_Unbounded_Bytes
                 (Read_Bytes
                    (Data,
                     Cursor,
                     Wire.Wire_Length (Length),
                     "logical message content"));
            end;

         when 'R' =>
            Result.Message_Type := Relation_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            Result.Relation := Read_U32 (Data, Cursor, "Relation OID");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "Relation namespace"));
            Result.Second_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "Relation name"));
            declare
               Identity : constant Character := Character'Val
                 (Read_Byte (Data, Cursor, "Relation replica identity"));
               Count : UInt16;
            begin
               Result.Replica :=
                 (case Identity is
                     when 'd' => Default_Identity,
                     when 'n' => Nothing_Identity,
                     when 'f' => Full_Identity,
                     when 'i' => Index_Identity,
                     when others => raise Protocol.Protocol_Error with
                       "invalid Relation replica identity");
               Count := Read_U16 (Data, Cursor, "Relation column count");
               Require
                 (Wire.Count_Fits
                    (Data'Length - Cursor,
                     Count,
                     Minimum_Item_Length => 10),
                  "Relation column count exceeds its payload");
               Result.Relation_Columns.Reserve_Capacity
                 (Ada.Containers.Count_Type (Count));
               for Index in 1 .. Natural (Count) loop
                  pragma Unreferenced (Index);
                  declare
                     Flags : constant Byte :=
                       Read_Byte (Data, Cursor, "Relation column flags");
                     Column : Relation_Column;
                  begin
                     Require
                       (Flags in 0 | 1, "invalid Relation column flags");
                     Column.Key := Flags = 1;
                     Column.Label := To_Unbounded_String
                       (Read_String (Data, Cursor, "Relation column name"));
                     Column.Oid := Read_U32
                       (Data, Cursor, "Relation column type OID");
                     Column.Modifier := Wire.To_Int32_Bits
                       (Read_U32
                          (Data, Cursor, "Relation column type modifier"));
                     Result.Relation_Columns.Append (Column);
                  end;
               end loop;
            end;

         when 'Y' =>
            Result.Message_Type := Type_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            Result.Relation := Read_U32 (Data, Cursor, "Type OID");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "Type namespace"));
            Result.Second_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "Type name"));

         when 'I' =>
            Result.Message_Type := Insert_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            Result.Relation := Read_U32 (Data, Cursor, "Insert relation OID");
            Require
              (Read_Byte (Data, Cursor, "Insert tuple tag") =
                 Byte (Character'Pos ('N')),
               "Insert must contain a new tuple");
            Result.After := Read_Tuple (Data, Cursor);

         when 'U' =>
            Result.Message_Type := Update_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            Result.Relation := Read_U32 (Data, Cursor, "Update relation OID");
            declare
               Tuple_Tag : Character := Character'Val
                 (Read_Byte (Data, Cursor, "Update tuple tag"));
            begin
               if Tuple_Tag in 'K' | 'O' then
                  Result.Before_Kind :=
                    (if Tuple_Tag = 'K'
                     then Key_Old_Tuple
                     else Full_Old_Tuple);
                  Result.Before := Read_Tuple (Data, Cursor);
                  Tuple_Tag := Character'Val
                    (Read_Byte (Data, Cursor, "Update new tuple tag"));
               end if;
               Require
                 (Tuple_Tag = 'N', "Update must contain a new tuple");
               Result.After := Read_Tuple (Data, Cursor);
            end;

         when 'D' =>
            Result.Message_Type := Delete_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            Result.Relation := Read_U32 (Data, Cursor, "Delete relation OID");
            declare
               Tuple_Tag : constant Character := Character'Val
                 (Read_Byte (Data, Cursor, "Delete old tuple tag"));
            begin
               Require
                 (Tuple_Tag in 'K' | 'O',
                  "Delete must contain a key or old tuple");
               Result.Before_Kind :=
                 (if Tuple_Tag = 'K'
                  then Key_Old_Tuple
                  else Full_Old_Tuple);
               Result.Before := Read_Tuple (Data, Cursor);
            end;

         when 'T' =>
            Result.Message_Type := Truncate_Message;
            Read_Stream_Xid (Result, Data, Cursor, Streamed);
            declare
               Count : constant UInt32 :=
                 Read_U32 (Data, Cursor, "Truncate relation count");
               Flags : constant Byte :=
                 Read_Byte (Data, Cursor, "Truncate flags");
            begin
               Require
                 ((Flags and 16#FC#) = 0, "invalid Truncate flags");
               Require
                 (UInt64 (Count) <= UInt64 ((Data'Length - Cursor) / 4),
                  "Truncate relation count exceeds its payload");
               Result.Truncate_Cascade := (Flags and 1) /= 0;
               Result.Truncate_Restart := (Flags and 2) /= 0;
               Result.Relation_Oids.Reserve_Capacity
                 (Ada.Containers.Count_Type (Count));
               for Index in 1 .. Count loop
                  pragma Unreferenced (Index);
                  Result.Relation_Oids.Append
                    (Read_U32 (Data, Cursor, "Truncate relation OID"));
               end loop;
            end;

         when 'S' =>
            Require (Version >= 2, "StreamStart requires protocol version 2");
            Require
              (Streaming /= Disabled,
               "StreamStart requires transaction streaming");
            Result.Message_Type := Stream_Start_Message;
            Result.Xid := Read_U32
              (Data, Cursor, "StreamStart transaction ID");
            declare
               First : constant Byte :=
                 Read_Byte (Data, Cursor, "StreamStart first flag");
            begin
               Require (First in 0 | 1, "invalid StreamStart first flag");
               Result.Flag := First = 1;
            end;

         when 'E' =>
            Require (Version >= 2, "StreamStop requires protocol version 2");
            Require
              (Streaming /= Disabled,
               "StreamStop requires transaction streaming");
            Result.Message_Type := Stream_Stop_Message;

         when 'c' =>
            Require
              (Version >= 2, "StreamCommit requires protocol version 2");
            Require
              (Streaming /= Disabled,
               "StreamCommit requires transaction streaming");
            Result.Message_Type := Stream_Commit_Message;
            Result.Xid := Read_U32
              (Data, Cursor, "StreamCommit transaction ID");
            Require
              (Read_Byte (Data, Cursor, "StreamCommit flags") = 0,
               "StreamCommit flags must be zero");
            Result.First_Position := Read_LSN
              (Data, Cursor, "StreamCommit LSN");
            Result.Second_Position := Read_LSN
              (Data, Cursor, "StreamCommit end LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "StreamCommit timestamp");

         when 'A' =>
            Require
              (Version >= 2, "StreamAbort requires protocol version 2");
            Require
              (Streaming /= Disabled,
               "StreamAbort requires transaction streaming");
            Result.Message_Type := Stream_Abort_Message;
            Result.Xid := Read_U32
              (Data, Cursor, "StreamAbort transaction ID");
            Result.Subxid := Read_U32
              (Data, Cursor, "StreamAbort subtransaction ID");
            if Streaming = Parallel then
               Result.First_Position := Read_LSN
                 (Data, Cursor, "StreamAbort LSN");
               Result.First_Time := Read_Time
                 (Data, Cursor, "StreamAbort timestamp");
            end if;

         when 'b' =>
            Require
              (Version >= 3, "BeginPrepare requires protocol version 3");
            Result.Message_Type := Begin_Prepare_Message;
            Result.First_Position := Read_LSN
              (Data, Cursor, "BeginPrepare prepare LSN");
            Result.Second_Position := Read_LSN
              (Data, Cursor, "BeginPrepare end LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "BeginPrepare timestamp");
            Result.Xid := Read_U32
              (Data, Cursor, "BeginPrepare transaction ID");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "BeginPrepare GID"));

         when 'P' | 'K' | 'p' =>
            Require
              (Version >= 3, "prepared message requires protocol version 3");
            if Tag = 'p' then
               Require
                 (Streaming /= Disabled,
                  "StreamPrepare requires transaction streaming");
            end if;
            Result.Message_Type :=
              (case Tag is
                  when 'P' => Prepare_Message,
                  when 'K' => Commit_Prepared_Message,
                  when 'p' => Stream_Prepare_Message,
                  when others => Prepare_Message);
            Require
              (Read_Byte (Data, Cursor, "prepared message flags") = 0,
               "prepared message flags must be zero");
            Result.First_Position := Read_LSN
              (Data, Cursor, "prepared message LSN");
            Result.Second_Position := Read_LSN
              (Data, Cursor, "prepared message end LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "prepared message timestamp");
            Result.Xid := Read_U32
              (Data, Cursor, "prepared message transaction ID");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "prepared message GID"));

         when 'r' =>
            Require
              (Version >= 3,
               "RollbackPrepared requires protocol version 3");
            Result.Message_Type := Rollback_Prepared_Message;
            Require
              (Read_Byte (Data, Cursor, "RollbackPrepared flags") = 0,
               "RollbackPrepared flags must be zero");
            Result.First_Position := Read_LSN
              (Data, Cursor, "RollbackPrepared prepare end LSN");
            Result.Second_Position := Read_LSN
              (Data, Cursor, "RollbackPrepared rollback end LSN");
            Result.First_Time := Read_Time
              (Data, Cursor, "RollbackPrepared prepare timestamp");
            Result.Second_Time := Read_Time
              (Data, Cursor, "RollbackPrepared rollback timestamp");
            Result.Xid := Read_U32
              (Data, Cursor, "RollbackPrepared transaction ID");
            Result.First_Text := To_Unbounded_String
              (Read_String (Data, Cursor, "RollbackPrepared GID"));

         when others =>
            raise Protocol.Protocol_Error with
              "unknown logical replication message tag";
      end case;

      Require_End (Data, Cursor, "logical replication message");
      return Result;
   end Decode;

   procedure Configure
     (Item      : out Decoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled) is
   begin
      Require
        (Configuration_Is_Valid (Version, Streaming),
         "logical replication version does not support the streaming mode");
      Item :=
        (Wire_Version => Version,
         Mode         => Streaming,
         In_Stream    => False);
   end Configure;

   procedure Reset (Item : in out Decoder) is
   begin
      Item.In_Stream := False;
   end Reset;

   function Decode
     (Item : in out Decoder; Data : Byte_Array) return Message is
      Tag : Character;
   begin
      Require (Data'Length > 0, "empty logical replication message");
      Tag := Character'Val (Data (Data'First));
      Require
        (Tag /= 'S' or else not Item.In_Stream,
         "nested logical transaction stream segment");
      Require
        (Tag /= 'E' or else Item.In_Stream,
         "StreamStop outside a logical stream segment");
      Require
        (Tag not in 'c' | 'A' | 'p' or else not Item.In_Stream,
         "logical transaction completion inside a stream segment");
      declare
         Result : constant Message :=
           Decode
             (Data,
              Version   => Item.Wire_Version,
              Streamed  => Item.In_Stream,
              Streaming => Item.Mode);
      begin
         if Tag = 'S' then
            Item.In_Stream := True;
         elsif Tag = 'E' then
            Item.In_Stream := False;
         end if;
         return Result;
      end;
   end Decode;

   function Inside_Stream (Item : Decoder) return Boolean is
     (Item.In_Stream);

   function Kind (Item : Message) return Message_Kind is
     (Item.Message_Type);

   function Level (Item : Message) return Message_Level is
     (case Item.Message_Type is
         when Begin_Message |
              Commit_Message |
              Stream_Start_Message |
              Stream_Stop_Message |
              Stream_Commit_Message |
              Stream_Abort_Message |
              Begin_Prepare_Message |
              Prepare_Message |
              Commit_Prepared_Message |
              Rollback_Prepared_Message |
              Stream_Prepare_Message => Transaction_Control,
         when Origin_Message |
              Logical_Decoding_Message |
              Relation_Message |
              Type_Message => Transaction_Metadata,
         when Insert_Message |
              Update_Message |
              Delete_Message |
              Truncate_Message => Row_Change);

   function Version (Item : Message) return Protocol_Version is
     (Item.Wire_Version);

   function Is_Streamed (Item : Message) return Boolean is (Item.Streamed);

   function Transaction (Item : Message) return Transaction_Id is (Item.Xid);

   function Subtransaction (Item : Message) return Transaction_Id is
   begin
      Require
        (Item.Message_Type = Stream_Abort_Message,
         "logical message has no subtransaction ID");
      return Item.Subxid;
   end Subtransaction;

   function Final_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type = Begin_Message,
         "logical message has no final transaction LSN");
      return Item.First_Position;
   end Final_LSN;

   function Commit_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type in Commit_Message | Stream_Commit_Message |
           Commit_Prepared_Message,
         "logical message has no commit LSN");
      return Item.First_Position;
   end Commit_LSN;

   function Prepare_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type in Begin_Prepare_Message | Prepare_Message |
           Stream_Prepare_Message,
         "logical message has no prepare LSN");
      return Item.First_Position;
   end Prepare_LSN;

   function Prepare_End_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type = Rollback_Prepared_Message,
         "logical message has no prepared transaction end LSN");
      return Item.First_Position;
   end Prepare_End_LSN;

   function End_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type in Commit_Message | Stream_Commit_Message |
           Begin_Prepare_Message | Prepare_Message |
           Commit_Prepared_Message | Rollback_Prepared_Message |
           Stream_Prepare_Message,
         "logical message has no end LSN");
      return Item.Second_Position;
   end End_LSN;

   function Origin_Commit_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type = Origin_Message,
         "logical message is not an Origin message");
      return Item.First_Position;
   end Origin_Commit_LSN;

   function Abort_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type = Stream_Abort_Message
         and then Item.Parallel_Stream,
         "logical message has no parallel-stream abort LSN");
      return Item.First_Position;
   end Abort_LSN;

   function Event_Timestamp
     (Item : Message) return Replication_Timestamp is
   begin
      Require
        (Item.Message_Type in Begin_Message | Commit_Message |
           Stream_Commit_Message | Stream_Abort_Message |
           Begin_Prepare_Message | Prepare_Message |
           Commit_Prepared_Message | Rollback_Prepared_Message |
           Stream_Prepare_Message,
         "logical message has no event timestamp");
      Require
        (Item.Message_Type /= Stream_Abort_Message
         or else Item.Parallel_Stream,
         "non-parallel StreamAbort has no event timestamp");
      return Item.First_Time;
   end Event_Timestamp;

   function Rollback_Timestamp
     (Item : Message) return Replication_Timestamp is
   begin
      Require
        (Item.Message_Type = Rollback_Prepared_Message,
         "logical message has no rollback timestamp");
      return Item.Second_Time;
   end Rollback_Timestamp;

   function GID (Item : Message) return String is
   begin
      Require
        (Item.Message_Type in Begin_Prepare_Message | Prepare_Message |
           Commit_Prepared_Message | Rollback_Prepared_Message |
           Stream_Prepare_Message,
         "logical message has no prepared transaction GID");
      return To_String (Item.First_Text);
   end GID;

   function Origin_Name (Item : Message) return String is
   begin
      Require
        (Item.Message_Type = Origin_Message,
         "logical message is not an Origin message");
      return To_String (Item.First_Text);
   end Origin_Name;

   function Is_Transactional (Item : Message) return Boolean is
   begin
      Require
        (Item.Message_Type = Logical_Decoding_Message,
         "logical message is not a logical decoding Message");
      return Item.Flag;
   end Is_Transactional;

   function Message_LSN (Item : Message) return LSN is
   begin
      Require
        (Item.Message_Type = Logical_Decoding_Message,
         "logical message is not a logical decoding Message");
      return Item.First_Position;
   end Message_LSN;

   function Prefix (Item : Message) return String is
   begin
      Require
        (Item.Message_Type = Logical_Decoding_Message,
         "logical message is not a logical decoding Message");
      return To_String (Item.First_Text);
   end Prefix;

   function Content (Item : Message) return Byte_Array is
   begin
      Require
        (Item.Message_Type = Logical_Decoding_Message,
         "logical message is not a logical decoding Message");
      return Flyology.Bytes.To_Array (Item.Bytes);
   end Content;

   function Relation_Id (Item : Message) return UInt32 is
   begin
      Require
        (Item.Message_Type in Relation_Message | Type_Message |
           Insert_Message | Update_Message | Delete_Message,
         "logical message has no relation or type OID");
      return Item.Relation;
   end Relation_Id;

   function Type_Id (Item : Message) return UInt32 is
   begin
      Require
        (Item.Message_Type = Type_Message,
         "logical message is not a Type message");
      return Item.Relation;
   end Type_Id;

   function Namespace_Name (Item : Message) return String is
   begin
      Require
        (Item.Message_Type in Relation_Message | Type_Message,
         "logical message has no namespace");
      return To_String (Item.First_Text);
   end Namespace_Name;

   function Object_Name (Item : Message) return String is
   begin
      Require
        (Item.Message_Type in Relation_Message | Type_Message,
         "logical message has no object name");
      return To_String (Item.Second_Text);
   end Object_Name;

   function Identity (Item : Message) return Replica_Identity is
   begin
      Require
        (Item.Message_Type = Relation_Message,
         "logical message is not a Relation message");
      return Item.Replica;
   end Identity;

   function Relation_Column_Count (Item : Message) return Natural is
   begin
      Require
        (Item.Message_Type = Relation_Message,
         "logical message is not a Relation message");
      return Natural (Item.Relation_Columns.Length);
   end Relation_Column_Count;

   function Relation_Column_At
     (Item : Message; Index : Positive) return Relation_Column is
   begin
      if Index > Relation_Column_Count (Item) then
         raise Constraint_Error with "Relation column index is invalid";
      end if;
      return Item.Relation_Columns.Element (Index);
   end Relation_Column_At;

   function New_Tuple (Item : Message) return Tuple_Data is
   begin
      Require
        (Item.Message_Type in Insert_Message | Update_Message,
         "logical message has no new tuple");
      return Item.After;
   end New_Tuple;

   function Old_Kind (Item : Message) return Old_Tuple_Kind is
   begin
      Require
        (Item.Message_Type in Update_Message | Delete_Message,
         "logical message cannot contain an old tuple");
      return Item.Before_Kind;
   end Old_Kind;

   function Old_Tuple (Item : Message) return Tuple_Data is
   begin
      Require
        (Item.Message_Type in Update_Message | Delete_Message
         and then Item.Before_Kind /= No_Old_Tuple,
         "logical message has no old tuple");
      return Item.Before;
   end Old_Tuple;

   function Truncated_Relation_Count (Item : Message) return Natural is
   begin
      Require
        (Item.Message_Type = Truncate_Message,
         "logical message is not a Truncate message");
      return Natural (Item.Relation_Oids.Length);
   end Truncated_Relation_Count;

   function Truncated_Relation
     (Item : Message; Index : Positive) return UInt32 is
   begin
      if Index > Truncated_Relation_Count (Item) then
         raise Constraint_Error with "Truncate relation index is invalid";
      end if;
      return Item.Relation_Oids.Element (Index);
   end Truncated_Relation;

   function Cascade (Item : Message) return Boolean is
   begin
      Require
        (Item.Message_Type = Truncate_Message,
         "logical message is not a Truncate message");
      return Item.Truncate_Cascade;
   end Cascade;

   function Restart_Identity (Item : Message) return Boolean is
   begin
      Require
        (Item.Message_Type = Truncate_Message,
         "logical message is not a Truncate message");
      return Item.Truncate_Restart;
   end Restart_Identity;

   function Is_First_Stream_Segment (Item : Message) return Boolean is
   begin
      Require
        (Item.Message_Type = Stream_Start_Message,
         "logical message is not a StreamStart message");
      return Item.Flag;
   end Is_First_Stream_Segment;

   function Column_Count (Item : Tuple_Data) return Natural is
     (Natural (Item.Columns.Length));

   function Column
     (Item : Tuple_Data; Index : Positive) return Tuple_Value is
   begin
      if Index > Column_Count (Item) then
         raise Constraint_Error with "TupleData column index is invalid";
      end if;
      return Item.Columns.Element (Index);
   end Column;

   function Kind (Item : Tuple_Value) return Tuple_Value_Kind is
     (Item.Value_Kind);

   function Value (Item : Tuple_Value) return Byte_Array is
   begin
      Require
        (Item.Value_Kind in Text_Value | Binary_Value,
         "TupleData column has no value bytes");
      return Flyology.Bytes.To_Array (Item.Data);
   end Value;

   function Text (Item : Tuple_Value) return String is
   begin
      Require
        (Item.Value_Kind = Text_Value,
         "TupleData column is not text formatted");
      return Flyology.Bytes.To_Byte_String (Item.Data);
   end Text;

   function Is_Key (Item : Relation_Column) return Boolean is (Item.Key);

   function Name (Item : Relation_Column) return String is
     (To_String (Item.Label));

   function Type_Oid (Item : Relation_Column) return UInt32 is (Item.Oid);

   function Type_Modifier (Item : Relation_Column) return Int32 is
     (Item.Modifier);

end Flyology.Postgres.Replication.Logical;
