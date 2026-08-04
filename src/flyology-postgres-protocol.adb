with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Protocol is

   use type Ada.Streams.Stream_Element_Offset;
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
        (Payload'Length + 4 <= Maximum_Message_Size,
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
      Protocol_Minor   : UInt16 := 0) return Byte_Array is
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

end Flyology.Postgres.Protocol;
