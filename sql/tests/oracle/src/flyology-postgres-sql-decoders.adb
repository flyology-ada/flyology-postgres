with Ada.Unchecked_Conversion;
with Interfaces; use Interfaces;
with System.Address_To_Access_Conversions;
with System.Storage_Elements; use System.Storage_Elements;

package body Flyology.Postgres.SQL.Decoders is

   use type System.Address;
   package Byte_Access is new System.Address_To_Access_Conversions (Unsigned_8);

   function Read_Byte (Stream : in out Reader) return Unsigned_8 is
   begin
      if Stream.Position >= Stream.Limit then
         raise Decoder_Error with "truncated protobuf payload";
      end if;
      declare
         Result : constant Unsigned_8 :=
           Byte_Access.To_Pointer
             (Stream.Base + Storage_Offset (Stream.Position)).all;
      begin
         Stream.Position := Stream.Position + 1;
         return Result;
      end;
   end Read_Byte;

   procedure Initialize
     (Stream : out Reader; Data : System.Address; Length : Natural) is
   begin
      if Length > 0 and then Data = System.Null_Address then
         raise Decoder_Error with "null protobuf buffer";
      end if;
      Stream := (Base => Data, Position => 0, Limit => Length, Depth => 0);
   end Initialize;

   function At_End (Stream : Reader) return Boolean is
     (Stream.Position = Stream.Limit);

   function Read_Varint (Stream : in out Reader) return Unsigned_64 is
      Result : Unsigned_64 := 0;
   begin
      for Index in 0 .. 9 loop
         declare
            Octet : constant Unsigned_8 := Read_Byte (Stream);
            Bits  : constant Unsigned_64 := Unsigned_64 (Octet and 16#7F#);
         begin
            if Index = 9 and then Bits > 1 then
               raise Decoder_Error with "overflowing protobuf varint";
            end if;
            Result := Result or Shift_Left (Bits, Index * 7);
            if (Octet and 16#80#) = 0 then
               return Result;
            end if;
         end;
      end loop;
      raise Decoder_Error with "unterminated protobuf varint";
   end Read_Varint;

   procedure Read_Key
     (Stream       : in out Reader;
      Field_Number : out Positive;
      Encoding     : out Wire_Type)
   is
      Key    : constant Unsigned_64 := Read_Varint (Stream);
      Number : constant Unsigned_64 := Shift_Right (Key, 3);
      Wire   : constant Unsigned_64 := Key and 7;
   begin
      if Number = 0 or else Number > 536_870_911 then
         raise Decoder_Error with "invalid protobuf field number";
      end if;
      if Wire > 5 then
         raise Decoder_Error with "invalid protobuf wire type";
      end if;
      Field_Number := Positive (Number);
      Encoding := Wire_Type'Val (Natural (Wire));
   end Read_Key;

   function To_Integer_64 is new Ada.Unchecked_Conversion
     (Unsigned_64, Integer_64);
   function To_Integer_32 is new Ada.Unchecked_Conversion
     (Unsigned_32, Integer_32);
   function To_Float_32 is new Ada.Unchecked_Conversion
     (Unsigned_32, IEEE_Float_32);
   function To_Float_64 is new Ada.Unchecked_Conversion
     (Unsigned_64, IEEE_Float_64);

   function Read_Int_64 (Stream : in out Reader) return Integer_64 is
     (To_Integer_64 (Read_Varint (Stream)));

   function Read_Int_32 (Stream : in out Reader) return Integer_32 is
      Value : constant Integer_64 := Read_Int_64 (Stream);
   begin
      if Value not in Integer_64 (Integer_32'First) .. Integer_64 (Integer_32'Last) then
         raise Decoder_Error with "int32 value is out of range";
      end if;
      return Integer_32 (Value);
   end Read_Int_32;

   function Zigzag_64 (Value : Unsigned_64) return Integer_64 is
      Magnitude : constant Unsigned_64 := Shift_Right (Value, 1);
   begin
      if (Value and 1) = 0 then
         return Integer_64 (Magnitude);
      elsif Magnitude = Unsigned_64 (Integer_64'Last) then
         return Integer_64'First;
      else
         return -Integer_64 (Magnitude) - 1;
      end if;
   end Zigzag_64;

   function Read_SInt_64 (Stream : in out Reader) return Integer_64 is
     (Zigzag_64 (Read_Varint (Stream)));

   function Read_SInt_32 (Stream : in out Reader) return Integer_32 is
      Value : constant Integer_64 := Read_SInt_64 (Stream);
   begin
      if Value not in Integer_64 (Integer_32'First) .. Integer_64 (Integer_32'Last) then
         raise Decoder_Error with "sint32 value is out of range";
      end if;
      return Integer_32 (Value);
   end Read_SInt_32;

   function Read_Fixed_32 (Stream : in out Reader) return Unsigned_32 is
      Result : Unsigned_32 := 0;
   begin
      for Index in 0 .. 3 loop
         Result := Result or Shift_Left (Unsigned_32 (Read_Byte (Stream)), Index * 8);
      end loop;
      return Result;
   end Read_Fixed_32;

   function Read_Fixed_64 (Stream : in out Reader) return Unsigned_64 is
      Result : Unsigned_64 := 0;
   begin
      for Index in 0 .. 7 loop
         Result := Result or Shift_Left (Unsigned_64 (Read_Byte (Stream)), Index * 8);
      end loop;
      return Result;
   end Read_Fixed_64;

   function Read_SFixed_32 (Stream : in out Reader) return Integer_32 is
     (To_Integer_32 (Read_Fixed_32 (Stream)));
   function Read_SFixed_64 (Stream : in out Reader) return Integer_64 is
     (To_Integer_64 (Read_Fixed_64 (Stream)));
   function Read_Float (Stream : in out Reader) return IEEE_Float_32 is
     (To_Float_32 (Read_Fixed_32 (Stream)));
   function Read_Double (Stream : in out Reader) return IEEE_Float_64 is
     (To_Float_64 (Read_Fixed_64 (Stream)));

   procedure Read_Embedded (Stream : in out Reader; Child : out Reader) is
      Count : constant Unsigned_64 := Read_Varint (Stream);
      Left  : constant Natural := Stream.Limit - Stream.Position;
   begin
      if Stream.Depth >= Maximum_Message_Depth then
         raise Decoder_Error with "excessive protobuf message recursion";
      end if;
      if Count > Unsigned_64 (Natural'Last) or else Natural (Count) > Left then
         raise Decoder_Error with "truncated or overflowing protobuf length";
      end if;
      Child := (Base => Stream.Base,
                Position => Stream.Position,
                Limit => Stream.Position + Natural (Count),
                Depth => Stream.Depth + 1);
      Stream.Position := Child.Limit;
   end Read_Embedded;

   function Read_Text (Stream : in out Reader) return String is
      Child : Reader;
   begin
      Read_Embedded (Stream, Child);
      declare
         Result : String (1 .. Child.Limit - Child.Position);
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val (Read_Byte (Child));
         end loop;
         return Result;
      end;
   end Read_Text;

   procedure Skip_Field
     (Stream       : in out Reader;
      Field_Number : Positive;
      Encoding     : Wire_Type)
   is
      procedure Skip
        (Number : Positive; Wire : Wire_Type; Nesting : Natural)
      is
         Child_Number : Positive;
         Child_Wire   : Wire_Type;
         Child        : Reader;
         Ignore_64    : Unsigned_64;
         Ignore_32    : Unsigned_32;
      begin
         case Wire is
            when Varint => Ignore_64 := Read_Varint (Stream);
            when Fixed_64 => Ignore_64 := Read_Fixed_64 (Stream);
            when Length_Delimited => Read_Embedded (Stream, Child);
            when Fixed_32 => Ignore_32 := Read_Fixed_32 (Stream);
            when Start_Group =>
               if Nesting >= Maximum_Message_Depth then
                  raise Decoder_Error with "excessive protobuf group recursion";
               end if;
               loop
                  if At_End (Stream) then
                     raise Decoder_Error with "unterminated protobuf group";
                  end if;
                  Read_Key (Stream, Child_Number, Child_Wire);
                  exit when Child_Wire = End_Group and then Child_Number = Number;
                  if Child_Wire = End_Group then
                     raise Decoder_Error with "mismatched protobuf end group";
                  end if;
                  Skip (Child_Number, Child_Wire, Nesting + 1);
               end loop;
            when End_Group =>
               raise Decoder_Error with "unexpected protobuf end group";
         end case;
      end Skip;
   begin
      Skip (Field_Number, Encoding, 0);
   end Skip_Field;

end Flyology.Postgres.SQL.Decoders;
