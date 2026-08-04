with Interfaces; use Interfaces;

package body Flyology.Postgres.Wire
  with SPARK_Mode => On
is

   use type Ada.Streams.Stream_Element_Offset;

   function Element_At
     (Data : Byte_Array; Position : Wire_Length) return Byte is
     (Data (Data'First + Ada.Streams.Stream_Element_Offset (Position)));

   function Decode_U16
     (Data : Byte_Array; Position : Wire_Length) return UInt16 is
     (Shift_Left (UInt16 (Element_At (Data, Position)), 8)
      or UInt16 (Element_At (Data, Position + 1)));

   function Decode_U32
     (Data : Byte_Array; Position : Wire_Length) return UInt32 is
     (Shift_Left (UInt32 (Element_At (Data, Position)), 24)
      or Shift_Left (UInt32 (Element_At (Data, Position + 1)), 16)
      or Shift_Left (UInt32 (Element_At (Data, Position + 2)), 8)
      or UInt32 (Element_At (Data, Position + 3)));

   procedure Try_Read_U16
     (Data     : Byte_Array;
      Cursor   : in out Wire_Length;
      Value    : out UInt16;
      Success  : out Boolean) is
   begin
      if Can_Read (Data, Cursor, 2) then
         Value := Decode_U16 (Data, Cursor);
         Cursor := Cursor + 2;
         Success := True;
      else
         Value := 0;
         Success := False;
      end if;
   end Try_Read_U16;

   procedure Try_Read_U32
     (Data     : Byte_Array;
      Cursor   : in out Wire_Length;
      Value    : out UInt32;
      Success  : out Boolean) is
   begin
      if Can_Read (Data, Cursor, 4) then
         Value := Decode_U32 (Data, Cursor);
         Cursor := Cursor + 4;
         Success := True;
      else
         Value := 0;
         Success := False;
      end if;
   end Try_Read_U32;

   procedure Encode_U16
     (Data     : in out Byte_Array;
      Position : Wire_Length;
      Value    : UInt16) is
   begin
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position)) :=
        Byte (Shift_Right (Value, 8) and 16#FF#);
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position + 1)) :=
        Byte (Value and 16#FF#);
   end Encode_U16;

   procedure Encode_U32
     (Data     : in out Byte_Array;
      Position : Wire_Length;
      Value    : UInt32) is
   begin
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position)) :=
        Byte (Shift_Right (Value, 24) and 16#FF#);
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position + 1)) :=
        Byte (Shift_Right (Value, 16) and 16#FF#);
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position + 2)) :=
        Byte (Shift_Right (Value, 8) and 16#FF#);
      Data (Data'First + Ada.Streams.Stream_Element_Offset (Position + 3)) :=
        Byte (Value and 16#FF#);
   end Encode_U32;

   procedure Find_Nul
     (Data     : Byte_Array;
      Start    : Wire_Length;
      Found    : out Boolean;
      Position : out Wire_Length) is
   begin
      Position := Start;
      while Position < Data'Length loop
         pragma Loop_Invariant (Position in Start .. Data'Length);
         pragma Loop_Invariant
           (for all Offset in Start .. Position =>
              (if Offset < Position then Element_At (Data, Offset) /= 0));
         if Element_At (Data, Position) = 0 then
            Found := True;
            return;
         end if;
         pragma Assert (Element_At (Data, Position) /= 0);
         Position := Position + 1;
      end loop;
      Found := False;
   end Find_Nul;

   procedure Try_Read_C_String
     (Data    : Byte_Array;
      Cursor  : in out Wire_Length;
      View    : out Byte_View;
      Success : out Boolean) is
      Found    : Boolean;
      Position : Wire_Length;
   begin
      if not Fits_Wire_Limit (Data) or else Cursor > Data'Length then
         View := Empty_View;
         Success := False;
         return;
      end if;

      Find_Nul (Data, Cursor, Found, Position);
      if Found then
         View := (First => Cursor, Length => Position - Cursor);
         Cursor := Position + 1;
         Success := True;
      else
         View := Empty_View;
         Success := False;
      end if;
   end Try_Read_C_String;

   function View_Equals
     (Data : Byte_Array; View : Byte_View; Value : String) return Boolean is
   begin
      if View.Length /= Value'Length then
         return False;
      end if;

      for Offset in Wire_Length range 0 .. View.Length - 1 loop
         pragma Loop_Invariant
           (for all Prior in Wire_Length range 0 .. Offset =>
              (if Prior < Offset
               then Element_At (Data, View.First + Prior) =
                 Byte (Character'Pos
                   (Value (Value'First + Integer (Prior))))));
         if Element_At (Data, View.First + Offset) /=
           Byte (Character'Pos
             (Value (Value'First + Integer (Offset))))
         then
            return False;
         end if;
      end loop;
      return True;
   end View_Equals;

   function Content_Length (Length : UInt32) return Wire_Length is
     (Wire_Length (Length - UInt32'(4)));

   procedure Decode_Initial
     (Data   : Byte_Array;
      Value  : out Decoded_Initial;
      Status : out Initial_Parse_Status) is
      Cursor  : Wire_Length := 0;
      Code    : UInt32;
      Success : Boolean;
   begin
      Value := (others => <>);

      if not Fits_Wire_Limit (Data) then
         Status := Initial_Too_Large;
         return;
      end if;

      Try_Read_U32 (Data, Cursor, Code, Success);
      if not Success then
         Status := Initial_Truncated;
         return;
      end if;

      if Code = SSL_Request_Code then
         Value.Kind := SSL_Request;
         Status :=
           (if Data'Length = 4 then Initial_Ok else Initial_Invalid_Length);
         return;
      elsif Code = GSS_Request_Code then
         Value.Kind := GSS_Request;
         Status :=
           (if Data'Length = 4 then Initial_Ok else Initial_Invalid_Length);
         return;
      elsif Code = Cancel_Request_Code then
         Value.Kind := Cancel_Request;
         if Data'Length not in 12 .. 264 then
            Status := Initial_Invalid_Length;
            return;
         end if;
         Try_Read_U32 (Data, Cursor, Value.Process_Id, Success);
         if not Success then
            Status := Initial_Truncated;
            return;
         end if;
         Value.Secret_Key :=
           (First => Cursor, Length => Data'Length - Cursor);
         Status := Initial_Ok;
         return;
      elsif Shift_Right (Code, 16) /= 3 then
         Value.Kind := Unknown_Request;
         Status := Initial_Ok;
         return;
      end if;

      Value.Kind := Startup_Request;
      Value.Protocol_Major := UInt16 (Shift_Right (Code, 16));
      Value.Protocol_Minor := UInt16 (Code and 16#FFFF#);

      while Cursor < Data'Length
        and then Element_At (Data, Cursor) /= 0
      loop
         pragma Loop_Invariant (Cursor in 4 .. Data'Length);
         pragma Loop_Invariant
           (Cursor = 4 or else Element_At (Data, Cursor - 1) = 0);
         pragma Loop_Invariant
           (Valid_Parsed_Parameter
              (Data, User_Parameter_Name, Value.User));
         pragma Loop_Invariant
           (Valid_Parsed_Parameter
              (Data, Database_Parameter_Name, Value.Database));
         pragma Loop_Invariant
           (Valid_Parsed_Parameter
              (Data, Application_Name_Parameter_Name, Value.Application_Name));
         pragma Loop_Variant (Decreases => Data'Length - Cursor);
         declare
            Name        : Byte_View;
            Field_Value : Byte_View;
         begin
            Try_Read_C_String (Data, Cursor, Name, Success);
            if not Success then
               Status := Initial_Unterminated_String;
               return;
            end if;
            Try_Read_C_String (Data, Cursor, Field_Value, Success);
            if not Success then
               Status := Initial_Unterminated_String;
               return;
            end if;

            if View_Equals (Data, Name, User_Parameter_Name) then
               pragma Assert
                 (Byte_View'
                    (First  =>
                       Field_Value.First
                         - Wire_Length (User_Parameter_Name'Length) - 1,
                     Length =>
                       Wire_Length (User_Parameter_Name'Length)) = Name);
               pragma Assert
                 (Parameter_Value_Matches
                    (Data, User_Parameter_Name, Field_Value));
               Value.User := (Present => True, Value => Field_Value);
               pragma Assert
                 (Valid_Parsed_Parameter
                    (Data, User_Parameter_Name, Value.User));
            elsif View_Equals (Data, Name, Database_Parameter_Name) then
               pragma Assert
                 (Byte_View'
                    (First  =>
                       Field_Value.First
                         - Wire_Length (Database_Parameter_Name'Length) - 1,
                     Length =>
                       Wire_Length (Database_Parameter_Name'Length)) = Name);
               pragma Assert
                 (Parameter_Value_Matches
                    (Data, Database_Parameter_Name, Field_Value));
               Value.Database := (Present => True, Value => Field_Value);
               pragma Assert
                 (Valid_Parsed_Parameter
                    (Data, Database_Parameter_Name, Value.Database));
            elsif View_Equals
              (Data, Name, Application_Name_Parameter_Name)
            then
               pragma Assert
                 (Byte_View'
                    (First  =>
                       Field_Value.First
                         - Wire_Length
                           (Application_Name_Parameter_Name'Length) - 1,
                     Length =>
                       Wire_Length
                         (Application_Name_Parameter_Name'Length)) = Name);
               pragma Assert
                 (Parameter_Value_Matches
                    (Data, Application_Name_Parameter_Name, Field_Value));
               Value.Application_Name :=
                 (Present => True, Value => Field_Value);
               pragma Assert
                 (Valid_Parsed_Parameter
                    (Data,
                     Application_Name_Parameter_Name,
                     Value.Application_Name));
            end if;
         end;
      end loop;

      if Cursor >= Data'Length then
         Status := Initial_Missing_Terminator;
         return;
      end if;
      Cursor := Cursor + 1;
      if Cursor /= Data'Length then
         Status := Initial_Trailing_Data;
         return;
      end if;
      if not Value.User.Present or else Value.User.Value.Length = 0 then
         Status := Initial_Missing_User;
         return;
      end if;
      if not Value.Database.Present
        or else Value.Database.Value.Length = 0
      then
         Value.Database := Value.User;
      end if;
      Status := Initial_Ok;
   end Decode_Initial;

end Flyology.Postgres.Wire;
