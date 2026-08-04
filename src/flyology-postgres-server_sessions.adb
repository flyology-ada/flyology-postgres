with Flyology.Bytes;
with Flyology.Postgres.Framing;

package body Flyology.Postgres.Server_Sessions is

   use type Protocol.Byte_Offset;
   use type Protocol.Field_Format;
   use type Protocol.Frontend_Kind;
   use type Protocol.Int16;
   use type Protocol.Int32;
   use type Protocol.UInt16;
   use type Protocol.UInt32;

   Payload_Limit : constant Natural := Protocol.Maximum_Message_Size - 4;

   procedure Require_Room
     (Contents   : Flyology.Bytes.Unbounded_Bytes;
      Additional : Natural;
      Context    : String) is
   begin
      if Additional > Payload_Limit - Flyology.Bytes.Length (Contents) then
         raise Protocol.Protocol_Error with
           Context & " exceeds the configured message limit";
      end if;
   end Require_Room;

   function Unsigned_16 (Value : Protocol.Int16) return Protocol.UInt16 is
     (if Value >= 0
      then Protocol.UInt16 (Value)
      else Protocol.UInt16 (Integer (Value) + 65_536));

   function Unsigned_32 (Value : Protocol.Int32) return Protocol.UInt32 is
     (if Value >= 0
      then Protocol.UInt32 (Value)
      else Protocol.UInt32 (Long_Long_Integer (Value) + 4_294_967_296));

   function Signed_16 (Value : Protocol.UInt16) return Protocol.Int16 is
     (if Value <= Protocol.UInt16 (Protocol.Int16'Last)
      then Protocol.Int16 (Value)
      else Protocol.Int16 (Integer (Value) - 65_536));

   procedure Send_Built
     (Item    : in out Session;
      Code    : Character;
      Contents : Flyology.Bytes.Unbounded_Bytes;
      Timeout : Duration) is
   begin
      Send
        (Item,
         Protocol.Make_Message
           (Code, Flyology.Bytes.To_Array (Contents)),
         Timeout);
   end Send_Built;

   function Read_Initial
     (Item : in out Session;
      Timeout : Duration) return Protocol.Initial_Request is
   begin
      return Framing.Read_Initial (Item.Channel.all, Timeout);
   end Read_Initial;

   function Read_Command
     (Item : in out Session;
      Timeout : Duration) return Protocol.Message is
   begin
      return Framing.Read_Message (Item.Channel.all, Timeout);
   end Read_Command;

   procedure Send
     (Item    : in out Session;
      Value   : Protocol.Message;
      Timeout : Duration) is
   begin
      Framing.Write_Message (Item.Channel.all, Value, Timeout);
   end Send;

   procedure Refuse_TLS
     (Item : in out Session; Timeout : Duration) is
   begin
      Framing.Write_Byte
        (Item.Channel.all, Protocol.Byte (Character'Pos ('N')), Timeout);
   end Refuse_TLS;

   procedure Refuse_GSS
     (Item : in out Session; Timeout : Duration) is
   begin
      Framing.Write_Byte
        (Item.Channel.all, Protocol.Byte (Character'Pos ('N')), Timeout);
   end Refuse_GSS;

   procedure Send_Authentication_Ok
     (Item : in out Session; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 0);
      Send_Built (Item, 'R', Contents, Timeout);
   end Send_Authentication_Ok;

   procedure Send_Authentication_Cleartext_Password
     (Item : in out Session; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 3);
      Send_Built (Item, 'R', Contents, Timeout);
   end Send_Authentication_Cleartext_Password;

   procedure Send_Authentication_SASL
     (Item : in out Session; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 10);
      Protocol.Append_C_String (Contents, "SCRAM-SHA-256");
      Protocol.Append_Byte (Contents, 0);
      Send_Built (Item, 'R', Contents, Timeout);
   end Send_Authentication_SASL;

   procedure Send_Authentication_SASL_Continue
     (Item : in out Session; Data : String; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 11);
      Flyology.Bytes.Append_Byte_String (Contents, Data);
      Send_Built (Item, 'R', Contents, Timeout);
   end Send_Authentication_SASL_Continue;

   procedure Send_Authentication_SASL_Final
     (Item : in out Session; Data : String; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 12);
      Flyology.Bytes.Append_Byte_String (Contents, Data);
      Send_Built (Item, 'R', Contents, Timeout);
   end Send_Authentication_SASL_Final;

   procedure Send_Negotiate_Protocol
     (Item         : in out Session;
      Latest_Minor : Protocol.UInt32;
      Timeout      : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, Latest_Minor);
      Protocol.Append_U32 (Contents, 0);
      Send_Built (Item, 'v', Contents, Timeout);
   end Send_Negotiate_Protocol;

   procedure Send_Parameter_Status
     (Item    : in out Session;
      Name    : String;
      Value   : String;
      Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Name);
      Protocol.Append_C_String (Contents, Value);
      Send_Built (Item, 'S', Contents, Timeout);
   end Send_Parameter_Status;

   procedure Send_Backend_Key_Data
     (Item       : in out Session;
      Process_Id : Protocol.UInt32;
      Secret_Key : Protocol.Byte_Array;
      Timeout    : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Secret_Key'Length not in 4 .. 256 then
         raise Protocol.Protocol_Error with
           "a backend cancellation key must contain 4 through 256 bytes";
      end if;
      Protocol.Append_U32 (Contents, Process_Id);
      Protocol.Append_Bytes (Contents, Secret_Key);
      Send_Built (Item, 'K', Contents, Timeout);
   end Send_Backend_Key_Data;

   procedure Send_Ready
     (Item               : in out Session;
      Transaction_Status : Character := 'I';
      Timeout            : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Transaction_Status not in 'I' | 'T' | 'E' then
         raise Protocol.Protocol_Error with
           "invalid ReadyForQuery transaction status";
      end if;
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos (Transaction_Status)));
      Send_Built (Item, 'Z', Contents, Timeout);
   end Send_Ready;

   procedure Append_Error_Fields
     (Contents  : in out Flyology.Bytes.Unbounded_Bytes;
      Message   : String;
      SQL_State : String;
      Severity  : String) is
   begin
      if SQL_State'Length /= 5 then
         raise Protocol.Protocol_Error with
           "a Postgres SQLSTATE must contain five characters";
      end if;
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('S')));
      Protocol.Append_C_String (Contents, Severity);
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('V')));
      Protocol.Append_C_String (Contents, Severity);
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('C')));
      Protocol.Append_C_String (Contents, SQL_State);
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('M')));
      Protocol.Append_C_String (Contents, Message);
      Protocol.Append_Byte (Contents, 0);
   end Append_Error_Fields;

   procedure Send_Error
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "XX000";
      Severity  : String := "ERROR";
      Timeout   : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_Error_Fields (Contents, Message, SQL_State, Severity);
      Send_Built (Item, 'E', Contents, Timeout);
   end Send_Error;

   procedure Send_Notice
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "00000";
      Severity  : String := "NOTICE";
      Timeout   : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_Error_Fields (Contents, Message, SQL_State, Severity);
      Send_Built (Item, 'N', Contents, Timeout);
   end Send_Notice;

   procedure Send_Command_Complete
     (Item : in out Session; Tag : String; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Tag);
      Send_Built (Item, 'C', Contents, Timeout);
   end Send_Command_Complete;

   procedure Send_Empty_Query_Response
     (Item : in out Session; Timeout : Duration) is
   begin
      Send (Item, Protocol.Make_Empty_Message ('I'), Timeout);
   end Send_Empty_Query_Response;

   procedure Send_Parse_Complete
     (Item : in out Session; Timeout : Duration) is
   begin
      Send (Item, Protocol.Make_Empty_Message ('1'), Timeout);
   end Send_Parse_Complete;

   procedure Send_Bind_Complete
     (Item : in out Session; Timeout : Duration) is
   begin
      Send (Item, Protocol.Make_Empty_Message ('2'), Timeout);
   end Send_Bind_Complete;

   procedure Send_Close_Complete
     (Item : in out Session; Timeout : Duration) is
   begin
      Send (Item, Protocol.Make_Empty_Message ('3'), Timeout);
   end Send_Close_Complete;

   procedure Send_No_Data
     (Item : in out Session; Timeout : Duration) is
   begin
      Send (Item, Protocol.Make_Empty_Message ('n'), Timeout);
   end Send_No_Data;

   procedure Send_Row_Description
     (Item    : in out Session;
      Columns : Protocol.Field_Description_Array;
      Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Columns'Length > Natural (Protocol.UInt16'Last) then
         raise Protocol.Protocol_Error with
           "RowDescription has too many fields";
      end if;
      Require_Room (Contents, 2, "RowDescription");
      Protocol.Append_U16 (Contents, Protocol.UInt16 (Columns'Length));
      for Column of Columns loop
         declare
            Name : constant String := Protocol.Field_Name (Column);
         begin
            if Name'Length > Payload_Limit - 19 then
               raise Protocol.Protocol_Error with
                 "RowDescription field name exceeds the configured limit";
            end if;
            Require_Room
              (Contents, Name'Length + 19, "RowDescription");
            Protocol.Append_C_String (Contents, Name);
            Protocol.Append_U32 (Contents, Protocol.Table_Oid (Column));
            Protocol.Append_U16
              (Contents,
               Unsigned_16 (Protocol.Column_Attribute_Number (Column)));
            Protocol.Append_U32 (Contents, Protocol.Type_Oid (Column));
            Protocol.Append_U16
              (Contents, Unsigned_16 (Protocol.Type_Size (Column)));
            Protocol.Append_U32
              (Contents, Unsigned_32 (Protocol.Type_Modifier (Column)));
            Protocol.Append_U16
              (Contents,
               (if Protocol.Format (Column) = Protocol.Text_Format
                then 0
                else 1));
         end;
      end loop;
      Send_Built (Item, 'T', Contents, Timeout);
   end Send_Row_Description;

   procedure Send_Row_Description
     (Item      : in out Session;
      Name      : String;
      Type_Oid  : Protocol.UInt32 := 25;
      Type_Size : Protocol.UInt16 := 16#FFFF#;
      Timeout   : Duration) is
   begin
      Send_Row_Description
        (Item,
         Columns =>
           (1 => Protocol.Make_Field_Description
              (Name      => Name,
               Type_Oid  => Type_Oid,
               Type_Size => Signed_16 (Type_Size))),
         Timeout => Timeout);
   end Send_Row_Description;

   procedure Send_Data_Row
     (Item    : in out Session;
      Values  : Protocol.Column_Value_Array;
      Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Values'Length > Natural (Protocol.UInt16'Last) then
         raise Protocol.Protocol_Error with "DataRow has too many columns";
      end if;
      Require_Room (Contents, 2, "DataRow");
      Protocol.Append_U16 (Contents, Protocol.UInt16 (Values'Length));
      for Value of Values loop
         if Protocol.Is_Null (Value) then
            Require_Room (Contents, 4, "DataRow");
            Protocol.Append_U32 (Contents, Protocol.UInt32'Last);
         else
            declare
               Bytes : constant Protocol.Byte_Array :=
                 Protocol.Column_Bytes (Value);
            begin
               if Bytes'Length > Payload_Limit - 4 then
                  raise Protocol.Protocol_Error with
                    "DataRow column exceeds the configured limit";
               end if;
               Require_Room (Contents, Bytes'Length + 4, "DataRow");
               Protocol.Append_U32
                 (Contents, Protocol.UInt32 (Bytes'Length));
               Protocol.Append_Bytes (Contents, Bytes);
            end;
         end if;
      end loop;
      Send_Built (Item, 'D', Contents, Timeout);
   end Send_Data_Row;

   procedure Send_Data_Row
     (Item : in out Session; Value : String; Timeout : Duration) is
   begin
      Send_Data_Row
        (Item,
         Values => (1 => Protocol.Text_Column (Value)),
         Timeout => Timeout);
   end Send_Data_Row;

   procedure Send_Null_Data_Row
     (Item : in out Session; Timeout : Duration) is
   begin
      Send_Data_Row
        (Item, Values => (1 => Protocol.Null_Column), Timeout => Timeout);
   end Send_Null_Data_Row;

   function Query_Text (Command : Protocol.Message) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Command);
      Cursor   : Protocol.Byte_Offset := Contents'First;
   begin
      if Protocol.Kind (Command) /= Protocol.Query then
         raise Protocol.Protocol_Error with "message is not a Query command";
      end if;
      declare
         Result : constant String := Protocol.Read_C_String (Contents, Cursor);
      begin
         if Cursor /= Protocol.Byte_Offset'Succ (Contents'Last) then
            raise Protocol.Protocol_Error with
              "Query command has trailing payload data";
         end if;
         return Result;
      end;
   end Query_Text;

   function Password_Text (Command : Protocol.Message) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Command);
      Cursor   : Protocol.Byte_Offset := Contents'First;
   begin
      if Protocol.Kind (Command) /= Protocol.Password_Or_SASL_Response then
         raise Protocol.Protocol_Error with
           "message is not a password response";
      end if;
      declare
         Result : constant String := Protocol.Read_C_String (Contents, Cursor);
      begin
         if Cursor /= Protocol.Byte_Offset'Succ (Contents'Last) then
            raise Protocol.Protocol_Error with
              "password response has trailing payload data";
         end if;
         return Result;
      end;
   end Password_Text;

   function Cancellation_Requested (Item : Session) return Boolean is
     ((Item.Operation_Cancellation /= null
       and then Item.Operation_Cancellation.Requested)
      or else (Item.Shutdown_Cancellation /= null
               and then Item.Shutdown_Cancellation.Requested));

   function SASL_Initial_Response
     (Command : Protocol.Message) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Command);
      Cursor   : Protocol.Byte_Offset := Contents'First;
   begin
      if Protocol.Kind (Command) /= Protocol.Password_Or_SASL_Response then
         raise Protocol.Protocol_Error with
           "message is not a SASL initial response";
      end if;
      declare
         Selected : constant String :=
           Protocol.Read_C_String (Contents, Cursor);
         Length : constant Protocol.UInt32 :=
           Protocol.Read_U32 (Contents, Cursor);
      begin
         if Selected /= "SCRAM-SHA-256" then
            raise Protocol.Protocol_Error with
              "unsupported SASL mechanism selected";
         elsif Length = Protocol.UInt32'Last
           or else Length > Protocol.UInt32 (Protocol.Maximum_Message_Size)
           or else Contents'Last - Cursor + 1 /= Protocol.Byte_Offset (Length)
         then
            raise Protocol.Protocol_Error with
              "invalid SASL initial response length";
         end if;
         declare
            Result : String (1 .. Natural (Length));
            Position : Protocol.Byte_Offset := Cursor;
         begin
            for Index in Result'Range loop
               Result (Index) := Character'Val (Contents (Position));
               Position := Position + 1;
            end loop;
            return Result;
         end;
      end;
   end SASL_Initial_Response;

   function SASL_Response (Command : Protocol.Message) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Command);
      Result   : String (1 .. Contents'Length);
      Position : Protocol.Byte_Offset := Contents'First;
   begin
      if Protocol.Kind (Command) /= Protocol.Password_Or_SASL_Response then
         raise Protocol.Protocol_Error with "message is not a SASL response";
      end if;
      for Index in Result'Range loop
         Result (Index) := Character'Val (Contents (Position));
         Position := Position + 1;
      end loop;
      return Result;
   end SASL_Response;

end Flyology.Postgres.Server_Sessions;
