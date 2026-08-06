with Ada.Containers;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Protocol is

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;
   use type Wire.Initial_Parse_Status;

   SSL_Code      : constant UInt32 := 80_877_103;

   function To_Bytes (Value : String) return Byte_Array is
      Result : Byte_Array (1 .. Byte_Offset (Value'Length));
      Cursor : Byte_Offset := Result'First;
   begin
      for Item of Value loop
         Result (Cursor) := Byte (Character'Pos (Item));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end To_Bytes;

   procedure Require
     (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol_Error with Information;
      end if;
   end Require;

   procedure Require_Room
     (Target      : Flyology.Bytes.Unbounded_Bytes;
      Additional  : Natural;
      Context     : String) is
      Current : constant Natural := Flyology.Bytes.Length (Target);
      Limit   : constant Natural := Maximum_Message_Size - 4;
   begin
      Require
        (Current <= Limit and then Additional <= Limit - Current,
         Context & " exceeds the configured limit");
   end Require_Room;

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

   function View_To_Bytes
     (Source : Byte_Array; View : Wire.Byte_View) return Byte_Array is
      Result : Byte_Array (1 .. Byte_Offset (View.Length));
   begin
      for Index in Result'Range loop
         Result (Index) := Wire.Element_At
           (Source,
            View.First + Wire.Wire_Length (Index - Result'First));
      end loop;
      return Result;
   end View_To_Bytes;

   procedure Append_Byte
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte) is
      Data : constant Byte_Array (1 .. 1) := (1 => Value);
   begin
      Flyology.Bytes.Append (Target, Data);
   end Append_Byte;

   procedure Append_Bytes
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte_Array) is
   begin
      Flyology.Bytes.Append (Target, Value);
   end Append_Bytes;

   procedure Append_U16
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt16) is
      Data : Byte_Array (1 .. 2);
   begin
      Wire.Encode_U16 (Data, Position => 0, Value => Value);
      Append_Bytes (Target, Data);
   end Append_U16;

   procedure Append_U32
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt32) is
      Data : Byte_Array (1 .. 4);
   begin
      Wire.Encode_U32 (Data, Position => 0, Value => Value);
      Append_Bytes (Target, Data);
   end Append_U32;

   procedure Append_C_String
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : String) is
   begin
      Require
        ((for all Item of Value => Item /= Character'Val (0)),
         "a Postgres string contains an embedded NUL");
      Append_Bytes (Target, To_Bytes (Value));
      Append_Byte (Target, 0);
   end Append_C_String;

   function Read_U16
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt16 is
      Position : Wire.Wire_Length;
      Result   : UInt16;
      Success  : Boolean;
   begin
      Require
        (Source'Length <= Maximum_Message_Size
         and then Cursor >= Source'First
         and then Cursor <= Source'Last,
         "truncated 16-bit protocol field");
      Position := Wire.Wire_Length (Cursor - Source'First);
      Wire.Try_Read_U16 (Source, Position, Result, Success);
      Require (Success, "truncated 16-bit protocol field");
      Require
        (Cursor <= Byte_Offset'Last - 2,
         "16-bit protocol cursor cannot advance");
      Cursor := Cursor + 2;
      return Result;
   end Read_U16;

   function Read_U32
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt32 is
      Position : Wire.Wire_Length;
      Result   : UInt32;
      Success  : Boolean;
   begin
      Require
        (Source'Length <= Maximum_Message_Size
         and then Cursor >= Source'First
         and then Cursor <= Source'Last,
         "truncated 32-bit protocol field");
      Position := Wire.Wire_Length (Cursor - Source'First);
      Wire.Try_Read_U32 (Source, Position, Result, Success);
      Require (Success, "truncated 32-bit protocol field");
      Require
        (Cursor <= Byte_Offset'Last - 4,
         "32-bit protocol cursor cannot advance");
      Cursor := Cursor + 4;
      return Result;
   end Read_U32;

   function Read_C_String
     (Source : Byte_Array; Cursor : in out Byte_Offset) return String is
      Position : Wire.Wire_Length;
      View     : Wire.Byte_View;
      Success  : Boolean;
   begin
      Require
        (Source'Length <= Maximum_Message_Size
         and then Cursor >= Source'First
         and then Cursor <= Source'Last,
         "Postgres string exceeds the configured limit");
      Position := Wire.Wire_Length (Cursor - Source'First);
      Wire.Try_Read_C_String (Source, Position, View, Success);
      Require (Success, "unterminated Postgres string");
      Require
        (Source'Last < Byte_Offset'Last,
         "Postgres string cursor cannot advance");
      declare
         Result : constant String := View_To_String (Source, View);
      begin
         Cursor := Source'First + Byte_Offset (Position);
         return Result;
      end;
   end Read_C_String;

   function Make_Message
     (Code : Character; Payload : Byte_Array) return Message is
   begin
      Require
        (Payload'Length <= Maximum_Message_Size - 4,
         "Postgres message exceeds the configured limit");
      return
        (Tag  => Code,
         Data => Flyology.Bytes.To_Unbounded_Bytes (Payload));
   end Make_Message;

   function Make_Empty_Message (Code : Character) return Message is
      Empty : constant Byte_Array (1 .. 0) := (others => 0);
   begin
      return Make_Message (Code, Empty);
   end Make_Empty_Message;

   function Code (Item : Message) return Character is (Item.Tag);

   function Kind (Item : Message) return Frontend_Kind is
   begin
      case Item.Tag is
         when 'B' => return Bind;
         when 'C' => return Close;
         when 'd' => return Copy_Data;
         when 'c' => return Copy_Done;
         when 'f' => return Copy_Fail;
         when 'D' => return Describe;
         when 'E' => return Execute;
         when 'H' => return Flush;
         when 'F' => return Function_Call;
         when 'p' => return Password_Or_SASL_Response;
         when 'P' => return Parse;
         when 'Q' => return Query;
         when 'S' => return Sync;
         when 'X' => return Terminate_Command;
         when others => return Unknown;
      end case;
   end Kind;

   function Payload (Item : Message) return Byte_Array is
     (Flyology.Bytes.To_Array (Item.Data));

   function Payload_Length (Item : Message) return Natural is
     (Flyology.Bytes.Length (Item.Data));

   function Encode (Item : Message) return Byte_Array is
      Result : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_Byte (Result, Byte (Character'Pos (Item.Tag)));
      Append_U32 (Result, UInt32 (Payload_Length (Item) + 4));
      Append_Bytes (Result, Payload (Item));
      return Flyology.Bytes.To_Array (Result);
   end Encode;

   function Null_Parameter
     (Format : Field_Format := Text_Format) return Bind_Parameter is
     ((Null_Value   => True,
       Format_Value => Format,
       Bytes        => Flyology.Bytes.Empty));

   function Text_Parameter (Value : String) return Bind_Parameter is
   begin
      Require
        (Value'Length <= Maximum_Message_Size - 8,
         "text parameter exceeds the configured limit");
      return
        (Null_Value   => False,
         Format_Value => Text_Format,
         Bytes        => Flyology.Bytes.From_Byte_String (Value));
   end Text_Parameter;

   function Binary_Parameter (Value : Byte_Array) return Bind_Parameter is
   begin
      Require
        (Value'Length <= Maximum_Message_Size - 8,
         "binary parameter exceeds the configured limit");
      return
        (Null_Value   => False,
         Format_Value => Binary_Format,
         Bytes        => Flyology.Bytes.To_Unbounded_Bytes (Value));
   end Binary_Parameter;

   function Is_Null (Item : Bind_Parameter) return Boolean is
     (Item.Null_Value);

   function Parameter_Format (Item : Bind_Parameter) return Field_Format is
     (Item.Format_Value);

   function Parameter_Bytes (Item : Bind_Parameter) return Byte_Array is
   begin
      Require (not Item.Null_Value, "a NULL parameter has no value bytes");
      return Flyology.Bytes.To_Array (Item.Bytes);
   end Parameter_Bytes;

   function Format_Code (Value : Field_Format) return UInt16 is
     (if Value = Text_Format then 0 else 1);

   function Parameter_Format_Count
     (Parameters : Bind_Parameter_Array) return Natural is
   begin
      if Parameters'Length = 0 then
         return 0;
      end if;
      declare
         First : constant Field_Format :=
           Parameters (Parameters'First).Format_Value;
      begin
         if (for all Item of Parameters =>
               Item.Format_Value = Text_Format)
         then
            return 0;
         elsif (for all Item of Parameters => Item.Format_Value = First) then
            return 1;
         else
            return Parameters'Length;
         end if;
      end;
   end Parameter_Format_Count;

   function Result_Format_Count
     (Formats : Field_Format_Array) return Natural is
   begin
      if Formats'Length = 0
        or else (for all Item of Formats => Item = Text_Format)
      then
         return 0;
      elsif (for all Item of Formats => Item = Formats (Formats'First)) then
         return 1;
      else
         return Formats'Length;
      end if;
   end Result_Format_Count;

   function Make_Parse_Message
     (Statement_Name  : String;
      SQL             : String;
      Parameter_Types : Oid_Array := No_Oids) return Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Parameter_Types'Length <= Natural (UInt16'Last),
         "Parse has too many parameter type OIDs");
      Require_Room
        (Contents, Statement_Name'Length + 1, "Parse message");
      Append_C_String (Contents, Statement_Name);
      Require_Room (Contents, SQL'Length + 1, "Parse message");
      Append_C_String (Contents, SQL);
      Require_Room
        (Contents, 2 + 4 * Parameter_Types'Length, "Parse message");
      Append_U16 (Contents, UInt16 (Parameter_Types'Length));
      for Oid of Parameter_Types loop
         Append_U32 (Contents, Oid);
      end loop;
      return Make_Message ('P', Flyology.Bytes.To_Array (Contents));
   end Make_Parse_Message;

   function Make_Bind_Message
     (Portal_Name    : String;
      Statement_Name : String;
      Parameters     : Bind_Parameter_Array := No_Parameters;
      Result_Formats : Field_Format_Array := No_Formats) return Message is
      Contents              : Flyology.Bytes.Unbounded_Bytes;
      Parameter_Code_Count  : Natural;
      Result_Code_Count     : Natural;
   begin
      Require
        (Parameters'Length <= Natural (UInt16'Last),
         "Bind has too many parameters");
      Require
        (Result_Formats'Length <= Natural (UInt16'Last),
         "Bind has too many result format codes");
      Parameter_Code_Count := Parameter_Format_Count (Parameters);
      Result_Code_Count := Result_Format_Count (Result_Formats);
      Require
        (Wire.Format_Count_Is_Valid
           (UInt16 (Parameter_Code_Count), UInt16 (Parameters'Length)),
         "Bind parameter format-code count is invalid");

      Require_Room (Contents, Portal_Name'Length + 1, "Bind message");
      Append_C_String (Contents, Portal_Name);
      Require_Room (Contents, Statement_Name'Length + 1, "Bind message");
      Append_C_String (Contents, Statement_Name);
      Require_Room
        (Contents, 2 + 2 * Parameter_Code_Count, "Bind message");
      Append_U16 (Contents, UInt16 (Parameter_Code_Count));
      if Parameter_Code_Count = 1 then
         Append_U16
           (Contents,
            Format_Code (Parameters (Parameters'First).Format_Value));
      elsif Parameter_Code_Count > 1 then
         for Item of Parameters loop
            Append_U16 (Contents, Format_Code (Item.Format_Value));
         end loop;
      end if;

      Require_Room (Contents, 2, "Bind message");
      Append_U16 (Contents, UInt16 (Parameters'Length));
      for Item of Parameters loop
         Require_Room (Contents, 4, "Bind message");
         if Item.Null_Value then
            Append_U32 (Contents, UInt32'Last);
         else
            declare
               Bytes : constant Byte_Array :=
                 Flyology.Bytes.To_Array (Item.Bytes);
            begin
               Require_Room (Contents, Bytes'Length, "Bind message");
               Append_U32 (Contents, UInt32 (Bytes'Length));
               Append_Bytes (Contents, Bytes);
            end;
         end if;
      end loop;

      Require_Room
        (Contents, 2 + 2 * Result_Code_Count, "Bind message");
      Append_U16 (Contents, UInt16 (Result_Code_Count));
      if Result_Code_Count = 1 then
         Append_U16
           (Contents, Format_Code (Result_Formats (Result_Formats'First)));
      elsif Result_Code_Count > 1 then
         for Item of Result_Formats loop
            Append_U16 (Contents, Format_Code (Item));
         end loop;
      end if;
      return Make_Message ('B', Flyology.Bytes.To_Array (Contents));
   end Make_Bind_Message;

   function Make_Describe_Message
     (Object_Type : Object_Kind; Name : String) return Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require_Room (Contents, Name'Length + 2, "Describe message");
      Append_Byte
        (Contents,
         Byte (Character'Pos
           (if Object_Type = Statement_Object then 'S' else 'P')));
      Append_C_String (Contents, Name);
      return Make_Message ('D', Flyology.Bytes.To_Array (Contents));
   end Make_Describe_Message;

   function Make_Execute_Message
     (Portal_Name : String; Maximum_Rows : Row_Limit := 0) return Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require_Room (Contents, Portal_Name'Length + 5, "Execute message");
      Append_C_String (Contents, Portal_Name);
      Append_U32 (Contents, UInt32 (Maximum_Rows));
      return Make_Message ('E', Flyology.Bytes.To_Array (Contents));
   end Make_Execute_Message;

   function Make_Close_Message
     (Object_Type : Object_Kind; Name : String) return Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require_Room (Contents, Name'Length + 2, "Close message");
      Append_Byte
        (Contents,
         Byte (Character'Pos
           (if Object_Type = Statement_Object then 'S' else 'P')));
      Append_C_String (Contents, Name);
      return Make_Message ('C', Flyology.Bytes.To_Array (Contents));
   end Make_Close_Message;

   function Make_Flush_Message return Message is
     (Make_Empty_Message ('H'));

   function Make_Sync_Message return Message is
     (Make_Empty_Message ('S'));

   function Make_Copy_Data_Message (Data : Byte_Array) return Message is
     (Make_Message ('d', Data));

   function Make_Copy_Done_Message return Message is
     (Make_Empty_Message ('c'));

   function Make_Copy_Fail_Message (Reason : String) return Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require_Room (Contents, Reason'Length + 1, "CopyFail message");
      Append_C_String (Contents, Reason);
      return Make_Message ('f', Flyology.Bytes.To_Array (Contents));
   end Make_Copy_Fail_Message;

   function Make_Field_Description
     (Name                    : String;
      Table_Oid               : UInt32 := 0;
      Column_Attribute_Number : Int16 := 0;
      Type_Oid                : UInt32 := 25;
      Type_Size               : Int16 := -1;
      Type_Modifier           : Int32 := -1;
      Format                  : Field_Format := Text_Format)
      return Field_Description is
   begin
      Require
        ((for all Item of Name => Item /= Character'Val (0)),
         "a RowDescription field name contains an embedded NUL");
      return
        (Name_Value                    => To_Unbounded_String (Name),
         Table_Oid_Value               => Table_Oid,
         Column_Attribute_Number_Value => Column_Attribute_Number,
         Type_Oid_Value                => Type_Oid,
         Type_Size_Value               => Type_Size,
         Type_Modifier_Value           => Type_Modifier,
         Format_Value                  => Format);
   end Make_Field_Description;

   function Field_Name (Item : Field_Description) return String is
     (To_String (Item.Name_Value));

   function Table_Oid (Item : Field_Description) return UInt32 is
     (Item.Table_Oid_Value);

   function Column_Attribute_Number
     (Item : Field_Description) return Int16 is
     (Item.Column_Attribute_Number_Value);

   function Type_Oid (Item : Field_Description) return UInt32 is
     (Item.Type_Oid_Value);

   function Type_Size (Item : Field_Description) return Int16 is
     (Item.Type_Size_Value);

   function Type_Modifier (Item : Field_Description) return Int32 is
     (Item.Type_Modifier_Value);

   function Format (Item : Field_Description) return Field_Format is
     (Item.Format_Value);

   function Field_Count (Item : Row_Description) return Natural is
     (Natural (Item.Fields.Length));

   function Field_At
     (Item : Row_Description; Index : Positive) return Field_Description is
   begin
      if Index > Field_Count (Item) then
         raise Constraint_Error with
           "RowDescription field index is invalid";
      end if;
      return Item.Fields.Element (Index);
   end Field_At;

   function Text_Column (Value : String) return Column_Value is
     ((Null_Value => False, Bytes => Flyology.Bytes.From_Byte_String (Value)));

   function Binary_Column (Value : Byte_Array) return Column_Value is
     ((Null_Value => False,
       Bytes      => Flyology.Bytes.To_Unbounded_Bytes (Value)));

   function Is_Null (Item : Column_Value) return Boolean is
     (Item.Null_Value);

   function Column_Bytes (Item : Column_Value) return Byte_Array is
   begin
      Require (not Item.Null_Value, "a NULL column has no value bytes");
      return Flyology.Bytes.To_Array (Item.Bytes);
   end Column_Bytes;

   function Column_Text (Item : Column_Value) return String is
   begin
      Require (not Item.Null_Value, "a NULL column has no text value");
      return Flyology.Bytes.To_Byte_String (Item.Bytes);
   end Column_Text;

   function Column_Count (Item : Data_Row) return Natural is
     (Natural (Item.Columns.Length));

   function Column_At
     (Item : Data_Row; Index : Positive) return Column_Value is
   begin
      if Index > Column_Count (Item) then
         raise Constraint_Error with "DataRow column index is invalid";
      end if;
      return Item.Columns.Element (Index);
   end Column_At;

   function Field_Text
     (Item : Diagnostic; Code : Character) return String is
   begin
      for Field of Item.Fields loop
         if Field.Code = Code then
            return To_String (Field.Text);
         end if;
      end loop;
      return "";
   end Field_Text;

   function Severity (Item : Diagnostic) return String is
     (Field_Text (Item, 'S'));

   function Nonlocalized_Severity (Item : Diagnostic) return String is
     (Field_Text (Item, 'V'));

   function Diagnostic_SQL_State (Item : Diagnostic) return String is
     (Field_Text (Item, 'C'));

   function Diagnostic_Message (Item : Diagnostic) return String is
     (Field_Text (Item, 'M'));

   function Parameter_Name (Item : Parameter_Status) return String is
     (To_String (Item.Name));

   function Parameter_Value (Item : Parameter_Status) return String is
     (To_String (Item.Value));

   function Parameter_Count (Item : Parameter_Description) return Natural is
     (Natural (Item.Types.Length));

   function Parameter_Type_At
     (Item : Parameter_Description; Index : Positive) return UInt32 is
   begin
      if Index > Parameter_Count (Item) then
         raise Constraint_Error with
           "ParameterDescription parameter index is invalid";
      end if;
      return Item.Types.Element (Index);
   end Parameter_Type_At;

   function Signed_16 (Value : UInt16) return Int16 is
     (if Value <= UInt16 (Int16'Last)
      then Int16 (Value)
      else Int16 (Integer (Value) - 65_536));

   function Signed_32 (Value : UInt32) return Int32 is
     (if Value <= UInt32 (Int32'Last)
      then Int32 (Value)
      else Int32 (Long_Long_Integer (Value) - 4_294_967_296));

   procedure Read_U16_At
     (Contents : Byte_Array;
      Cursor   : in out Wire.Wire_Length;
      Value    : out UInt16;
      Context  : String) is
      Success : Boolean;
   begin
      Wire.Try_Read_U16 (Contents, Cursor, Value, Success);
      Require (Success, "truncated " & Context);
   end Read_U16_At;

   procedure Read_U32_At
     (Contents : Byte_Array;
      Cursor   : in out Wire.Wire_Length;
      Value    : out UInt32;
      Context  : String) is
      Success : Boolean;
   begin
      Wire.Try_Read_U32 (Contents, Cursor, Value, Success);
      Require (Success, "truncated " & Context);
   end Read_U32_At;

   procedure Read_C_String_At
     (Contents : Byte_Array;
      Cursor   : in out Wire.Wire_Length;
      View     : out Wire.Byte_View;
      Context  : String) is
      Success : Boolean;
   begin
      Wire.Try_Read_C_String (Contents, Cursor, View, Success);
      Require (Success, "unterminated " & Context);
   end Read_C_String_At;

   function Decode_Row_Description (Item : Message) return Row_Description is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      Count    : UInt16;
      Result   : Row_Description;
   begin
      Read_U16_At (Contents, Cursor, Count, "RowDescription field count");
      Require
        (Wire.Count_Fits
           (Contents'Length - Cursor, Count, Minimum_Item_Length => 19),
         "RowDescription field count exceeds its payload");
      Result.Fields.Reserve_Capacity (Ada.Containers.Count_Type (Count));

      for Index in 1 .. Natural (Count) loop
         pragma Unreferenced (Index);
         declare
            Name_View        : Wire.Byte_View;
            Table_Value      : UInt32;
            Attribute_Value  : UInt16;
            Type_Oid_Value   : UInt32;
            Type_Size_Value  : UInt16;
            Modifier_Value   : UInt32;
            Format_Value     : UInt16;
         begin
            Read_C_String_At
              (Contents, Cursor, Name_View, "RowDescription field name");
            Read_U32_At
              (Contents, Cursor, Table_Value, "RowDescription table OID");
            Read_U16_At
              (Contents, Cursor, Attribute_Value,
               "RowDescription column attribute number");
            Read_U32_At
              (Contents, Cursor, Type_Oid_Value, "RowDescription type OID");
            Read_U16_At
              (Contents, Cursor, Type_Size_Value, "RowDescription type size");
            Read_U32_At
              (Contents, Cursor, Modifier_Value,
               "RowDescription type modifier");
            Read_U16_At
              (Contents, Cursor, Format_Value, "RowDescription format code");
            Require
              (Format_Value in 0 | 1,
               "invalid RowDescription format code");
            Result.Fields.Append
              (Make_Field_Description
                 (Name                    =>
                    View_To_String (Contents, Name_View),
                  Table_Oid               => Table_Value,
                  Column_Attribute_Number => Signed_16 (Attribute_Value),
                  Type_Oid                => Type_Oid_Value,
                  Type_Size               => Signed_16 (Type_Size_Value),
                  Type_Modifier           => Signed_32 (Modifier_Value),
                  Format                  =>
                    (if Format_Value = 0
                     then Text_Format
                     else Binary_Format)));
         end;
      end loop;
      Require
        (Cursor = Contents'Length,
         "RowDescription has trailing payload data");
      return Result;
   end Decode_Row_Description;

   function Decode_Data_Row (Item : Message) return Data_Row is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      Count    : UInt16;
      Result   : Data_Row;
   begin
      Read_U16_At (Contents, Cursor, Count, "DataRow column count");
      Require
        (Wire.Count_Fits
           (Contents'Length - Cursor, Count, Minimum_Item_Length => 4),
         "DataRow column count exceeds its payload");
      Result.Columns.Reserve_Capacity (Ada.Containers.Count_Type (Count));

      for Index in 1 .. Natural (Count) loop
         pragma Unreferenced (Index);
         declare
            Length_Value : UInt32;
         begin
            Read_U32_At
              (Contents, Cursor, Length_Value, "DataRow column length");
            if Length_Value = UInt32'Last then
               Result.Columns.Append (Null_Column);
            else
               Require
                 (Length_Value <= UInt32 (Maximum_Message_Size),
                  "DataRow column length exceeds the configured limit");
               declare
                  View    : Wire.Byte_View;
                  Success : Boolean;
               begin
                  Wire.Try_Read_Bytes
                    (Contents,
                     Cursor,
                     Wire.Wire_Length (Length_Value),
                     View,
                     Success);
                  Require (Success, "truncated DataRow column value");
                  Result.Columns.Append
                    (Binary_Column (View_To_Bytes (Contents, View)));
               end;
            end if;
         end;
      end loop;
      Require (Cursor = Contents'Length, "DataRow has trailing payload data");
      return Result;
   end Decode_Data_Row;

   function Decode_Diagnostic (Item : Message) return Diagnostic is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      Result   : Diagnostic;
   begin
      loop
         Require
           (Cursor < Contents'Length,
            "ErrorResponse or NoticeResponse is missing its terminator");
         declare
            Field_Code : constant Character :=
              Character'Val (Wire.Element_At (Contents, Cursor));
         begin
            Cursor := Cursor + 1;
            if Field_Code = Character'Val (0) then
               Require
                 (Cursor = Contents'Length,
                  "ErrorResponse or NoticeResponse has trailing payload data");
               return Result;
            end if;
            declare
               View : Wire.Byte_View;
            begin
               Read_C_String_At
                 (Contents, Cursor, View,
                  "ErrorResponse or NoticeResponse field");
               Result.Fields.Append
                 ((Code => Field_Code,
                   Text => To_Unbounded_String
                     (View_To_String (Contents, View))));
            end;
         end;
      end loop;
   end Decode_Diagnostic;

   function Decode_Parameter_Status
     (Item : Message) return Parameter_Status is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      Name     : Wire.Byte_View;
      Value    : Wire.Byte_View;
   begin
      Read_C_String_At (Contents, Cursor, Name, "ParameterStatus name");
      Read_C_String_At (Contents, Cursor, Value, "ParameterStatus value");
      Require
        (Cursor = Contents'Length,
         "ParameterStatus has trailing payload data");
      return
        (Name  => To_Unbounded_String (View_To_String (Contents, Name)),
         Value => To_Unbounded_String (View_To_String (Contents, Value)));
   end Decode_Parameter_Status;

   function Decode_Parameter_Description
     (Item : Message) return Parameter_Description is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      Count    : UInt16;
      Result   : Parameter_Description;
   begin
      Read_U16_At
        (Contents, Cursor, Count, "ParameterDescription parameter count");
      Require
        (Wire.Count_Fits
           (Contents'Length - Cursor, Count, Minimum_Item_Length => 4),
         "ParameterDescription count exceeds its payload");
      Result.Types.Reserve_Capacity (Ada.Containers.Count_Type (Count));
      for Index in 1 .. Natural (Count) loop
         pragma Unreferenced (Index);
         declare
            Value : UInt32;
         begin
            Read_U32_At
              (Contents, Cursor, Value, "ParameterDescription type OID");
            Result.Types.Append (Value);
         end;
      end loop;
      Require
        (Cursor = Contents'Length,
         "ParameterDescription has trailing payload data");
      return Result;
   end Decode_Parameter_Description;

   procedure Require_Empty_Backend_Payload
     (Contents : Byte_Array; Context : String) is
   begin
      Require
        (Contents'Length = 0, Context & " must have an empty payload");
   end Require_Empty_Backend_Payload;

   function Decode_C_String_Payload
     (Item : Message; Context : String) return String is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 0;
      View     : Wire.Byte_View;
   begin
      Read_C_String_At (Contents, Cursor, View, Context);
      Require
        (Cursor = Contents'Length,
         Context & " has trailing payload data");
      return View_To_String (Contents, View);
   end Decode_C_String_Payload;

   function Decode_Frontend_Copy
     (Item : Message) return Frontend_Copy_Message is
      Contents : constant Byte_Array := Payload (Item);
   begin
      case Kind (Item) is
         when Copy_Data =>
            return (Command => Frontend_Copy_Data, Raw => Item);
         when Copy_Done =>
            Require
              (Contents'Length = 0,
               "frontend CopyDone must have an empty payload");
            return (Command => Frontend_Copy_Done, Raw => Item);
         when Copy_Fail =>
            return
              (Command       => Frontend_Copy_Fail,
               Raw           => Item,
               Failure_Value => To_Unbounded_String
                 (Decode_C_String_Payload (Item, "CopyFail reason")));
         when others =>
            raise Protocol_Error with "message is not a frontend COPY command";
      end case;
   end Decode_Frontend_Copy;

   function Copy_Kind
     (Item : Frontend_Copy_Message) return Frontend_Copy_Kind is
     (Item.Command);

   function Copy_Bytes (Item : Frontend_Copy_Message) return Byte_Array is
   begin
      Require
        (Item.Command = Frontend_Copy_Data,
         "frontend COPY command is not CopyData");
      return Payload (Item.Raw);
   end Copy_Bytes;

   function Copy_Failure_Reason
     (Item : Frontend_Copy_Message) return String is
   begin
      Require
        (Item.Command = Frontend_Copy_Fail,
         "frontend COPY command is not CopyFail");
      return To_String (Item.Failure_Value);
   end Copy_Failure_Reason;

   function Original_Message
     (Item : Frontend_Copy_Message) return Message is (Item.Raw);

   function Decode_Copy_Format_Description
     (Item : Message; Context : String) return Copy_Format_Description is
      Contents : constant Byte_Array := Payload (Item);
      Cursor   : Wire.Wire_Length := 1;
      Count    : UInt16;
      Result   : Copy_Format_Description;
   begin
      Require
        (Contents'Length >= 3,
         Context & " is missing its format header");
      declare
         Code : constant UInt16 := UInt16 (Contents (Contents'First));
      begin
         Require
           (Wire.Copy_Format_Code_Is_Valid (Code),
            Context & " has an invalid overall format code");
         Result.Overall :=
           (if Code = 0 then Text_Format else Binary_Format);
      end;
      Read_U16_At (Contents, Cursor, Count, Context & " column count");
      Require
        (Wire.Copy_Response_Length_Is_Valid (Contents'Length, Count),
         Context & " column count does not match its payload");
      Result.Columns.Reserve_Capacity (Ada.Containers.Count_Type (Count));
      for Index in 1 .. Natural (Count) loop
         pragma Unreferenced (Index);
         declare
            Code : UInt16;
         begin
            Read_U16_At (Contents, Cursor, Code, Context & " column format");
            Require
              (Wire.Copy_Format_Code_Is_Valid (Code),
               Context & " has an invalid column format code");
            Result.Columns.Append
              ((if Code = 0 then Text_Format else Binary_Format));
         end;
      end loop;
      Require (Cursor = Contents'Length, Context & " has trailing data");
      return Result;
   end Decode_Copy_Format_Description;

   function Decode_Backend (Item : Message) return Backend_Message is
      Contents : constant Byte_Array := Payload (Item);
   begin
      case Code (Item) is
         when '1' =>
            Require_Empty_Backend_Payload (Contents, "ParseComplete");
            return (Response => Parse_Complete_Response, Raw => Item);
         when '2' =>
            Require_Empty_Backend_Payload (Contents, "BindComplete");
            return (Response => Bind_Complete_Response, Raw => Item);
         when '3' =>
            Require_Empty_Backend_Payload (Contents, "CloseComplete");
            return (Response => Close_Complete_Response, Raw => Item);
         when 'T' =>
            return
              (Response              => Row_Description_Response,
               Raw                   => Item,
               Row_Description_Value => Decode_Row_Description (Item));
         when 'D' =>
            return
              (Response       => Data_Row_Response,
               Raw            => Item,
               Data_Row_Value => Decode_Data_Row (Item));
         when 'C' =>
            return
              (Response          => Command_Complete_Response,
               Raw               => Item,
               Command_Tag_Value => To_Unbounded_String
                 (Decode_C_String_Payload (Item, "CommandComplete tag")));
         when 'I' =>
            Require
              (Contents'Length = 0,
               "EmptyQueryResponse must have an empty payload");
            return (Response => Empty_Query_Response, Raw => Item);
         when 'E' =>
            return
              (Response         => Error_Response,
               Raw              => Item,
               Diagnostic_Value => Decode_Diagnostic (Item));
         when 'N' =>
            return
              (Response         => Notice_Response,
               Raw              => Item,
               Diagnostic_Value => Decode_Diagnostic (Item));
         when 'S' =>
            return
              (Response               => Parameter_Status_Response,
               Raw                    => Item,
               Parameter_Status_Value => Decode_Parameter_Status (Item));
         when 't' =>
            return
              (Response                    => Parameter_Description_Response,
               Raw                         => Item,
               Parameter_Description_Value =>
                 Decode_Parameter_Description (Item));
         when 'n' =>
            Require_Empty_Backend_Payload (Contents, "NoData");
            return (Response => No_Data_Response, Raw => Item);
         when 's' =>
            Require_Empty_Backend_Payload (Contents, "PortalSuspended");
            return (Response => Portal_Suspended_Response, Raw => Item);
         when 'G' =>
            return
              (Response          => Copy_In_Response,
               Raw               => Item,
               Copy_Format_Value =>
                 Decode_Copy_Format_Description (Item, "CopyInResponse"));
         when 'H' =>
            return
              (Response          => Copy_Out_Response,
               Raw               => Item,
               Copy_Format_Value =>
                 Decode_Copy_Format_Description (Item, "CopyOutResponse"));
         when 'W' =>
            return
              (Response          => Copy_Both_Response,
               Raw               => Item,
               Copy_Format_Value =>
                 Decode_Copy_Format_Description (Item, "CopyBothResponse"));
         when 'd' =>
            return (Response => Copy_Data_Response, Raw => Item);
         when 'c' =>
            Require_Empty_Backend_Payload (Contents, "CopyDone");
            return (Response => Copy_Done_Response, Raw => Item);
         when 'Z' =>
            Require
              (Contents'Length = 1,
               "ReadyForQuery must contain one status byte");
            declare
               Status : constant Character :=
                 Character'Val (Contents (Contents'First));
            begin
               Require
                 (Status in 'I' | 'T' | 'E',
                  "invalid ReadyForQuery transaction status");
               return
                 (Response                 => Ready_For_Query_Response,
                  Raw                      => Item,
                  Transaction_Status_Value =>
                    (case Status is
                       when 'I' => Idle,
                       when 'T' => In_Transaction,
                       when 'E' => Failed_Transaction,
                       when others => Idle));
            end;
         when others =>
            return (Response => Unknown_Response, Raw => Item);
      end case;
   end Decode_Backend;

   function Response_Kind (Item : Backend_Message) return Backend_Message_Kind
   is (Item.Response);

   function Description (Item : Backend_Message) return Row_Description is
   begin
      Require
        (Item.Response = Row_Description_Response,
         "backend response is not RowDescription");
      return Item.Row_Description_Value;
   end Description;

   function Row_Data (Item : Backend_Message) return Data_Row is
   begin
      Require
        (Item.Response = Data_Row_Response,
         "backend response is not DataRow");
      return Item.Data_Row_Value;
   end Row_Data;

   function Completion_Tag (Item : Backend_Message) return String is
   begin
      Require
        (Item.Response = Command_Complete_Response,
         "backend response is not CommandComplete");
      return To_String (Item.Command_Tag_Value);
   end Completion_Tag;

   function Diagnostic_Data (Item : Backend_Message) return Diagnostic is
   begin
      Require
        (Item.Response in Error_Response | Notice_Response,
         "backend response is not ErrorResponse or NoticeResponse");
      return Item.Diagnostic_Value;
   end Diagnostic_Data;

   function Parameter_Data (Item : Backend_Message) return Parameter_Status is
   begin
      Require
        (Item.Response = Parameter_Status_Response,
         "backend response is not ParameterStatus");
      return Item.Parameter_Status_Value;
   end Parameter_Data;

   function Parameter_Types
     (Item : Backend_Message) return Parameter_Description is
   begin
      Require
        (Item.Response = Parameter_Description_Response,
         "backend response is not ParameterDescription");
      return Item.Parameter_Description_Value;
   end Parameter_Types;

   function Overall_Format
     (Item : Copy_Format_Description) return Field_Format is (Item.Overall);

   function Copy_Column_Count
     (Item : Copy_Format_Description) return Natural is
     (Natural (Item.Columns.Length));

   function Copy_Column_Format
     (Item : Copy_Format_Description; Index : Positive) return Field_Format is
   begin
      if Index > Copy_Column_Count (Item) then
         raise Constraint_Error with "COPY column format index is invalid";
      end if;
      return Item.Columns.Element (Index);
   end Copy_Column_Format;

   function Copy_Formats
     (Item : Backend_Message) return Copy_Format_Description is
   begin
      Require
        (Item.Response in Copy_In_Response | Copy_Out_Response |
           Copy_Both_Response,
         "backend response is not a COPY response");
      return Item.Copy_Format_Value;
   end Copy_Formats;

   function Copy_Data (Item : Backend_Message) return Byte_Array is
   begin
      Require
        (Item.Response = Copy_Data_Response,
         "backend response is not CopyData");
      return Payload (Item.Raw);
   end Copy_Data;

   function Transaction_State
     (Item : Backend_Message) return Transaction_Status is
   begin
      Require
        (Item.Response = Ready_For_Query_Response,
         "backend response is not ReadyForQuery");
      return Item.Transaction_Status_Value;
   end Transaction_State;

   function Original_Message (Item : Backend_Message) return Message is
     (Item.Raw);

   function Decode_Initial
     (Contents : Byte_Array) return Initial_Request is
      Decoded : Wire.Decoded_Initial;
      Status  : Wire.Initial_Parse_Status;
      Result  : Initial_Request;
   begin
      Wire.Decode_Initial (Contents, Decoded, Status);
      Require
        (Status = Wire.Initial_Ok,
         "invalid initial Postgres packet: " & Status'Image);

      case Decoded.Kind is
         when Wire.SSL_Request =>
            Result.Request_Kind := SSL_Request;
         when Wire.GSS_Request =>
            Result.Request_Kind := GSS_Request;
         when Wire.Cancel_Request =>
            Result.Request_Kind := Cancel_Request;
            Result.Backend_Pid := Decoded.Process_Id;
            Result.Secret := Flyology.Bytes.To_Unbounded_Bytes
              (View_To_Bytes (Contents, Decoded.Secret_Key));
         when Wire.Startup_Request =>
            Result.Request_Kind := Startup;
            Result.Startup.Protocol_Major := Decoded.Protocol_Major;
            Result.Startup.Protocol_Minor := Decoded.Protocol_Minor;
            Result.Startup.User := To_Unbounded_String
              (View_To_String (Contents, Decoded.User.Value));
            Result.Startup.Database := To_Unbounded_String
              (View_To_String (Contents, Decoded.Database.Value));
            if Decoded.Application_Name.Present then
               Result.Startup.Application_Name := To_Unbounded_String
                 (View_To_String
                    (Contents, Decoded.Application_Name.Value));
            end if;
            declare
               Cursor : Byte_Offset := Contents'First + 4;
            begin
               while Contents (Cursor) /= 0 loop
                  declare
                     Name : constant String :=
                       Read_C_String (Contents, Cursor);
                     Value : constant String :=
                       Read_C_String (Contents, Cursor);
                  begin
                     if Name = "replication" then
                        if Value = "database" then
                           Result.Startup.Replication_Mode :=
                             Logical_Replication_Connection;
                        elsif Value in "true" | "on" | "yes" | "1" then
                           Result.Startup.Replication_Mode :=
                             Physical_Replication_Connection;
                        elsif Value not in
                          "false" | "off" | "no" | "0"
                        then
                           raise Protocol_Error with
                             "invalid startup replication mode";
                        end if;
                     end if;
                  end;
               end loop;
            end;
         when Wire.Unknown_Request =>
            Result.Request_Kind := Unknown_Initial;
      end case;

      return Result;
   end Decode_Initial;

   function Kind (Item : Initial_Request) return Initial_Kind is
     (Item.Request_Kind);

   function Startup_Data
     (Item : Initial_Request) return Startup_Information is
     (Item.Startup);

   function Process_Id (Item : Initial_Request) return UInt32 is
     (Item.Backend_Pid);

   function Secret_Key (Item : Initial_Request) return Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));

   function Encode_Startup
     (User             : String;
      Database         : String := "";
      Application_Name : String := "flyology_postgres";
      Protocol_Major   : UInt16 := 3;
      Protocol_Minor   : UInt16 := 0;
      Replication_Mode : Replication_Connection_Mode := Normal_Connection)
      return Byte_Array is
      Contents : Flyology.Bytes.Unbounded_Bytes;
      Packet : Flyology.Bytes.Unbounded_Bytes;
      Version : constant UInt32 :=
        Shift_Left (UInt32 (Protocol_Major), 16) or UInt32 (Protocol_Minor);
   begin
      Require (User'Length > 0, "a Postgres startup user is required");
      Append_U32 (Contents, Version);
      Append_C_String (Contents, "user");
      Append_C_String (Contents, User);
      if Database'Length > 0 then
         Append_C_String (Contents, "database");
         Append_C_String (Contents, Database);
      end if;
      if Application_Name'Length > 0 then
         Append_C_String (Contents, "application_name");
         Append_C_String (Contents, Application_Name);
      end if;
      if Replication_Mode /= Normal_Connection then
         Append_C_String (Contents, "replication");
         Append_C_String
           (Contents,
            (if Replication_Mode = Physical_Replication_Connection
             then "true"
             else "database"));
      end if;
      Append_Byte (Contents, 0);
      Require
        (Flyology.Bytes.Length (Contents) + 4 <= Maximum_Message_Size,
         "startup packet exceeds the configured limit");
      Append_U32 (Packet, UInt32 (Flyology.Bytes.Length (Contents) + 4));
      Append_Bytes (Packet, Flyology.Bytes.To_Array (Contents));
      return Flyology.Bytes.To_Array (Packet);
   end Encode_Startup;

   function Encode_SSL_Request return Byte_Array is
      Packet : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_U32 (Packet, 8);
      Append_U32 (Packet, SSL_Code);
      return Flyology.Bytes.To_Array (Packet);
   end Encode_SSL_Request;

   function Encode_Cancel_Request
     (Process_Id : UInt32; Secret_Key : Byte_Array) return Byte_Array is
      Packet : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Secret_Key'Length in 4 .. 256,
         "a cancellation secret key must contain 4 through 256 bytes");
      Append_U32 (Packet, UInt32 (Secret_Key'Length + 12));
      Append_U32 (Packet, Wire.Cancel_Request_Code);
      Append_U32 (Packet, Process_Id);
      Append_Bytes (Packet, Secret_Key);
      return Flyology.Bytes.To_Array (Packet);
   end Encode_Cancel_Request;

end Flyology.Postgres.Protocol;
