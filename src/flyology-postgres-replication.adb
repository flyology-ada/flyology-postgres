with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;

package body Flyology.Postgres.Replication is

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   function To_UInt64 is new Ada.Unchecked_Conversion
     (Source => Int64, Target => UInt64);
   function To_Int64 is new Ada.Unchecked_Conversion
     (Source => UInt64, Target => Int64);

   function Byte_String (Value : String) return Byte_Array is
      Result : Byte_Array (1 .. Ada.Streams.Stream_Element_Offset
        (Value'Length));
      Cursor : Ada.Streams.Stream_Element_Offset := Result'First;
   begin
      for Item of Value loop
         Result (Cursor) := Byte (Character'Pos (Item));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end Byte_String;

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Information;
      end if;
   end Require;

   function Hex_Digit (Value : UInt64) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Integer (Value))
      else Character'Val (Character'Pos ('A') + Integer (Value - 10)));

   function Hex_Image (Value : UInt32) return String is
      Buffer : String (1 .. 8);
      First  : Positive := Buffer'Last;
      Work   : UInt64 := UInt64 (Value);
   begin
      loop
         Buffer (First) := Hex_Digit (Work mod 16);
         exit when Work < 16;
         Work := Work / 16;
         First := First - 1;
      end loop;
      return Buffer (First .. Buffer'Last);
   end Hex_Image;

   function Image (Value : LSN) return String is
      High : constant UInt32 := UInt32
        (Interfaces.Shift_Right (Value, 32));
      Low  : constant UInt32 := UInt32 (Value and 16#FFFF_FFFF#);
   begin
      return Hex_Image (High) & "/" & Hex_Image (Low);
   end Image;

   function Hex_Value (Text : String) return UInt32 is
      Result : UInt32 := 0;
      Digit  : UInt32;
      Upper  : Character;
   begin
      Require
        (Text'Length in 1 .. 8,
         "a replication LSN component must contain 1 through 8 digits");
      for Item of Text loop
         Upper := Ada.Characters.Handling.To_Upper (Item);
         if Upper in '0' .. '9' then
            Digit := Character'Pos (Upper) - Character'Pos ('0');
         elsif Upper in 'A' .. 'F' then
            Digit := Character'Pos (Upper) - Character'Pos ('A') + 10;
         else
            raise Protocol.Protocol_Error with
              "a replication LSN contains a non-hexadecimal digit";
         end if;
         Result := Interfaces.Shift_Left (Result, 4) or Digit;
      end loop;
      return Result;
   end Hex_Value;

   function Value (Text : String) return LSN is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Text, "/");
   begin
      Require
        (Slash > Text'First and then Slash < Text'Last,
         "a replication LSN must have the form HEX/HEX");
      Require
        (Ada.Strings.Fixed.Index
           (Text (Slash + 1 .. Text'Last), "/") = 0,
         "a replication LSN contains more than one slash");
      return Interfaces.Shift_Left
        (UInt64 (Hex_Value (Text (Text'First .. Slash - 1))), 32)
        or UInt64 (Hex_Value (Text (Slash + 1 .. Text'Last)));
   end Value;

   function Is_Option_Name (Name : String) return Boolean is
     (Name'Length > 0
      and then
        (for all Item of Name =>
           Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'));

   function Is_Slot_Name (Name : String) return Boolean is
     (Name'Length in 1 .. 63
      and then
        (for all Item of Name => Item in 'a' .. 'z' | '0' .. '9' | '_'));

   function SQL_Literal (Text : String) return String is
      Count : Natural := 2;
   begin
      for Item of Text loop
         Count := Count + (if Item = ''' then 2 else 1);
      end loop;
      declare
         Result : String (1 .. Count);
         Cursor : Positive := Result'First;
      begin
         Result (Cursor) := ''';
         Cursor := Cursor + 1;
         for Item of Text loop
            Result (Cursor) := Item;
            Cursor := Cursor + 1;
            if Item = ''' then
               Result (Cursor) := ''';
               Cursor := Cursor + 1;
            end if;
         end loop;
         Result (Cursor) := ''';
         return Result;
      end;
   end SQL_Literal;

   function Query (Text : String) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Text'Length <= Protocol.Maximum_Message_Size - 5,
         "replication command exceeds the configured message limit");
      Protocol.Append_C_String (Contents, Text);
      return Protocol.Make_Message
        ('Q', Flyology.Bytes.To_Array (Contents));
   end Query;

   function Decimal_Image (Value : UInt32) return String is
     (Ada.Strings.Fixed.Trim (UInt32'Image (Value), Ada.Strings.Both));

   function Option (Name : String) return Logical_Option is
   begin
      Require (Is_Option_Name (Name), "invalid logical option name");
      return
        (Name      => Flyology.Bytes.From_Byte_String (Name),
         Data      => Flyology.Bytes.Empty,
         Has_Value => False);
   end Option;

   function Option (Name : String; Value : String) return Logical_Option is
   begin
      Require (Is_Option_Name (Name), "invalid logical option name");
      Require
        (Value'Length <= Protocol.Maximum_Message_Size,
         "logical option value exceeds the configured limit");
      return
        (Name      => Flyology.Bytes.From_Byte_String (Name),
         Data      => Flyology.Bytes.From_Byte_String (Value),
         Has_Value => True);
   end Option;

   function Option_Name (Item : Logical_Option) return String is
     (Flyology.Bytes.To_Byte_String (Item.Name));

   function Option_Value (Item : Logical_Option) return String is
     (Flyology.Bytes.To_Byte_String (Item.Data));

   function Option_Has_Value (Item : Logical_Option) return Boolean is
     (Item.Has_Value);

   function Identify_System return Protocol.Message is
     (Query ("IDENTIFY_SYSTEM"));

   function Show (Parameter : String) return Protocol.Message is
   begin
      Require
        (Is_Option_Name (Parameter),
         "invalid replication SHOW parameter name");
      return Query ("SHOW " & Parameter);
   end Show;

   function Timeline_History (Timeline : UInt32) return Protocol.Message is
   begin
      Require (Timeline > 0, "a replication timeline must be positive");
      return Query ("TIMELINE_HISTORY " & Decimal_Image (Timeline));
   end Timeline_History;

   function Start_Physical
     (Position  : LSN;
      Slot_Name : String := "";
      Timeline  : UInt32 := 0) return Protocol.Message is
      Slot : constant String :=
        (if Slot_Name'Length = 0 then "" else " SLOT " & Slot_Name);
      Line : constant String :=
        (if Timeline = 0
         then ""
         else " TIMELINE " & Decimal_Image (Timeline));
   begin
      Require
        (Slot_Name'Length = 0 or else Is_Slot_Name (Slot_Name),
         "invalid physical replication slot name");
      return Query
        ("START_REPLICATION" & Slot & " PHYSICAL " & Image (Position)
         & Line);
   end Start_Physical;

   function Start_Logical
     (Slot_Name : String;
      Position  : LSN;
      Options   : Logical_Option_Array := No_Logical_Options)
      return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Is_Slot_Name (Slot_Name), "invalid logical replication slot name");
      Flyology.Bytes.Append
        (Contents,
         Byte_String
           ("START_REPLICATION SLOT " & Slot_Name & " LOGICAL "
            & Image (Position)));
      if Options'Length > 0 then
         Flyology.Bytes.Append (Contents, Byte_String (" ("));
         for Index in Options'Range loop
            if Index /= Options'First then
               Flyology.Bytes.Append (Contents, Byte_String (", "));
            end if;
            Flyology.Bytes.Append
              (Contents, Byte_String (Option_Name (Options (Index))));
            if Option_Has_Value (Options (Index)) then
               Flyology.Bytes.Append
                 (Contents,
                  Byte_String
                    (" " & SQL_Literal (Option_Value (Options (Index)))));
            end if;
         end loop;
         Flyology.Bytes.Append (Contents, Byte_String (")"));
      end if;
      return Query (Flyology.Bytes.To_Byte_String (Contents));
   end Start_Logical;

   function Query_Text (Item : Protocol.Message) return String is
      Data : constant Byte_Array := Protocol.Payload (Item);
   begin
      Require
        (Protocol.Code (Item) = 'Q',
         "a replication command must use simple Query framing");
      Require
        (Data'Length > 0 and then Data (Data'Last) = 0,
         "a replication query must end with a zero byte");
      if Data'Length > 1 then
         for Index in Data'First .. Data'Last - 1 loop
            Require
              (Data (Index) /= 0,
               "a replication query contains an embedded zero byte");
         end loop;
      end if;
      return Flyology.Bytes.To_Byte_String
        (Flyology.Bytes.To_Unbounded_Bytes
           (Data (Data'First .. Data'Last - 1)));
   end Query_Text;

   function Is_Space (Item : Character) return Boolean is
     (Item in ' ' | ASCII.HT | ASCII.LF | ASCII.CR | ASCII.FF);

   procedure Skip_Spaces (Text : String; Cursor : in out Natural) is
   begin
      while Cursor <= Text'Last and then Is_Space (Text (Cursor)) loop
         Cursor := Cursor + 1;
      end loop;
   end Skip_Spaces;

   function Next_Token
     (Text : String; Cursor : in out Natural) return String is
      First : Natural;
   begin
      Skip_Spaces (Text, Cursor);
      First := Cursor;
      while Cursor <= Text'Last
        and then not Is_Space (Text (Cursor))
        and then Text (Cursor) not in '(' | ')' | ','
      loop
         Cursor := Cursor + 1;
      end loop;
      Require (Cursor > First, "missing replication command token");
      return Text (First .. Cursor - 1);
   end Next_Token;

   function Is_Keyword (Token : String; Expected : String) return Boolean is
     (Ada.Characters.Handling.To_Upper (Token) = Expected);

   procedure Expect_Keyword
     (Text     : String;
      Cursor   : in out Natural;
      Expected : String) is
      Token : constant String := Next_Token (Text, Cursor);
   begin
      Require
        (Is_Keyword (Token, Expected),
         "expected " & Expected & " in replication command");
   end Expect_Keyword;

   procedure Expect_End (Text : String; Cursor : in out Natural) is
   begin
      Skip_Spaces (Text, Cursor);
      Require
        (Cursor > Text'Last,
         "unexpected trailing replication command input");
   end Expect_End;

   function Decimal_Value (Text : String) return UInt32 is
   begin
      Require
        (Text'Length > 0
         and then (for all Item of Text => Item in '0' .. '9'),
         "a replication timeline must be an unsigned decimal integer");
      return UInt32'Value (Text);
   exception
      when Constraint_Error =>
         raise Protocol.Protocol_Error with
           "a replication timeline is outside the supported range";
   end Decimal_Value;

   function Read_Quoted
     (Text : String; Cursor : in out Natural) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Require
        (Cursor <= Text'Last and then Text (Cursor) = ''',
         "expected a quoted logical replication option value");
      Cursor := Cursor + 1;
      while Cursor <= Text'Last loop
         if Text (Cursor) /= ''' then
            Ada.Strings.Unbounded.Append (Result, Text (Cursor));
            Cursor := Cursor + 1;
         elsif Cursor < Text'Last and then Text (Cursor + 1) = ''' then
            Ada.Strings.Unbounded.Append (Result, ''');
            Cursor := Cursor + 2;
         else
            Cursor := Cursor + 1;
            return Ada.Strings.Unbounded.To_String (Result);
         end if;
      end loop;
      raise Protocol.Protocol_Error with
        "unterminated logical replication option value";
   end Read_Quoted;

   package Option_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Logical_Option);

   function Parse_Options (Text : String) return Logical_Option_Array is
      Cursor : Natural := Text'First;
      Values : Option_Vectors.Vector;
   begin
      Skip_Spaces (Text, Cursor);
      Require
        (Cursor <= Text'Last and then Text (Cursor) = '(',
         "logical replication options must begin with '('");
      Cursor := Cursor + 1;
      Skip_Spaces (Text, Cursor);
      if Cursor <= Text'Last and then Text (Cursor) = ')' then
         Cursor := Cursor + 1;
      else
         loop
            declare
               Name : constant String := Next_Token (Text, Cursor);
            begin
               Require
                 (Is_Option_Name (Name),
                  "invalid logical replication option name");
               Skip_Spaces (Text, Cursor);
               if Cursor <= Text'Last and then Text (Cursor) = ''' then
                  Values.Append (Option (Name, Read_Quoted (Text, Cursor)));
               else
                  Values.Append (Option (Name));
               end if;
            end;
            Skip_Spaces (Text, Cursor);
            Require
              (Cursor <= Text'Last,
               "unterminated logical replication option list");
            if Text (Cursor) = ')' then
               Cursor := Cursor + 1;
               exit;
            end if;
            Require
              (Text (Cursor) = ',',
               "expected ',' between logical replication options");
            Cursor := Cursor + 1;
         end loop;
      end if;
      Expect_End (Text, Cursor);
      declare
         Result : Logical_Option_Array (1 .. Natural (Values.Length));
      begin
         for Index in Result'Range loop
            Result (Index) := Values (Index);
         end loop;
         return Result;
      end;
   end Parse_Options;

   function Decode_Command (Item : Protocol.Message) return Command is
      Text   : constant String := Query_Text (Item);
      Cursor : Natural := Text'First;
      First  : constant String := Next_Token (Text, Cursor);
      Result : Command := (Raw => Item, others => <>);

      function More return Boolean is
      begin
         Skip_Spaces (Text, Cursor);
         return Cursor <= Text'Last;
      end More;

      procedure Set_Timeline is
      begin
         Result.Timeline_Value := Decimal_Value (Next_Token (Text, Cursor));
         Require
           (Result.Timeline_Value > 0,
            "a replication timeline must be positive");
         Result.Timeline_Present := True;
      end Set_Timeline;
   begin
      if Is_Keyword (First, "IDENTIFY_SYSTEM") then
         Result.Message_Kind := Identify_System_Command;
         Expect_End (Text, Cursor);
      elsif Is_Keyword (First, "SHOW") then
         Result.Message_Kind := Show_Command;
         declare
            Name : constant String := Next_Token (Text, Cursor);
         begin
            Require
              (Is_Option_Name (Name),
               "invalid replication SHOW parameter name");
            Result.Parameter_Data :=
              Flyology.Bytes.From_Byte_String (Name);
         end;
         Expect_End (Text, Cursor);
      elsif Is_Keyword (First, "TIMELINE_HISTORY") then
         Result.Message_Kind := Timeline_History_Command;
         Set_Timeline;
         Expect_End (Text, Cursor);
      elsif Is_Keyword (First, "START_REPLICATION") then
         declare
            Token : Ada.Strings.Unbounded.Unbounded_String :=
              Ada.Strings.Unbounded.To_Unbounded_String
                (Next_Token (Text, Cursor));
         begin
            if Is_Keyword
              (Ada.Strings.Unbounded.To_String (Token), "SLOT")
            then
               Token := Ada.Strings.Unbounded.To_Unbounded_String
                 (Next_Token (Text, Cursor));
               Require
                 (Is_Slot_Name (Ada.Strings.Unbounded.To_String (Token)),
                  "invalid replication slot name");
               Result.Slot_Data :=
                 Flyology.Bytes.From_Byte_String
                   (Ada.Strings.Unbounded.To_String (Token));
               Token := Ada.Strings.Unbounded.To_Unbounded_String
                 (Next_Token (Text, Cursor));
            end if;

            if Is_Keyword
              (Ada.Strings.Unbounded.To_String (Token), "LOGICAL")
            then
               Result.Message_Kind := Start_Logical_Command;
               Require
                 (Flyology.Bytes.Length (Result.Slot_Data) > 0,
                  "logical replication requires a slot");
               Result.Start_Position := Value (Next_Token (Text, Cursor));
               if More then
                  Result.Options_Data := Flyology.Bytes.From_Byte_String
                    (Text (Cursor .. Text'Last));
                  declare
                     Ignored : constant Logical_Option_Array :=
                       Parse_Options
                         (Flyology.Bytes.To_Byte_String
                            (Result.Options_Data));
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               end if;
            else
               Result.Message_Kind := Start_Physical_Command;
               if Is_Keyword
                 (Ada.Strings.Unbounded.To_String (Token), "PHYSICAL")
               then
                  Token := Ada.Strings.Unbounded.To_Unbounded_String
                    (Next_Token (Text, Cursor));
               end if;
               Result.Start_Position :=
                 Value (Ada.Strings.Unbounded.To_String (Token));
               if More then
                  Expect_Keyword (Text, Cursor, "TIMELINE");
                  Set_Timeline;
               end if;
               Expect_End (Text, Cursor);
            end if;
         end;
      else
         raise Protocol.Protocol_Error with
           "unsupported replication command " & First;
      end if;
      return Result;
   end Decode_Command;

   function Kind (Item : Command) return Command_Kind is
     (Item.Message_Kind);

   function Original_Message (Item : Command) return Protocol.Message is
     (Item.Raw);

   function Parameter (Item : Command) return String is
   begin
      Require
        (Item.Message_Kind = Show_Command,
         "replication command does not contain a SHOW parameter");
      return Flyology.Bytes.To_Byte_String (Item.Parameter_Data);
   end Parameter;

   function Slot_Name (Item : Command) return String is
   begin
      Require
        (Item.Message_Kind in Start_Physical_Command |
           Start_Logical_Command,
         "replication command does not contain a slot");
      return Flyology.Bytes.To_Byte_String (Item.Slot_Data);
   end Slot_Name;

   function Position (Item : Command) return LSN is
   begin
      Require
        (Item.Message_Kind in Start_Physical_Command |
           Start_Logical_Command,
         "replication command does not contain a start position");
      return Item.Start_Position;
   end Position;

   function Has_Timeline (Item : Command) return Boolean is
   begin
      Require
        (Item.Message_Kind in Timeline_History_Command |
           Start_Physical_Command,
         "replication command cannot contain a timeline");
      return Item.Timeline_Present;
   end Has_Timeline;

   function Timeline (Item : Command) return UInt32 is
   begin
      Require
        (Item.Message_Kind in Timeline_History_Command |
           Start_Physical_Command
         and then Item.Timeline_Present,
         "replication command does not contain a timeline");
      return Item.Timeline_Value;
   end Timeline;

   function Options (Item : Command) return Logical_Option_Array is
   begin
      Require
        (Item.Message_Kind = Start_Logical_Command,
         "replication command does not contain logical options");
      if Flyology.Bytes.Length (Item.Options_Data) = 0 then
         return No_Logical_Options;
      end if;
      return Parse_Options
        (Flyology.Bytes.To_Byte_String (Item.Options_Data));
   end Options;

   procedure Append_U64
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt64) is
   begin
      Protocol.Append_U32
        (Target, UInt32 (Interfaces.Shift_Right (Value, 32)));
      Protocol.Append_U32 (Target, UInt32 (Value and 16#FFFF_FFFF#));
   end Append_U64;

   function Read_U64
     (Source : Byte_Array;
      Cursor : in out Ada.Streams.Stream_Element_Offset) return UInt64 is
      High : constant UInt32 := Protocol.Read_U32 (Source, Cursor);
      Low  : constant UInt32 := Protocol.Read_U32 (Source, Cursor);
   begin
      return Interfaces.Shift_Left (UInt64 (High), 32) or UInt64 (Low);
   end Read_U64;

   procedure Append_Timestamp
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication_Timestamp) is
   begin
      Append_U64 (Target, To_UInt64 (Value));
   end Append_Timestamp;

   function Read_Timestamp
     (Source : Byte_Array;
      Cursor : in out Ada.Streams.Stream_Element_Offset)
      return Replication_Timestamp is
   begin
      return To_Int64 (Read_U64 (Source, Cursor));
   end Read_Timestamp;

   function Boolean_Byte (Value : Boolean) return Byte is
     (if Value then 1 else 0);

   function Copy_Data_Message
     (Kind : Character;
      Payload : Flyology.Bytes.Unbounded_Bytes) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_Byte (Contents, Byte (Character'Pos (Kind)));
      Protocol.Append_Bytes (Contents, Flyology.Bytes.To_Array (Payload));
      return Protocol.Make_Copy_Data_Message
        (Flyology.Bytes.To_Array (Contents));
   end Copy_Data_Message;

   function Make_XLog_Data
     (WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Data'Length <= Protocol.Maximum_Message_Size - 29,
         "replication WAL data exceeds the configured message limit");
      Append_U64 (Contents, WAL_Start);
      Append_U64 (Contents, WAL_End);
      Append_Timestamp (Contents, Sent_At);
      Protocol.Append_Bytes (Contents, Data);
      return Copy_Data_Message ('w', Contents);
   end Make_XLog_Data;

   function Make_Primary_Keepalive
     (WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_U64 (Contents, WAL_End);
      Append_Timestamp (Contents, Sent_At);
      Protocol.Append_Byte (Contents, Boolean_Byte (Reply_Requested));
      return Copy_Data_Message ('k', Contents);
   end Make_Primary_Keepalive;

   function Make_Standby_Status_Update
     (Received_LSN    : LSN;
      Flushed_LSN     : LSN;
      Applied_LSN     : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_U64 (Contents, Received_LSN);
      Append_U64 (Contents, Flushed_LSN);
      Append_U64 (Contents, Applied_LSN);
      Append_Timestamp (Contents, Sent_At);
      Protocol.Append_Byte (Contents, Boolean_Byte (Reply_Requested));
      return Copy_Data_Message ('r', Contents);
   end Make_Standby_Status_Update;

   function Make_Hot_Standby_Feedback
     (Sent_At            : Replication_Timestamp;
      Xmin               : Transaction_Id;
      Xmin_Epoch         : UInt32;
      Catalog_Xmin       : Transaction_Id;
      Catalog_Xmin_Epoch : UInt32) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_Timestamp (Contents, Sent_At);
      Protocol.Append_U32 (Contents, Xmin);
      Protocol.Append_U32 (Contents, Xmin_Epoch);
      Protocol.Append_U32 (Contents, Catalog_Xmin);
      Protocol.Append_U32 (Contents, Catalog_Xmin_Epoch);
      return Copy_Data_Message ('h', Contents);
   end Make_Hot_Standby_Feedback;

   function Decode (Item : Protocol.Message) return Stream_Message is
      Contents : constant Byte_Array := Protocol.Payload (Item);
      Cursor   : Ada.Streams.Stream_Element_Offset := Contents'First + 1;
      Tag      : Character;
      Result   : Stream_Message;
   begin
      Require
        (Protocol.Code (Item) = 'd',
         "replication streaming requires a CopyData message");
      Require
        (Contents'Length > 0,
         "replication CopyData is missing its message tag");
      Tag := Character'Val (Contents (Contents'First));
      Result.Raw := Item;
      case Tag is
         when 'w' =>
            Require
              (Contents'Length >= 25,
               "XLogData is missing its replication header");
            Result.Message_Kind := XLog_Data;
            Result.First_LSN := Read_U64 (Contents, Cursor);
            Result.Second_LSN := Read_U64 (Contents, Cursor);
            Result.Timestamp := Read_Timestamp (Contents, Cursor);
            Result.Bytes := Flyology.Bytes.To_Unbounded_Bytes
              (Contents (Cursor .. Contents'Last));
         when 'k' =>
            Require
              (Contents'Length = 18,
               "PrimaryKeepalive has an invalid payload length");
            Result.Message_Kind := Primary_Keepalive;
            Result.Second_LSN := Read_U64 (Contents, Cursor);
            Result.Timestamp := Read_Timestamp (Contents, Cursor);
            Require
              (Contents (Cursor) in 0 | 1,
               "PrimaryKeepalive has an invalid reply flag");
            Result.Reply := Contents (Cursor) = 1;
         when 'r' =>
            Require
              (Contents'Length = 34,
               "StandbyStatusUpdate has an invalid payload length");
            Result.Message_Kind := Standby_Status_Update;
            Result.First_LSN := Read_U64 (Contents, Cursor);
            Result.Second_LSN := Read_U64 (Contents, Cursor);
            Result.Third_LSN := Read_U64 (Contents, Cursor);
            Result.Timestamp := Read_Timestamp (Contents, Cursor);
            Require
              (Contents (Cursor) in 0 | 1,
               "StandbyStatusUpdate has an invalid reply flag");
            Result.Reply := Contents (Cursor) = 1;
         when 'h' =>
            Require
              (Contents'Length = 25,
               "HotStandbyFeedback has an invalid payload length");
            Result.Message_Kind := Hot_Standby_Feedback;
            Result.Timestamp := Read_Timestamp (Contents, Cursor);
            Result.Xmin_Value := Protocol.Read_U32 (Contents, Cursor);
            Result.Xmin_Epoch_Value := Protocol.Read_U32 (Contents, Cursor);
            Result.Catalog_Xmin_Value := Protocol.Read_U32 (Contents, Cursor);
            Result.Catalog_Epoch := Protocol.Read_U32 (Contents, Cursor);
         when others =>
            raise Protocol.Protocol_Error with
              "unknown replication CopyData message tag";
      end case;
      return Result;
   end Decode;

   function Kind (Item : Stream_Message) return Stream_Message_Kind is
     (Item.Message_Kind);

   function Original_Message (Item : Stream_Message) return Protocol.Message
   is (Item.Raw);

   function WAL_Start (Item : Stream_Message) return LSN is
   begin
      Require (Item.Message_Kind = XLog_Data, "message is not XLogData");
      return Item.First_LSN;
   end WAL_Start;

   function WAL_End (Item : Stream_Message) return LSN is
   begin
      Require
        (Item.Message_Kind in XLog_Data | Primary_Keepalive,
         "replication message has no WAL end position");
      return Item.Second_LSN;
   end WAL_End;

   function Sent_At
     (Item : Stream_Message) return Replication_Timestamp is
     (Item.Timestamp);

   function Data (Item : Stream_Message) return Byte_Array is
   begin
      Require (Item.Message_Kind = XLog_Data, "message is not XLogData");
      return Flyology.Bytes.To_Array (Item.Bytes);
   end Data;

   function Reply_Requested (Item : Stream_Message) return Boolean is
   begin
      Require
        (Item.Message_Kind in Primary_Keepalive | Standby_Status_Update,
         "replication message has no reply-requested flag");
      return Item.Reply;
   end Reply_Requested;

   function Received_LSN (Item : Stream_Message) return LSN is
   begin
      Require
        (Item.Message_Kind = Standby_Status_Update,
         "message is not StandbyStatusUpdate");
      return Item.First_LSN;
   end Received_LSN;

   function Flushed_LSN (Item : Stream_Message) return LSN is
   begin
      Require
        (Item.Message_Kind = Standby_Status_Update,
         "message is not StandbyStatusUpdate");
      return Item.Second_LSN;
   end Flushed_LSN;

   function Applied_LSN (Item : Stream_Message) return LSN is
   begin
      Require
        (Item.Message_Kind = Standby_Status_Update,
         "message is not StandbyStatusUpdate");
      return Item.Third_LSN;
   end Applied_LSN;

   function Feedback_Xmin (Item : Stream_Message) return Transaction_Id is
   begin
      Require
        (Item.Message_Kind = Hot_Standby_Feedback,
         "message is not HotStandbyFeedback");
      return Item.Xmin_Value;
   end Feedback_Xmin;

   function Feedback_Xmin_Epoch (Item : Stream_Message) return UInt32 is
   begin
      Require
        (Item.Message_Kind = Hot_Standby_Feedback,
         "message is not HotStandbyFeedback");
      return Item.Xmin_Epoch_Value;
   end Feedback_Xmin_Epoch;

   function Feedback_Catalog_Xmin
     (Item : Stream_Message) return Transaction_Id is
   begin
      Require
        (Item.Message_Kind = Hot_Standby_Feedback,
         "message is not HotStandbyFeedback");
      return Item.Catalog_Xmin_Value;
   end Feedback_Catalog_Xmin;

   function Feedback_Catalog_Xmin_Epoch
     (Item : Stream_Message) return UInt32 is
   begin
      Require
        (Item.Message_Kind = Hot_Standby_Feedback,
         "message is not HotStandbyFeedback");
      return Item.Catalog_Epoch;
   end Feedback_Catalog_Xmin_Epoch;

end Flyology.Postgres.Replication;
