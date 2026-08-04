with Ada.Streams;
with Interfaces;

--  Pure, allocation-free Postgres wire primitives. Logical positions are
--  zero-based offsets into Source or Target, independent of array bounds.
package Flyology.Postgres.Wire
  with SPARK_Mode => On
is

   use type Ada.Streams.Stream_Element;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   subtype Byte is Ada.Streams.Stream_Element;
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype UInt16 is Interfaces.Unsigned_16;
   subtype UInt32 is Interfaces.Unsigned_32;

   Maximum_Frame_Size : constant := Flyology.Postgres.Maximum_Message_Size;
   subtype Wire_Length is Natural range 0 .. Maximum_Frame_Size;

   function Fits_Wire_Limit (Data : Byte_Array) return Boolean is
     (Data'Length <= Maximum_Frame_Size);

   function Can_Read
     (Data     : Byte_Array;
      Position : Wire_Length;
      Count    : Wire_Length) return Boolean is
     (Fits_Wire_Limit (Data)
      and then Position <= Data'Length
      and then Count <= Data'Length - Position);

   type Byte_View is record
      First  : Wire_Length := 0;
      Length : Wire_Length := 0;
   end record;

   Empty_View : constant Byte_View := (First => 0, Length => 0);

   function Valid_View
     (Data : Byte_Array; View : Byte_View) return Boolean is
     (Fits_Wire_Limit (Data)
      and then View.First <= Data'Length
      and then View.Length <= Data'Length - View.First);

   type Optional_Byte_View is record
      Present : Boolean := False;
      Value   : Byte_View := Empty_View;
   end record;

   function Valid_Optional_View
     (Data : Byte_Array; View : Optional_Byte_View) return Boolean is
     (not View.Present or else Valid_View (Data, View.Value));

   function Element_At
     (Data : Byte_Array; Position : Wire_Length) return Byte
   with
     Pre => Fits_Wire_Limit (Data) and then Position < Data'Length;

   function Decode_U16
     (Data : Byte_Array; Position : Wire_Length) return UInt16
   with
     Pre => Can_Read (Data, Position, 2);

   function Decode_U32
     (Data : Byte_Array; Position : Wire_Length) return UInt32
   with
     Pre => Can_Read (Data, Position, 4);

   procedure Try_Read_U16
     (Data     : Byte_Array;
      Cursor   : in out Wire_Length;
      Value    : out UInt16;
      Success  : out Boolean)
   with
     Post =>
       (if Can_Read (Data, Cursor'Old, 2)
        then Success
          and then Cursor = Cursor'Old + 2
          and then Value = Decode_U16 (Data, Cursor'Old)
        else not Success
          and then Cursor = Cursor'Old
          and then Value = 0);

   procedure Try_Read_U32
     (Data     : Byte_Array;
      Cursor   : in out Wire_Length;
      Value    : out UInt32;
      Success  : out Boolean)
   with
     Post =>
       (if Can_Read (Data, Cursor'Old, 4)
        then Success
          and then Cursor = Cursor'Old + 4
          and then Value = Decode_U32 (Data, Cursor'Old)
        else not Success
          and then Cursor = Cursor'Old
          and then Value = 0);

   function Count_Fits
     (Remaining           : Wire_Length;
      Count               : UInt16;
      Minimum_Item_Length : Wire_Length) return Boolean is
     (Minimum_Item_Length = 0
      or else Natural (Count) <= Remaining / Minimum_Item_Length);

   function Format_Count_Is_Valid
     (Format_Count : UInt16; Value_Count : UInt16) return Boolean is
     (Format_Count = 0
      or else Format_Count = 1
      or else Format_Count = Value_Count);

   procedure Try_Read_Bytes
     (Data    : Byte_Array;
      Cursor  : in out Wire_Length;
      Count   : Wire_Length;
      View    : out Byte_View;
      Success : out Boolean)
   with
     Post =>
       (if Can_Read (Data, Cursor'Old, Count)
        then Success
          and then View = (First => Cursor'Old, Length => Count)
          and then Valid_View (Data, View)
          and then Cursor = Cursor'Old + Count
        else not Success
          and then Cursor = Cursor'Old
          and then View = Empty_View);

   function Terminated_View
     (Data : Byte_Array; View : Byte_View) return Boolean is
     (Valid_View (Data, View)
      and then View.Length < Data'Length - View.First
      and then Element_At (Data, View.First + View.Length) = 0);

   function C_String_View
     (Data : Byte_Array; View : Byte_View) return Boolean is
     (Terminated_View (Data, View)
      and then
        (for all Offset in Wire_Length range 0 .. View.Length =>
           (if Offset < View.Length
            then Element_At (Data, View.First + Offset) /= 0)));

   function Valid_Optional_C_String_View
     (Data : Byte_Array; View : Optional_Byte_View) return Boolean is
     (not View.Present or else C_String_View (Data, View.Value));

   procedure Try_Read_C_String
     (Data    : Byte_Array;
      Cursor  : in out Wire_Length;
      View    : out Byte_View;
      Success : out Boolean)
   with
     Post =>
       (if Success
        then View.First = Cursor'Old
          and then C_String_View (Data, View)
          and then Cursor = View.First + View.Length + 1
        else Cursor = Cursor'Old and then View = Empty_View);

   function View_Content_Equals
     (Data : Byte_Array; View : Byte_View; Value : String) return Boolean is
     (View.Length = Value'Length
      and then
        (for all Offset in Wire_Length range 0 .. View.Length =>
           (if Offset < View.Length
            then Element_At (Data, View.First + Offset) =
              Byte (Character'Pos
                (Value (Value'First + Integer (Offset)))))))
   with
     Ghost,
     Pre => Valid_View (Data, View);

   function View_Equals
     (Data : Byte_Array; View : Byte_View; Value : String) return Boolean
   with
     Pre  => Valid_View (Data, View),
     Post =>
       View_Equals'Result = View_Content_Equals (Data, View, Value);

   procedure Encode_U16
     (Data     : in out Byte_Array;
      Position : Wire_Length;
      Value    : UInt16)
   with
     Pre  => Can_Read (Data, Position, 2),
     Post =>
       Element_At (Data, Position) =
         Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#)
       and then Element_At (Data, Position + 1) =
         Byte (Value and 16#FF#);

   procedure Encode_U32
     (Data     : in out Byte_Array;
      Position : Wire_Length;
      Value    : UInt32)
   with
     Pre  => Can_Read (Data, Position, 4),
     Post =>
       Element_At (Data, Position) =
         Byte (Interfaces.Shift_Right (Value, 24) and 16#FF#)
       and then Element_At (Data, Position + 1) =
         Byte (Interfaces.Shift_Right (Value, 16) and 16#FF#)
       and then Element_At (Data, Position + 2) =
         Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#)
       and then Element_At (Data, Position + 3) =
         Byte (Value and 16#FF#);

   procedure Find_Nul
     (Data     : Byte_Array;
      Start    : Wire_Length;
      Found    : out Boolean;
      Position : out Wire_Length)
   with
     Pre  => Fits_Wire_Limit (Data) and then Start <= Data'Length,
     Post =>
       Position in Start .. Data'Length
       and then
         (for all Offset in Start .. Position =>
            (if Offset < Position then Element_At (Data, Offset) /= 0))
       and then (if Found
                 then Position < Data'Length
                   and then Element_At (Data, Position) = 0
                 else Position = Data'Length);

   function Valid_Initial_Length (Length : UInt32) return Boolean is
     (Length >= 8 and then Length <= UInt32 (Maximum_Frame_Size));

   function Valid_Typed_Length (Length : UInt32) return Boolean is
     (Length >= 4 and then Length <= UInt32 (Maximum_Frame_Size));

   function Content_Length (Length : UInt32) return Wire_Length
   with
     Pre  => Valid_Typed_Length (Length),
     Post => Content_Length'Result = Wire_Length (Length - UInt32'(4));

   type Initial_View_Kind is
     (Startup_Request,
      SSL_Request,
      GSS_Request,
      Cancel_Request,
      Unknown_Request);

   type Initial_Parse_Status is
     (Initial_Ok,
      Initial_Too_Large,
      Initial_Truncated,
      Initial_Invalid_Length,
      Initial_Unterminated_String,
      Initial_Missing_Terminator,
      Initial_Trailing_Data,
      Initial_Missing_User);

   SSL_Request_Code    : constant UInt32 := 80_877_103;
   GSS_Request_Code    : constant UInt32 := 80_877_104;
   Cancel_Request_Code : constant UInt32 := 80_877_102;

   User_Parameter_Name             : constant String := "user";
   Database_Parameter_Name         : constant String := "database";
   Application_Name_Parameter_Name : constant String := "application_name";

   type Decoded_Initial is record
      Kind             : Initial_View_Kind := Unknown_Request;
      Protocol_Major   : UInt16 := 0;
      Protocol_Minor   : UInt16 := 0;
      Process_Id       : UInt32 := 0;
      Secret_Key       : Byte_View := Empty_View;
      User             : Optional_Byte_View;
      Database         : Optional_Byte_View;
      Application_Name : Optional_Byte_View;
   end record;

   function Parameter_Value_Matches
     (Data  : Byte_Array;
      Name  : String;
      Value : Byte_View) return Boolean is
     (Name'Length <= Maximum_Frame_Size - 5
      and then Value.First >= Wire_Length (Name'Length) + 5
      and then C_String_View
        (Data,
         (First  => Value.First - Wire_Length (Name'Length) - 1,
          Length => Wire_Length (Name'Length)))
      and then View_Equals
        (Data,
         (First  => Value.First - Wire_Length (Name'Length) - 1,
          Length => Wire_Length (Name'Length)),
         Name)
      and then
        (Value.First - Wire_Length (Name'Length) - 1 = 4
         or else Element_At
           (Data, Value.First - Wire_Length (Name'Length) - 2) = 0))
   with
     Ghost,
     Pre => C_String_View (Data, Value);

   function Valid_Parsed_Parameter
     (Data  : Byte_Array;
      Name  : String;
      Value : Optional_Byte_View) return Boolean is
     (not Value.Present
      or else
        (C_String_View (Data, Value.Value)
         and then Parameter_Value_Matches (Data, Name, Value.Value)))
   with Ghost;

   function Valid_Decoded_Initial
     (Data   : Byte_Array;
      Value  : Decoded_Initial;
      Status : Initial_Parse_Status) return Boolean is
     (if Status /= Initial_Ok then True
      else Fits_Wire_Limit (Data)
        and then Data'Length >= 4
        and then
       (if Value.Kind = Startup_Request then
        Data'Length > 4
        and then Decode_U32 (Data, 0) =
          (Interfaces.Shift_Left (UInt32 (Value.Protocol_Major), 16)
           or UInt32 (Value.Protocol_Minor))
        and then Value.Protocol_Major = 3
        and then Value.User.Present
        and then Value.User.Value.Length > 0
        and then Value.Database.Present
        and then C_String_View (Data, Value.User.Value)
        and then Parameter_Value_Matches
          (Data, User_Parameter_Name, Value.User.Value)
        and then C_String_View (Data, Value.Database.Value)
        and then
          (Value.Database.Value = Value.User.Value
           or else Parameter_Value_Matches
             (Data, Database_Parameter_Name, Value.Database.Value))
        and then Valid_Parsed_Parameter
          (Data, Application_Name_Parameter_Name, Value.Application_Name)
        and then Element_At (Data, Data'Length - 1) = 0
      elsif Value.Kind = Cancel_Request then
        Data'Length in 12 .. 264
        and then Decode_U32 (Data, 0) = Cancel_Request_Code
        and then Value.Process_Id = Decode_U32 (Data, 4)
        and then Value.Secret_Key.First = 8
        and then Value.Secret_Key.Length = Data'Length - 8
        and then Valid_View (Data, Value.Secret_Key)
        and then Value.Secret_Key.Length in 4 .. 256
      elsif Value.Kind = SSL_Request then
        Data'Length = 4
        and then Decode_U32 (Data, 0) = SSL_Request_Code
      elsif Value.Kind = GSS_Request then
        Data'Length = 4
        and then Decode_U32 (Data, 0) = GSS_Request_Code
      else Decode_U32 (Data, 0) not in
        SSL_Request_Code | GSS_Request_Code | Cancel_Request_Code
        and then Interfaces.Shift_Right (Decode_U32 (Data, 0), 16) /= 3))
   with Ghost;

   procedure Decode_Initial
     (Data   : Byte_Array;
      Value  : out Decoded_Initial;
      Status : out Initial_Parse_Status)
   with
     Post => Valid_Decoded_Initial (Data, Value, Status);

end Flyology.Postgres.Wire;
