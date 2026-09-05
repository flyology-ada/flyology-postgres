with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Bytes;
with Flyology.IO;
with Flyology.IO.Timers;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Base_Backups;
with Flyology.Postgres.Replication.Base_Backups.Server_Sessions;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with Flyology.Postgres.Server_Sessions;
with Flyology.Postgres.Transports;
with Flyology.Postgres.Wire;
with Replication_Tests;

procedure Tests is

   package Protocol renames Flyology.Postgres.Protocol;
   package SCRAM_Core renames Flyology.Postgres.SCRAM_Core;
   package Client renames Flyology.Postgres.Client;
   package Base_Backups renames
     Flyology.Postgres.Replication.Base_Backups;
   package Backup_Sessions renames
     Flyology.Postgres.Replication.Base_Backups.Server_Sessions;
   package Server_Sessions renames Flyology.Postgres.Server_Sessions;
   package Transports renames Flyology.Postgres.Transports;
   package Operations renames Flyology.Operations;
   package Operation_Drivers renames Flyology.Operations.Drivers;
   package Timers renames Flyology.IO.Timers;

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Field_Format;
   use type Protocol.Frontend_Kind;
   use type Protocol.Initial_Kind;
   use type Protocol.Frontend_Copy_Kind;
   use type Protocol.Int16;
   use type Protocol.Int32;
   use type Protocol.Transaction_Status;
   use type Protocol.UInt16;
   use type Protocol.UInt32;
   use type Client.Operation_State;
   use type Operations.Terminal_Outcome;
   use type Base_Backups.Event_Kind;
   use type Interfaces.Unsigned_64;
   use type Ada.Streams.Stream_Element_Array;

   type Memory_Transport is
     limited new Transports.TLS_Upgradable_Transport
       and Transports.Operation_Transport with record
         Input        : Flyology.Bytes.Unbounded_Bytes;
         Output       : Flyology.Bytes.Unbounded_Bytes;
         Next         : Natural := 1;
         Engaged      : Boolean := False;
         Blocked      : Boolean := False;
         Fail_Receive : Boolean := False;
         Chunk        : Positive := 1;
   end record;

   overriding procedure Receive_Exactly
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Upgrade_TLS
     (Item        : in out Memory_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration);

   overriding procedure Start_Operation
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Result    : out Transports.Acquisition_Result;
      Timeout   : Duration);

   overriding procedure Poll_Acquisition
     (Item   : in out Memory_Transport;
      Result : out Transports.Acquisition_Result);

   overriding procedure Arm_Acquisition
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class);

   overriding procedure Receive_Step
     (Item   : in out Memory_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result);

   overriding procedure Send_Step
     (Item   : in out Memory_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result);

   overriding procedure Arm_Transport
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Required  : Transports.Step_Result);

   overriding procedure Release_Operation (Item : in out Memory_Transport);
   overriding procedure Cancel_Operation (Item : in out Memory_Transport);

   overriding procedure Receive_Exactly
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null) is
      pragma Unreferenced (Timeout);
      pragma Unreferenced (On_Wait);
      --  Buffered input is always available, so this transport never waits.
      Available : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Input);
   begin
      if Item.Next > Available'Length + 1
        or else Data'Length > Available'Length - Item.Next + 1
      then
         raise Program_Error with "memory transport input is exhausted";
      end if;
      for Index in Data'Range loop
         Data (Index) := Available (Protocol.Byte_Offset (Item.Next));
         Item.Next := Item.Next + 1;
      end loop;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
      pragma Unreferenced (Timeout);
   begin
      Flyology.Bytes.Append (Item.Output, Data);
   end Send_All;

   overriding procedure Upgrade_TLS
     (Item        : in out Memory_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
      pragma Unreferenced (Item, Backend, Server_Name, Timeout);
   begin
      raise Program_Error with "unexpected memory transport TLS upgrade";
   end Upgrade_TLS;

   overriding procedure Start_Operation
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Result    : out Transports.Acquisition_Result;
      Timeout   : Duration) is
   begin
      if Item.Engaged then
         raise Program_Error with "memory transport is already engaged";
      end if;
      Item.Engaged := True;
      if Timeout >= 0.0 then
         Operation_Drivers.Arm_Deadline (Operation, Timeout);
      end if;
      Result := Transports.Acquired;
   end Start_Operation;

   overriding procedure Poll_Acquisition
     (Item   : in out Memory_Transport;
      Result : out Transports.Acquisition_Result) is
      pragma Unreferenced (Item);
   begin
      Result := Transports.Acquired;
   end Poll_Acquisition;

   overriding procedure Arm_Acquisition
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class) is
      pragma Unreferenced (Item);
   begin
      Operation_Drivers.Reschedule (Operation);
   end Arm_Acquisition;

   overriding procedure Receive_Step
     (Item   : in out Memory_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result) is
      Available : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Input);
      Count : Natural;
   begin
      Last := Data'First - 1;
      if Item.Fail_Receive then
         raise Program_Error with "synthetic provider receive failure";
      elsif Item.Blocked then
         Result := Transports.Need_Read;
         return;
      elsif Item.Next > Available'Length then
         Result := Transports.Peer_Closed;
         return;
      end if;
      Count := Natural'Min
        (Item.Chunk,
         Natural'Min
           (Data'Length, Available'Length - Item.Next + 1));
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Available (Protocol.Byte_Offset (Item.Next + Offset));
      end loop;
      Item.Next := Item.Next + Count;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
      Result := Transports.Made_Progress;
   end Receive_Step;

   overriding procedure Send_Step
     (Item   : in out Memory_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result) is
      Count : constant Natural := Natural'Min (Item.Chunk, Data'Length);
      Final : constant Ada.Streams.Stream_Element_Offset :=
        Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
   begin
      Flyology.Bytes.Append (Item.Output, Data (Data'First .. Final));
      Last := Final;
      Result := Transports.Made_Progress;
   end Send_Step;

   overriding procedure Arm_Transport
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Required  : Transports.Step_Result) is
      pragma Unreferenced (Item, Operation, Required);
   begin
      --  A blocked synthetic transfer retains Start's deadline source.
      null;
   end Arm_Transport;

   overriding procedure Release_Operation (Item : in out Memory_Transport) is
   begin
      Item.Engaged := False;
   end Release_Operation;

   overriding procedure Cancel_Operation (Item : in out Memory_Transport) is
   begin
      Item.Engaged := False;
   end Cancel_Operation;

   procedure Queue
     (Item : in out Memory_Transport; Message : Protocol.Message) is
   begin
      Flyology.Bytes.Append (Item.Input, Protocol.Encode (Message));
   end Queue;

   procedure Test_Startup is
      Packet : constant Protocol.Byte_Array :=
        Protocol.Encode_Startup
          (User             => "alice",
           Database         => "example",
           Application_Name => "tests");
      Cursor : Protocol.Byte_Offset := Packet'First;
      Length : constant Protocol.UInt32 :=
        Protocol.Read_U32 (Packet, Cursor);
      Initial : constant Protocol.Initial_Request :=
        Protocol.Decode_Initial (Packet (Cursor .. Packet'Last));
      Startup : constant Protocol.Startup_Information :=
        Protocol.Startup_Data (Initial);
   begin
      Assert
        (Length = Protocol.UInt32 (Packet'Length),
         "startup length is encoded in network order");
      Assert
        (Protocol.Kind (Initial) = Protocol.Startup,
         "startup packet is classified");
      Assert (To_String (Startup.User) = "alice", "startup user round-trips");
      Assert
        (To_String (Startup.Database) = "example",
         "startup database round-trips");
      Assert
        (To_String (Startup.Application_Name) = "tests",
         "startup application name round-trips");
   end Test_Startup;

   procedure Test_SSL_Request is
      Packet  : constant Protocol.Byte_Array := Protocol.Encode_SSL_Request;
      Cursor  : Protocol.Byte_Offset := Packet'First;
      Length  : constant Protocol.UInt32 := Protocol.Read_U32 (Packet, Cursor);
      Initial : constant Protocol.Initial_Request :=
        Protocol.Decode_Initial (Packet (Cursor .. Packet'Last));
   begin
      Assert (Length = 8, "SSLRequest has the required eight-byte length");
      Assert
        (Protocol.Kind (Initial) = Protocol.SSL_Request,
         "SSLRequest round-trips through initial packet decoding");
   end Test_SSL_Request;

   procedure Test_TLS_Refusal_Is_Terminal is
      package OpenSSL renames Flyology.IO.TLS.OpenSSL;
      Backend : OpenSSL.OpenSSL_Provider;
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Refused : Boolean := False;
      Retry_Rejected : Boolean := False;
   begin
      Flyology.Bytes.Append
        (Channel.Input,
         (1 => Protocol.Byte (Character'Pos ('N'))));
      begin
         Client.Startup_TLS
           (Session,
            Backend,
            Server_Name => "db.example.com",
            User        => "tester",
            Timeout     => 1.0);
      exception
         when Client.TLS_Not_Available =>
            Refused := True;
      end;
      Assert (Refused, "TLS refusal raises TLS_Not_Available");
      Assert
        (Client.State (Session) = Client.Closed,
         "TLS refusal permanently closes the session state");
      Assert
        (Flyology.Bytes.To_Array (Channel.Output) =
           Protocol.Encode_SSL_Request,
         "TLS refusal sends no plaintext startup packet");

      begin
         Client.Startup (Session, User => "tester", Timeout => 1.0);
      exception
         when Program_Error =>
            Retry_Rejected := True;
      end;
      Assert
        (Retry_Rejected,
         "TLS-refused sessions cannot retry startup in plaintext");
   end Test_TLS_Refusal_Is_Terminal;

   procedure Test_Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, "select 1");
      declare
         Value : constant Protocol.Message :=
           Protocol.Make_Message
             ('Q', Flyology.Bytes.To_Array (Contents));
         Packet : constant Protocol.Byte_Array := Protocol.Encode (Value);
         Cursor : Protocol.Byte_Offset := Packet'First + 1;
      begin
         Assert
           (Protocol.Kind (Value) = Protocol.Query,
            "Query is classified");
         Assert
           (Packet (Packet'First) = Protocol.Byte (Character'Pos ('Q')),
            "typed message begins with its tag");
         Assert
           (Protocol.Read_U32 (Packet, Cursor) =
              Protocol.UInt32 (Protocol.Payload_Length (Value) + 4),
            "typed message length includes its own field");
      end;
   end Test_Message;

   procedure Test_All_Frontend_Commands is
      type Case_Item is record
         Code : Character;
         Kind : Protocol.Frontend_Kind;
      end record;
      type Cases is array (Positive range <>) of Case_Item;
      Commands : constant Cases :=
        (('B', Protocol.Bind),
         ('C', Protocol.Close),
         ('d', Protocol.Copy_Data),
         ('c', Protocol.Copy_Done),
         ('f', Protocol.Copy_Fail),
         ('D', Protocol.Describe),
         ('E', Protocol.Execute),
         ('H', Protocol.Flush),
         ('F', Protocol.Function_Call),
         ('p', Protocol.Password_Or_SASL_Response),
         ('P', Protocol.Parse),
         ('Q', Protocol.Query),
         ('S', Protocol.Sync),
         ('X', Protocol.Terminate_Command),
         ('?', Protocol.Unknown));
   begin
      for Command of Commands loop
         Assert
           (Protocol.Kind (Protocol.Make_Empty_Message (Command.Code)) =
              Command.Kind,
            "frontend command " & Command.Code & " is classified");
      end loop;
   end Test_All_Frontend_Commands;

   procedure Test_Malformed_String is
      Contents : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('x')));
      Cursor   : Protocol.Byte_Offset := Contents'First;
      Rejected : Boolean := False;
   begin
      begin
         declare
            Ignored : constant String :=
              Protocol.Read_C_String (Contents, Cursor);
         begin
            Assert (Ignored'Length = 0, "unreachable malformed string result");
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "unterminated strings are rejected");
   end Test_Malformed_String;

   procedure Test_Proved_Wire_Core is
      package Wire renames Flyology.Postgres.Wire;
      use type Wire.Byte_View;
      use type Wire.Int64;
      Data     : Protocol.Byte_Array (-3 .. 0) := (others => 0);
      Data64   : Protocol.Byte_Array (-7 .. 0) := (others => 0);
      Found    : Boolean;
      Position : Wire.Wire_Length;
      Cursor   : Wire.Wire_Length;
      Value16  : Wire.UInt16;
      Value64  : Wire.UInt64;
      Success  : Boolean;
      View     : Wire.Byte_View;
   begin
      Wire.Encode_U32 (Data, Position => 0, Value => 16#1234_ABCD#);
      Assert
        (Wire.Decode_U32 (Data, Position => 0) = 16#1234_ABCD#,
         "proved endian primitives handle arbitrary array bounds");

      Wire.Encode_U64
        (Data64, Position => 0, Value => 16#FEDC_BA98_7654_3210#);
      Assert
        (Wire.Decode_U64 (Data64, Position => 0) =
           16#FEDC_BA98_7654_3210#,
         "proved 64-bit endian primitives round trip replication fields");
      Cursor := 0;
      Wire.Try_Read_U64 (Data64, Cursor, Value64, Success);
      Assert
        (Success
         and then Cursor = 8
         and then Value64 = 16#FEDC_BA98_7654_3210#,
         "proved 64-bit total reads advance by exactly eight bytes");

      Assert
        (Wire.To_Int32_Bits (16#FFFF_FFFF#) = -1
         and then Wire.To_UInt32_Bits (Wire.Int32'First) = 16#8000_0000#
         and then Wire.To_Int64_Bits (16#FFFF_FFFF_FFFF_FFFF#) = -1
         and then Wire.To_UInt64_Bits (Wire.Int64'First) =
           16#8000_0000_0000_0000#,
         "proved signed bit-pattern conversions cover negative boundaries");

      Data :=
        (-3 => Protocol.Byte (Character'Pos ('a')),
         -2 => Protocol.Byte (Character'Pos ('b')),
         -1 => 0,
          0 => Protocol.Byte (Character'Pos ('x')));
      Wire.Find_Nul (Data, Start => 0, Found => Found, Position => Position);
      Assert
        (Found and then Position = 2,
         "proved NUL search finds its offset");

      Cursor := 3;
      Wire.Try_Read_U16 (Data, Cursor, Value16, Success);
      Assert
        (not Success and then Cursor = 3 and then Value16 = 0,
         "failed total reads leave their cursor unchanged");
      Cursor := 0;
      Wire.Try_Read_C_String (Data, Cursor, View, Success);
      Assert
        (Success
         and then Cursor = 3
         and then View = (First => 0, Length => 2),
         "total C-string reads return a validated view");
      Assert
        (Wire.Valid_Initial_Length (8)
         and then not Wire.Valid_Initial_Length (7)
         and then Wire.Content_Length (8) = 4,
         "proved frame-length predicates enforce protocol minima");
      Assert
        (Wire.Count_Fits (Remaining => 8, Count => 2,
                          Minimum_Item_Length => 4)
         and then not Wire.Count_Fits
           (Remaining => 7, Count => 2, Minimum_Item_Length => 4),
         "proved count checks reject impossible bounded payloads");
      Assert
        (Wire.Format_Count_Is_Valid (Format_Count => 0, Value_Count => 3)
         and then Wire.Format_Count_Is_Valid
           (Format_Count => 1, Value_Count => 3)
         and then Wire.Format_Count_Is_Valid
           (Format_Count => 3, Value_Count => 3)
         and then not Wire.Format_Count_Is_Valid
           (Format_Count => 2, Value_Count => 3),
         "proved format-count checks model Bind's legal encodings");
      Cursor := 1;
      Wire.Try_Read_Bytes
        (Data, Cursor, Count => 2, View => View, Success => Success);
      Assert
        (Success
         and then Cursor = 3
         and then View = (First => 1, Length => 2),
         "proved bounded byte reads return validated slices");
   end Test_Proved_Wire_Core;

   procedure Test_Variable_Cancellation_Key is
      Secret   : constant Protocol.Byte_Array (1 .. 8) :=
        (1 => 16#10#,
         2 => 16#20#,
         3 => 16#30#,
         4 => 16#40#,
         5 => 16#50#,
         6 => 16#60#,
         7 => 16#70#,
         8 => 16#80#);
      Packet : constant Protocol.Byte_Array :=
        Protocol.Encode_Cancel_Request (42, Secret);
      Cursor : Protocol.Byte_Offset := Packet'First;
   begin
      Assert
        (Protocol.Read_U32 (Packet, Cursor) =
           Protocol.UInt32 (Packet'Length),
         "CancelRequest length covers the complete initial packet");
      declare
         Initial : constant Protocol.Initial_Request :=
           Protocol.Decode_Initial (Packet (Cursor .. Packet'Last));
         Decoded_Secret : constant Protocol.Byte_Array :=
           Protocol.Secret_Key (Initial);
      begin
         Assert
           (Protocol.Kind (Initial) = Protocol.Cancel_Request,
            "protocol 3.2 variable-key cancellation is classified");
         Assert
           (Protocol.Process_Id (Initial) = 42,
            "cancellation process ID is decoded");
         Assert
           (Decoded_Secret = Secret,
            "variable cancellation key round-trips");
      end;
   end Test_Variable_Cancellation_Key;

   procedure Test_Invalid_Cancellation_Key_Length is
      Too_Short : constant Protocol.Byte_Array (1 .. 3) := (others => 0);
      Rejected  : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Protocol.Byte_Array :=
              Protocol.Encode_Cancel_Request (1, Too_Short);
         begin
            Assert (Ignored'Length = 0, "unreachable cancellation packet");
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "cancellation keys shorter than four bytes fail");
   end Test_Invalid_Cancellation_Key_Length;

   procedure Test_Malformed_Startup is
      Packet : constant Protocol.Byte_Array :=
        Protocol.Encode_Startup
          (User             => "alice",
           Application_Name => "",
           Protocol_Minor   => 2);
      Rejected : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Protocol.Initial_Request :=
              Protocol.Decode_Initial
                (Packet (Packet'First + 4 .. Packet'Last - 1));
         begin
            Assert
              (Protocol.Kind (Ignored) = Protocol.Unknown_Initial,
               "unreachable malformed startup result");
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected,
         "startup packets without their final terminator are rejected");
   end Test_Malformed_Startup;

   procedure Test_Typed_Row_Messages is
      Description_Contents : Flyology.Bytes.Unbounded_Bytes;
      Row_Contents         : Flyology.Bytes.Unbounded_Bytes;
      Binary_Value         : constant Protocol.Byte_Array (1 .. 3) :=
        (1 => 0,
         2 => Protocol.Byte (Character'Pos ('A')),
         3 => 16#FF#);
   begin
      Protocol.Append_U16 (Description_Contents, 2);
      Protocol.Append_C_String (Description_Contents, "identifier");
      Protocol.Append_U32 (Description_Contents, 42);
      Protocol.Append_U16 (Description_Contents, 16#FFFF#);
      Protocol.Append_U32 (Description_Contents, 23);
      Protocol.Append_U16 (Description_Contents, 4);
      Protocol.Append_U32 (Description_Contents, Protocol.UInt32'Last);
      Protocol.Append_U16 (Description_Contents, 0);
      Protocol.Append_C_String (Description_Contents, "payload");
      Protocol.Append_U32 (Description_Contents, 0);
      Protocol.Append_U16 (Description_Contents, 0);
      Protocol.Append_U32 (Description_Contents, 17);
      Protocol.Append_U16 (Description_Contents, 16#FFFF#);
      Protocol.Append_U32 (Description_Contents, Protocol.UInt32'Last);
      Protocol.Append_U16 (Description_Contents, 1);

      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('T', Flyology.Bytes.To_Array (Description_Contents)));
         Description : constant Protocol.Row_Description :=
           Protocol.Description (Response);
         First_Field : constant Protocol.Field_Description :=
           Protocol.Field_At (Description, 1);
         Second_Field : constant Protocol.Field_Description :=
           Protocol.Field_At (Description, 2);
      begin
         Assert
           (Protocol.Response_Kind (Response) =
              Protocol.Row_Description_Response,
            "RowDescription is decoded to a typed response");
         Assert
           (Protocol.Code (Protocol.Original_Message (Response)) = 'T',
            "typed responses retain their original raw message");
         Assert
           (Protocol.Field_Count (Description) = 2,
            "all RowDescription fields are retained");
         Assert
           (Protocol.Field_Name (First_Field) = "identifier"
            and then Protocol.Table_Oid (First_Field) = 42
            and then Protocol.Column_Attribute_Number (First_Field) = -1
            and then Protocol.Type_Oid (First_Field) = 23
            and then Protocol.Type_Size (First_Field) = 4
            and then Protocol.Type_Modifier (First_Field) = -1
            and then Protocol.Format (First_Field) = Protocol.Text_Format,
            "every RowDescription metadata field is decoded");
         Assert
           (Protocol.Field_Name (Second_Field) = "payload"
            and then Protocol.Type_Size (Second_Field) = -1
            and then Protocol.Format (Second_Field) = Protocol.Binary_Format,
            "signed metadata and binary format codes are decoded");
      end;

      Protocol.Append_U16 (Row_Contents, 4);
      Protocol.Append_U32 (Row_Contents, 3);
      Protocol.Append_Bytes (Row_Contents, Binary_Value);
      Protocol.Append_U32 (Row_Contents, Protocol.UInt32'Last);
      Protocol.Append_U32 (Row_Contents, 0);
      Protocol.Append_U32 (Row_Contents, 1);
      Protocol.Append_Byte
        (Row_Contents, Protocol.Byte (Character'Pos ('x')));

      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('D', Flyology.Bytes.To_Array (Row_Contents)));
         Row : constant Protocol.Data_Row := Protocol.Row_Data (Response);
      begin
         Assert
           (Protocol.Column_Count (Row) = 4,
            "all DataRow columns are retained");
         Assert
           (Protocol.Column_Bytes (Protocol.Column_At (Row, 1)) = Binary_Value,
            "DataRow values preserve arbitrary bytes");
         Assert
           (Protocol.Is_Null (Protocol.Column_At (Row, 2)),
            "DataRow NULL is distinct");
         Assert
           (not Protocol.Is_Null (Protocol.Column_At (Row, 3))
            and then
              Protocol.Column_Bytes (Protocol.Column_At (Row, 3))'Length = 0,
            "DataRow empty values are distinct from NULL");
         Assert
           (Protocol.Column_Text (Protocol.Column_At (Row, 4)) = "x",
            "text convenience access is available");
      end;
   end Test_Typed_Row_Messages;

   procedure Test_Typed_Query_Events is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, "SELECT 2");
      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('C', Flyology.Bytes.To_Array (Contents)));
      begin
         Assert
           (Protocol.Completion_Tag (Response) = "SELECT 2",
            "CommandComplete tag is decoded");
      end;

      Contents := Flyology.Bytes.Empty;
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('S')));
      Protocol.Append_C_String (Contents, "ERROR");
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('V')));
      Protocol.Append_C_String (Contents, "ERROR");
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('C')));
      Protocol.Append_C_String (Contents, "22012");
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('M')));
      Protocol.Append_C_String (Contents, "division by zero");
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('Y')));
      Protocol.Append_C_String (Contents, "future field");
      Protocol.Append_Byte (Contents, 0);
      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('E', Flyology.Bytes.To_Array (Contents)));
         Diagnostic : constant Protocol.Diagnostic :=
           Protocol.Diagnostic_Data (Response);
      begin
         Assert
           (Protocol.Severity (Diagnostic) = "ERROR"
            and then Protocol.Nonlocalized_Severity (Diagnostic) = "ERROR"
            and then Protocol.Diagnostic_SQL_State (Diagnostic) = "22012"
            and then Protocol.Diagnostic_Message (Diagnostic) =
              "division by zero"
            and then Protocol.Field_Text (Diagnostic, 'Y') = "future field",
            "ErrorResponse fields, including future fields, are decoded");
      end;

      Contents := Flyology.Bytes.Empty;
      Protocol.Append_C_String (Contents, "application_name");
      Protocol.Append_C_String (Contents, "typed-tests");
      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('S', Flyology.Bytes.To_Array (Contents)));
         Status : constant Protocol.Parameter_Status :=
           Protocol.Parameter_Data (Response);
      begin
         Assert
           (Protocol.Parameter_Name (Status) = "application_name"
            and then Protocol.Parameter_Value (Status) = "typed-tests",
            "ParameterStatus name and value are decoded");
      end;

      for Item in Protocol.Transaction_Status loop
         declare
            Code : constant Character :=
              (case Item is
                 when Protocol.Idle => 'I',
                 when Protocol.In_Transaction => 'T',
                 when Protocol.Failed_Transaction => 'E');
            Payload : constant Protocol.Byte_Array (1 .. 1) :=
              (1 => Protocol.Byte (Character'Pos (Code)));
            Response : constant Protocol.Backend_Message :=
              Protocol.Decode_Backend (Protocol.Make_Message ('Z', Payload));
         begin
            Assert
              (Protocol.Transaction_State (Response) = Item,
               "ReadyForQuery transaction status is decoded");
         end;
      end loop;

      Assert
        (Protocol.Response_Kind
           (Protocol.Decode_Backend (Protocol.Make_Empty_Message ('I'))) =
           Protocol.Empty_Query_Response,
         "EmptyQueryResponse is decoded");
      Assert
        (Protocol.Response_Kind
           (Protocol.Decode_Backend (Protocol.Make_Empty_Message ('?'))) =
           Protocol.Unknown_Response,
         "unknown backend messages retain a raw response");
   end Test_Typed_Query_Events;

   procedure Test_Extended_Frontend_Messages is
      Binary : constant Protocol.Byte_Array (1 .. 2) :=
        (1 => 0, 2 => 16#FF#);
   begin
      declare
         Value   : constant Protocol.Message :=
           Protocol.Make_Parse_Message
             ("statement", "select $1::int4, $2::bytea", (23, 17));
         Contents : constant Protocol.Byte_Array := Protocol.Payload (Value);
         Cursor   : Protocol.Byte_Offset := Contents'First;
      begin
         Assert (Protocol.Kind (Value) = Protocol.Parse, "Parse is encoded");
         Assert
           (Protocol.Read_C_String (Contents, Cursor) = "statement"
            and then Protocol.Read_C_String (Contents, Cursor) =
              "select $1::int4, $2::bytea"
            and then Protocol.Read_U16 (Contents, Cursor) = 2
            and then Protocol.Read_U32 (Contents, Cursor) = 23
            and then Protocol.Read_U32 (Contents, Cursor) = 17
            and then Cursor = Contents'First + Contents'Length,
            "Parse carries its name, SQL, and parameter OIDs");
      end;

      declare
         Value : constant Protocol.Message :=
           Protocol.Make_Bind_Message
             (Portal_Name    => "portal",
              Statement_Name => "statement",
              Parameters     =>
                (Protocol.Text_Parameter ("42"),
                 Protocol.Null_Parameter (Protocol.Binary_Format),
                 Protocol.Binary_Parameter (Binary)),
              Result_Formats =>
                (Protocol.Text_Format, Protocol.Binary_Format));
         Contents : constant Protocol.Byte_Array := Protocol.Payload (Value);
         Cursor   : Protocol.Byte_Offset := Contents'First;
      begin
         Assert (Protocol.Kind (Value) = Protocol.Bind, "Bind is encoded");
         Assert
           (Protocol.Read_C_String (Contents, Cursor) = "portal"
            and then Protocol.Read_C_String (Contents, Cursor) = "statement"
            and then Protocol.Read_U16 (Contents, Cursor) = 3
            and then Protocol.Read_U16 (Contents, Cursor) = 0
            and then Protocol.Read_U16 (Contents, Cursor) = 1
            and then Protocol.Read_U16 (Contents, Cursor) = 1
            and then Protocol.Read_U16 (Contents, Cursor) = 3
            and then Protocol.Read_U32 (Contents, Cursor) = 2,
            "Bind carries per-parameter formats and its value count");
         Assert
           (Contents (Cursor) = Protocol.Byte (Character'Pos ('4'))
            and then Contents (Cursor + 1) =
              Protocol.Byte (Character'Pos ('2')),
            "Bind preserves text parameter bytes");
         Cursor := Cursor + 2;
         Assert
           (Protocol.Read_U32 (Contents, Cursor) = Protocol.UInt32'Last
            and then Protocol.Read_U32 (Contents, Cursor) = 2
            and then Contents (Cursor) = 0
            and then Contents (Cursor + 1) = 16#FF#,
            "Bind distinguishes NULL and binary parameter values");
         Cursor := Cursor + 2;
         Assert
           (Protocol.Read_U16 (Contents, Cursor) = 2
            and then Protocol.Read_U16 (Contents, Cursor) = 0
            and then Protocol.Read_U16 (Contents, Cursor) = 1
            and then Cursor = Contents'First + Contents'Length,
            "Bind carries result format codes without trailing bytes");
      end;

      declare
         Text_Bind : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Bind_Message
              ("", "", (1 => Protocol.Text_Parameter ("x"))));
         Binary_Bind : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Bind_Message
              ("", "", (1 => Protocol.Binary_Parameter (Binary))));
         Text_Cursor : Protocol.Byte_Offset := Text_Bind'First;
         Binary_Cursor : Protocol.Byte_Offset := Binary_Bind'First;
      begin
         Assert
           (Protocol.Read_C_String (Text_Bind, Text_Cursor) = ""
            and then Protocol.Read_C_String (Text_Bind, Text_Cursor) = ""
            and then Protocol.Read_U16 (Text_Bind, Text_Cursor) = 0,
            "all-text Bind parameters use the default format-code form");
         Assert
           (Protocol.Read_C_String (Binary_Bind, Binary_Cursor) = ""
            and then Protocol.Read_C_String (Binary_Bind, Binary_Cursor) = ""
            and then Protocol.Read_U16 (Binary_Bind, Binary_Cursor) = 1
            and then Protocol.Read_U16 (Binary_Bind, Binary_Cursor) = 1,
            "all-binary Bind parameters use the single format-code form");
      end;

      declare
         Describe_Statement : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Describe_Message
              (Protocol.Statement_Object, "named"));
         Describe_Portal : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Describe_Message (Protocol.Portal_Object, ""));
         Execute : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Execute_Message ("portal", 25));
         Close_Statement : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Close_Message
              (Protocol.Statement_Object, "named"));
         Close_Portal : constant Protocol.Byte_Array := Protocol.Payload
           (Protocol.Make_Close_Message (Protocol.Portal_Object, ""));
         Cursor : Protocol.Byte_Offset := Execute'First;
      begin
         Assert
           (Describe_Statement (Describe_Statement'First) =
              Protocol.Byte (Character'Pos ('S'))
            and then Describe_Portal (Describe_Portal'First) =
              Protocol.Byte (Character'Pos ('P')),
            "Describe distinguishes named statements and unnamed portals");
         Assert
           (Protocol.Read_C_String (Execute, Cursor) = "portal"
            and then Protocol.Read_U32 (Execute, Cursor) = 25,
            "Execute carries its portal and maximum row count");
         Assert
           (Close_Statement (Close_Statement'First) =
              Protocol.Byte (Character'Pos ('S'))
            and then Close_Portal (Close_Portal'First) =
              Protocol.Byte (Character'Pos ('P')),
            "Close distinguishes statements and portals");
         Assert
           (Protocol.Payload_Length (Protocol.Make_Flush_Message) = 0
            and then Protocol.Kind (Protocol.Make_Flush_Message) =
              Protocol.Flush
            and then Protocol.Payload_Length (Protocol.Make_Sync_Message) = 0
            and then Protocol.Kind (Protocol.Make_Sync_Message) =
              Protocol.Sync,
            "Flush and Sync use empty payloads");
      end;
   end Test_Extended_Frontend_Messages;

   procedure Test_Extended_Backend_Messages is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      for Code in Character range '1' .. '3' loop
         declare
            Response : constant Protocol.Backend_Message :=
              Protocol.Decode_Backend (Protocol.Make_Empty_Message (Code));
            Expected : constant Protocol.Backend_Message_Kind :=
              (case Code is
                 when '1' => Protocol.Parse_Complete_Response,
                 when '2' => Protocol.Bind_Complete_Response,
                 when others => Protocol.Close_Complete_Response);
         begin
            Assert
              (Protocol.Response_Kind (Response) = Expected,
               "extended completion response is decoded");
         end;
      end loop;
      Assert
        (Protocol.Response_Kind
           (Protocol.Decode_Backend (Protocol.Make_Empty_Message ('n'))) =
           Protocol.No_Data_Response
         and then Protocol.Response_Kind
           (Protocol.Decode_Backend (Protocol.Make_Empty_Message ('s'))) =
           Protocol.Portal_Suspended_Response,
         "NoData and PortalSuspended are decoded");

      Protocol.Append_U16 (Contents, 3);
      Protocol.Append_U32 (Contents, 23);
      Protocol.Append_U32 (Contents, 0);
      Protocol.Append_U32 (Contents, 17);
      declare
         Response : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend
             (Protocol.Make_Message
                ('t', Flyology.Bytes.To_Array (Contents)));
         Description : constant Protocol.Parameter_Description :=
           Protocol.Parameter_Types (Response);
      begin
         Assert
           (Protocol.Parameter_Count (Description) = 3
            and then Protocol.Parameter_Type_At (Description, 1) = 23
            and then Protocol.Parameter_Type_At (Description, 2) = 0
            and then Protocol.Parameter_Type_At (Description, 3) = 17,
            "ParameterDescription retains every parameter OID");
      end;
   end Test_Extended_Backend_Messages;

   procedure Test_Copy_Protocol is
      Chunk : constant Protocol.Byte_Array (1 .. 3) :=
        (16#00#, 16#41#, 16#FF#);

      function Copy_Response (Code : Character) return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_Byte (Contents, 1);
         Protocol.Append_U16 (Contents, 2);
         Protocol.Append_U16 (Contents, 0);
         Protocol.Append_U16 (Contents, 1);
         return Protocol.Make_Message
           (Code, Flyology.Bytes.To_Array (Contents));
      end Copy_Response;

      function Frontend_Rejected (Item : Protocol.Message) return Boolean is
      begin
         declare
            Ignored : constant Protocol.Frontend_Copy_Message :=
              Protocol.Decode_Frontend_Copy (Item);
            pragma Unreferenced (Ignored);
         begin
            return False;
         end;
      exception
         when Protocol.Protocol_Error =>
            return True;
      end Frontend_Rejected;
   begin
      declare
         Command : constant Protocol.Frontend_Copy_Message :=
           Protocol.Decode_Frontend_Copy
             (Protocol.Make_Copy_Data_Message (Chunk));
      begin
         Assert
           (Protocol.Copy_Kind (Command) = Protocol.Frontend_Copy_Data
            and then Protocol.Copy_Bytes (Command) = Chunk,
            "frontend CopyData preserves one bounded chunk");
      end;

      declare
         Command : constant Protocol.Frontend_Copy_Message :=
           Protocol.Decode_Frontend_Copy
             (Protocol.Make_Copy_Fail_Message ("client stopped"));
      begin
         Assert
           (Protocol.Copy_Kind (Command) = Protocol.Frontend_Copy_Fail
            and then Protocol.Copy_Failure_Reason (Command) =
              "client stopped",
            "frontend CopyFail preserves its reason");
      end;
      Assert
        (Protocol.Copy_Kind
           (Protocol.Decode_Frontend_Copy
              (Protocol.Make_Copy_Done_Message)) =
           Protocol.Frontend_Copy_Done,
         "frontend CopyDone has a typed constructor");
      Assert
        (Frontend_Rejected
           (Protocol.Make_Message ('c', (1 => 0)))
         and then Frontend_Rejected
           (Protocol.Make_Message
              ('f', (1 => Protocol.Byte (Character'Pos ('x')))))
         and then Frontend_Rejected
           (Protocol.Make_Empty_Message ('Q')),
         "malformed and non-COPY frontend commands are rejected");

      for Code of String'("GHW") loop
         declare
            Response : constant Protocol.Backend_Message :=
              Protocol.Decode_Backend (Copy_Response (Code));
            Expected : constant Protocol.Backend_Message_Kind :=
              (case Code is
                 when 'G' => Protocol.Copy_In_Response,
                 when 'H' => Protocol.Copy_Out_Response,
                 when others => Protocol.Copy_Both_Response);
            Formats : constant Protocol.Copy_Format_Description :=
              Protocol.Copy_Formats (Response);
         begin
            Assert
              (Protocol.Response_Kind (Response) = Expected
               and then Protocol.Overall_Format (Formats) =
                 Protocol.Binary_Format
               and then Protocol.Copy_Column_Count (Formats) = 2
               and then Protocol.Copy_Column_Format (Formats, 1) =
                 Protocol.Text_Format
               and then Protocol.Copy_Column_Format (Formats, 2) =
                 Protocol.Binary_Format,
               "COPY response retains overall and per-column formats");
         end;
      end loop;

      declare
         Data_Event : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend (Protocol.Make_Message ('d', Chunk));
         Done_Event : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend (Protocol.Make_Empty_Message ('c'));
      begin
         Assert
           (Protocol.Response_Kind (Data_Event) = Protocol.Copy_Data_Response
            and then Protocol.Copy_Data (Data_Event) = Chunk
            and then Protocol.Response_Kind (Done_Event) =
              Protocol.Copy_Done_Response,
            "backend COPY data and completion are typed events");
      end;

      declare
         Channel : aliased Memory_Transport;
         Session : Server_Sessions.Session (Channel'Access);
      begin
         Queue (Channel, Protocol.Make_Flush_Message);
         Queue (Channel, Protocol.Make_Copy_Data_Message (Chunk));
         declare
            Command : constant Protocol.Frontend_Copy_Message :=
              Server_Sessions.Read_Copy_Command (Session, 1.0);
         begin
            Assert
              (Protocol.Copy_Bytes (Command) = Chunk,
               "server COPY dispatch ignores Flush before one data chunk");
         end;
      end;

      declare
         Channel : aliased Memory_Transport;
         Session : Server_Sessions.Session (Channel'Access);
      begin
         Queue (Channel, Protocol.Make_Sync_Message);
         Queue (Channel, Protocol.Make_Copy_Data_Message (Chunk));
         declare
            Command : constant Protocol.Frontend_Copy_Message :=
              Server_Sessions.Read_Copy_Command (Session, 1.0);
         begin
            Assert
              (Protocol.Copy_Bytes (Command) = Chunk,
               "server COPY dispatch ignores Sync before one data chunk");
         end;
         Server_Sessions.Send_Copy_Out_Response
           (Session,
            Protocol.Text_Format,
            (Protocol.Text_Format, Protocol.Binary_Format),
            1.0);
         Server_Sessions.Send_Copy_Data (Session, Chunk, 1.0);
         Server_Sessions.Send_Copy_Done (Session, 1.0);
         declare
            Output : constant Protocol.Byte_Array :=
              Flyology.Bytes.To_Array (Channel.Output);
         begin
            Assert
              (Output'Length = 12 + 8 + 5
               and then Output (1) = Protocol.Byte (Character'Pos ('H'))
               and then Output (13) = Protocol.Byte (Character'Pos ('d'))
               and then Output (21) = Protocol.Byte (Character'Pos ('c')),
               "server COPY helpers emit response, chunk, and done frames");
         end;
      end;
   end Test_Copy_Protocol;

   procedure Test_Negotiate_Protocol_Version is
      Channel : aliased Memory_Transport;
      Session : Server_Sessions.Session (Channel'Access);
      Expected_Frame : constant Protocol.Byte_Array (1 .. 13) :=
        (1  => Protocol.Byte (Character'Pos ('v')),
         2  => 0,
         3  => 0,
         4  => 0,
         5  => 12,
         6  => 0,
         7  => 3,
         8  => 0,
         9  => 2,
         10 => 0,
         11 => 0,
         12 => 0,
         13 => 0);
   begin
      Server_Sessions.Send_Negotiate_Protocol
        (Session, Latest_Version => 16#0003_0002#, Timeout => 1.0);
      declare
         Output : constant Protocol.Byte_Array :=
           Flyology.Bytes.To_Array (Channel.Output);
      begin
         Assert
           (Output'Length = Expected_Frame'Length,
            "NegotiateProtocolVersion has the documented frame size");
         Assert
           (Output = Expected_Frame,
            "NegotiateProtocolVersion carries the complete protocol version");
      end;
   end Test_Negotiate_Protocol_Version;

   procedure Test_Copy_Client_State is
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Authentication : Flyology.Bytes.Unbounded_Bytes;
      Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('I')));
      Chunk : constant Protocol.Byte_Array (1 .. 2) :=
        (Protocol.Byte (Character'Pos ('a')),
         Protocol.Byte (Character'Pos (ASCII.LF)));

      function Copy_Response (Code : Character) return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_Byte (Contents, 0);
         Protocol.Append_U16 (Contents, 1);
         Protocol.Append_U16 (Contents, 0);
         return Protocol.Make_Message
           (Code, Flyology.Bytes.To_Array (Contents));
      end Copy_Response;

      function Complete return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_C_String (Contents, "COPY 1");
         return Protocol.Make_Message
           ('C', Flyology.Bytes.To_Array (Contents));
      end Complete;

      function Program_Rejected
        (Action : not null access procedure) return Boolean is
      begin
         Action.all;
         return False;
      exception
         when Program_Error =>
            return True;
      end Program_Rejected;
   begin
      Protocol.Append_U32 (Authentication, 0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Session, User => "tester", Timeout => 1.0);

      declare
         procedure Invalid_Send is
         begin
            Client.Send_Copy_Data (Session, Chunk, 1.0);
         end Invalid_Send;

         procedure Invalid_Receive is
         begin
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, 1.0);
               pragma Unreferenced (Event);
            begin
               null;
            end;
         end Invalid_Receive;
      begin
         Assert
           (Program_Rejected (Invalid_Send'Access)
            and then Program_Rejected (Invalid_Receive'Access),
            "COPY state misuse raises a normal Ada Program_Error");
      end;

      Client.Send_Query (Session, "copy t to stdout", Timeout => 1.0);
      Queue (Channel, Copy_Response ('H'));
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Started) = Protocol.Copy_Out_Response
            and then Client.State (Session) = Client.Copy_Out_Active,
            "simple query enters COPY OUT");
      end;
      Queue (Channel, Protocol.Make_Message ('d', Chunk));
      Queue (Channel, Protocol.Make_Empty_Message ('c'));
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Data_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Done_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Complete_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
      begin
         Assert
           (Protocol.Copy_Data (Data_Event) = Chunk
            and then Protocol.Response_Kind (Done_Event) =
              Protocol.Copy_Done_Response
            and then Protocol.Completion_Tag (Complete_Event) = "COPY 1"
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response
            and then Client.Is_Ready (Session),
            "COPY OUT streams chunks and recovers at ReadyForQuery");
      end;

      Client.Send_Query (Session, "copy t from stdin", Timeout => 1.0);
      Queue (Channel, Copy_Response ('G'));
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
         pragma Unreferenced (Started);
      begin
         Client.Send_Copy_Data (Session, Chunk, 1.0);
         Client.Send_Copy_Data
           (Session, Protocol.Byte_Array'(1 .. 0 => 0), 1.0);
         Client.Finish_Copy (Session, 1.0);
      end;
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Complete_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Complete_Event) =
              Protocol.Command_Complete_Response
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response,
            "COPY IN accepts multiple chunks and finishes gracefully");
      end;

      Client.Send_Query (Session, "copy t from stdin", Timeout => 1.0);
      Queue (Channel, Copy_Response ('G'));
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
         pragma Unreferenced (Started);
      begin
         Client.Abort_Copy (Session, "test abort", 1.0);
      end;
      Queue
        (Channel,
         Protocol.Make_Message
           ('E',
            (1 => Protocol.Byte (Character'Pos ('M')),
             2 => Protocol.Byte (Character'Pos ('x')),
             3 => 0,
             4 => 0)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Error_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Ready_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Error_Event) = Protocol.Error_Response
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response
            and then Client.Is_Ready (Session),
            "CopyFail recovers a simple-query COPY stream");
      end;

      Client.Prepare_Statement
        (Session, "copy_in", "copy t from stdin", Timeout => 1.0);
      Client.Bind_Portal (Session, "", "copy_in", Timeout => 1.0);
      Client.Execute_Portal (Session, "", Timeout => 1.0);
      Queue (Channel, Copy_Response ('G'));
      declare
         Started : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, 1.0);
         pragma Unreferenced (Started);
      begin
         Client.Send_Copy_Data (Session, Chunk, 1.0);
         Client.Finish_Copy (Session, 1.0);
         Client.Synchronize (Session, 1.0);
      end;
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Complete_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Ready_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Complete_Event) =
              Protocol.Command_Complete_Response
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response
            and then Client.Is_Ready (Session),
            "extended COPY observes Sync before ReadyForQuery");
      end;

      Client.Send_Query (Session, "copy both fixture", Timeout => 1.0);
      Queue (Channel, Copy_Response ('W'));
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
         pragma Unreferenced (Started);
      begin
         Queue (Channel, Protocol.Make_Message ('d', Chunk));
         Queue (Channel, Protocol.Make_Empty_Message ('c'));
         declare
            Data_Event : constant Client.Copy_Event :=
              Client.Receive_Copy_Event (Session, 1.0);
            Done_Event : constant Client.Copy_Event :=
              Client.Receive_Copy_Event (Session, 1.0);
            pragma Unreferenced (Data_Event, Done_Event);
         begin
            Assert
              (Client.State (Session) = Client.Copy_Both_Active,
               "COPY BOTH keeps its writable direction after backend done");
         end;
         Client.Send_Copy_Data (Session, Chunk, 1.0);
         Client.Finish_Copy (Session, 1.0);
      end;
      Queue (Channel, Protocol.Make_Message ('d', Chunk));
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Trailing_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Complete_Event : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, 1.0);
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, 1.0);
         pragma Unreferenced
           (Trailing_Event, Complete_Event, Ready_Event);
      begin
         Assert
           (Client.Is_Ready (Session),
            "COPY BOTH accepts crossed teardown data before completion");
      end;

      Client.Send_Query (Session, "copy raw from stdin", Timeout => 1.0);
      Queue (Channel, Copy_Response ('G'));
      declare
         Response : constant Protocol.Message :=
           Client.Receive_Message (Session, 1.0);
         pragma Unreferenced (Response);
      begin
         Client.Send_Command
           (Session, Protocol.Make_Copy_Data_Message (Chunk), 1.0);
         Client.Send_Command
           (Session, Protocol.Make_Copy_Done_Message, 1.0);
      end;
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Complete_Message : constant Protocol.Message :=
           Client.Receive_Message (Session, 1.0);
         Ready_Message : constant Protocol.Message :=
           Client.Receive_Message (Session, 1.0);
         pragma Unreferenced (Complete_Message, Ready_Message);
      begin
         Assert
           (Client.Is_Ready (Session),
            "raw COPY commands and receives preserve state tracking");
      end;
   end Test_Copy_Client_State;

   procedure Test_Base_Backup_Client_State is
      Channel : aliased Memory_Transport;
      Session : aliased Client.Session (Channel'Access);
      Receiver : Base_Backups.Receiver (Session'Access);
      Server_Channel : aliased Memory_Transport;
      Server_Session : Server_Sessions.Session (Server_Channel'Access);
      Authentication : Flyology.Bytes.Unbounded_Bytes;
      Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('I')));
      Chunk : constant Protocol.Byte_Array (1 .. 4) :=
        (16#75#, 16#73#, 16#74#, 16#61#);
      Manifest_Chunk : constant Protocol.Byte_Array (1 .. 2) :=
        (16#7B#, 16#7D#);
      Settings : Base_Backups.Options := Base_Backups.Defaults (15);
      Step : Natural := 0;
   begin
      Protocol.Append_U32 (Authentication, 0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Session, User => "backup-test", Timeout => 1.0);

      Backup_Sessions.Send_Start_Position
        (Server_Session, 16#100#, 1, 1.0);
      Backup_Sessions.Begin_Tablespaces (Server_Session, 1.0);
      Backup_Sessions.Send_Tablespace
        (Server_Session,
         Oid_Present      => False,
         Location_Present => False,
         Size_Present     => True,
         Size_KiB         => 42,
         Timeout          => 1.0);
      Backup_Sessions.Complete_Tablespaces (Server_Session, 1.0);
      Backup_Sessions.Begin_Stream (Server_Session, 1.0);
      Backup_Sessions.Send_Archive_Start
        (Server_Session, "base.tar", "", 1.0);
      Backup_Sessions.Send_Data
        (Server_Session, 15, Chunk, 1.0);
      declare
         Rejected : Boolean := False;
      begin
         begin
            Backup_Sessions.Send_Progress
              (Server_Session, Interfaces.Unsigned_64'Last, 1.0);
         exception
            when Protocol.Protocol_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected,
            "base backup progress rejects negative PostgreSQL int64 values");
      end;
      Backup_Sessions.Send_Progress (Server_Session, 4, 1.0);
      Backup_Sessions.Send_Manifest_Start (Server_Session, 1.0);
      Backup_Sessions.Send_Data
        (Server_Session, 15, Manifest_Chunk, 1.0);
      Backup_Sessions.Finish_Stream (Server_Session, 1.0);
      Backup_Sessions.Send_End_Position
        (Server_Session, 16#200#, 1, 1.0);
      Flyology.Bytes.Append
        (Channel.Input, Flyology.Bytes.To_Array (Server_Channel.Output));

      Base_Backups.Set_Progress (Settings);
      Base_Backups.Set_Manifest
        (Settings, Base_Backups.Include_Manifest);
      Base_Backups.Start (Receiver, Settings, 1.0);

      loop
         declare
            Event : constant Base_Backups.Event :=
              Base_Backups.Receive (Receiver, 1.0);
         begin
            Step := Step + 1;
            case Step is
               when 1 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Backup_Start
                     and then Base_Backups.Start_LSN (Event) = 16#100#
                     and then Base_Backups.Timeline (Event) = 1,
                     "base backup exposes its consistent start position");
               when 2 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Tablespace
                     and then not Base_Backups.Has_Tablespace_Oid (Event)
                     and then not
                       Base_Backups.Has_Tablespace_Location (Event)
                     and then Base_Backups.Tablespace_Size_KiB (Event) = 42,
                     "base backup preserves nullable tablespace metadata");
               when 3 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Archive_Start
                     and then Base_Backups.Archive_Name (Event) = "base.tar"
                     and then Base_Backups.Archive_Location (Event) = "",
                     "multiplexed backup names each archive");
               when 4 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Archive_Data
                     and then Base_Backups.Data (Event) = Chunk,
                     "archive data is returned one bounded frame at a time");
               when 5 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Progress
                     and then Base_Backups.Bytes_Completed (Event) = 4,
                     "backup progress preserves its int64 byte count");
               when 6 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Manifest_Start,
                     "backup manifest start is explicit");
               when 7 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Manifest_Data
                     and then Base_Backups.Data (Event) = Manifest_Chunk,
                     "manifest bytes share the bounded stream API");
               when 8 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Backup_End
                     and then Base_Backups.End_LSN (Event) = 16#200#
                     and then Base_Backups.Timeline (Event) = 1,
                     "base backup validates and exposes its end position");
               when 9 =>
                  Assert
                    (Base_Backups.Kind (Event) = Base_Backups.Complete
                     and then Client.Is_Ready (Session),
                     "base backup completion consumes ReadyForQuery");
                  exit;
               when others =>
                  Assert (False, "base backup emitted an unexpected event");
            end case;
         end;
      end loop;
   end Test_Base_Backup_Client_State;

   procedure Test_Extended_Client_State is
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Authentication : Flyology.Bytes.Unbounded_Bytes;
      Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('I')));

      function Rejected (Action : not null access procedure) return Boolean is
      begin
         Action.all;
         return False;
      exception
         when Program_Error =>
            return True;
      end Rejected;
   begin
      Protocol.Append_U32 (Authentication, 0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Session, User => "tester", Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Ready
         and then Client.Is_Ready (Session),
         "startup enters the ready state");

      declare
         procedure Invalid_Execute is
         begin
            Client.Execute_Portal (Session, "portal", Timeout => 1.0);
         end Invalid_Execute;
      begin
         Assert
           (Rejected (Invalid_Execute'Access),
            "Execute before Bind is rejected locally");
      end;

      Client.Prepare_Statement
        (Session, "statement", "select $1::text", Timeout => 1.0);
      Client.Bind_Portal
        (Session,
         "portal",
         "statement",
         (1 => Protocol.Text_Parameter ("value")),
         Timeout => 1.0);
      Client.Execute_Portal
        (Session, "portal", Maximum_Rows => 1, Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Extended_Query_Active,
         "extended commands can be pipelined through Flush");

      Queue (Channel, Protocol.Make_Empty_Message ('s'));
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Event) =
              Protocol.Portal_Suspended_Response,
            "PortalSuspended enables a resume transition");
      end;
      Client.Resume_Portal
        (Session, "portal", Maximum_Rows => 0, Timeout => 1.0);

      Queue
        (Channel,
         Protocol.Make_Message
           ('E',
            (1 => Protocol.Byte (Character'Pos ('M')),
             2 => Protocol.Byte (Character'Pos ('x')),
             3 => 0,
             4 => 0)));
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Event) = Protocol.Error_Response
            and then Client.State (Session) = Client.Recovery_Required,
            "an extended error requires recovery");
      end;
      declare
         procedure Invalid_Prepare is
         begin
            Client.Prepare_Statement
              (Session, "other", "select 1", Timeout => 1.0);
         end Invalid_Prepare;
      begin
         Assert
           (Rejected (Invalid_Prepare'Access),
            "commands are rejected until extended error recovery starts");
      end;
      Client.Synchronize (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Event) = Protocol.Ready_For_Query_Response
            and then Client.State (Session) = Client.Ready,
            "Sync plus ReadyForQuery makes the session reusable");
      end;

      Client.Prepare_Statement
        (Session, "bad", "select broken", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('E',
            (1 => Protocol.Byte (Character'Pos ('M')),
             2 => Protocol.Byte (Character'Pos ('x')),
             3 => 0,
             4 => 0)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Error_Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
         Ready_Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Error_Event) = Protocol.Error_Response
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response
            and then Client.State (Session) = Client.Ready,
            "a pipelined Sync is honored after an extended error");
      end;

      Client.Send_Query (Session, "select 1", Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Simple_Query_Active,
         "Send_Query enters the simple-query state");
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      declare
         Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 1.0);
      begin
         Assert
           (Protocol.Response_Kind (Event) = Protocol.Ready_For_Query_Response
            and then Client.State (Session) = Client.Ready,
            "simple-query ReadyForQuery restores the ready state");
      end;
      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Closed,
         "Terminate closes the local session state");
   end Test_Extended_Client_State;

   procedure Test_Pipelined_Client_State is
      Channel : aliased Memory_Transport;
      Session : Client.Session (Channel'Access);
      Copy_Channel : aliased Memory_Transport;
      Copy_Session : Client.Session (Copy_Channel'Access);
      Authentication : Flyology.Bytes.Unbounded_Bytes;
      Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('I')));
      Failure : constant Protocol.Byte_Array (1 .. 4) :=
        (1 => Protocol.Byte (Character'Pos ('M')),
         2 => Protocol.Byte (Character'Pos ('x')),
         3 => 0,
         4 => 0);
      Copy_Rejected : Boolean := False;

      function Complete return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_C_String (Contents, "SELECT 1");
         return Protocol.Make_Message
           ('C', Flyology.Bytes.To_Array (Contents));
      end Complete;

      function Single_Column_Row return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_U16 (Contents, 1);
         Protocol.Append_U32 (Contents, 1);
         Protocol.Append_Byte
           (Contents, Protocol.Byte (Character'Pos ('1')));
         return Protocol.Make_Message
           ('D', Flyology.Bytes.To_Array (Contents));
      end Single_Column_Row;

      function Copy_Out_Response return Protocol.Message is
         Contents : Flyology.Bytes.Unbounded_Bytes;
      begin
         Protocol.Append_Byte (Contents, 0);
         Protocol.Append_U16 (Contents, 1);
         Protocol.Append_U16 (Contents, 0);
         return Protocol.Make_Message
           ('H', Flyology.Bytes.To_Array (Contents));
      end Copy_Out_Response;

      function Rejected (Action : not null access procedure) return Boolean is
      begin
         Action.all;
         return False;
      exception
         when Program_Error =>
            return True;
      end Rejected;

      function Next return Protocol.Backend_Message_Kind is
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 1.0);
      begin
         return Protocol.Response_Kind (Event);
      end Next;

      procedure Write_Batch (Name : String) is
      begin
         Client.Prepare_Statement (Session, Name, "select 1", Timeout => 1.0);
         Client.Bind_Portal (Session, Name, Name, Timeout => 1.0);
         Client.Execute_Portal (Session, Name, Timeout => 1.0);
         Client.Synchronize (Session, Timeout => 1.0);
      end Write_Batch;
   begin
      Protocol.Append_U32 (Authentication, 0);
      Queue
        (Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Session, User => "tester", Timeout => 1.0);

      Client.Enter_Pipeline_Mode (Session);
      Assert
        (Client.In_Pipeline_Mode (Session)
         and then Client.Pending_Synchronizations (Session) = 0
         and then Client.State (Session) = Client.Ready,
         "pipeline mode starts from an idle session");

      declare
         procedure Invalid_Query is
         begin
            Client.Send_Query (Session, "select 1", Timeout => 1.0);
         end Invalid_Query;
      begin
         Assert
           (Rejected (Invalid_Query'Access),
            "simple queries are rejected in pipeline mode");
      end;

      Write_Batch ("first");
      Assert
        (Client.State (Session) = Client.Awaiting_Ready
         and then Client.Pending_Synchronizations (Session) = 1,
         "the first pipelined batch stays outstanding after Sync");

      Client.Prepare_Statement
        (Session, "second", "select 1", Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 1,
         "a new batch opens without consuming the pending ReadyForQuery");
      Client.Bind_Portal (Session, "second", "second", Timeout => 1.0);
      Client.Execute_Portal (Session, "second", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Assert
        (Client.Pending_Synchronizations (Session) = 2,
         "two Sync-terminated batches are in flight at once");

      declare
         procedure Invalid_Exit is
         begin
            Client.Exit_Pipeline_Mode (Session);
         end Invalid_Exit;
      begin
         Assert
           (Rejected (Invalid_Exit'Access),
            "pipeline mode cannot end while a batch is outstanding");
      end;

      Queue (Channel, Protocol.Make_Message ('E', Failure));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Error_Response
         and then Client.State (Session) = Client.Awaiting_Ready
         and then Client.Pending_Synchronizations (Session) = 2,
         "a failed pipelined batch needs no separate recovery Sync");
      Assert
        (Next = Protocol.Ready_For_Query_Response
         and then Client.State (Session) = Client.Awaiting_Ready
         and then Client.Pending_Synchronizations (Session) = 1,
         "each ReadyForQuery ends exactly one pipelined batch");

      Queue (Channel, Protocol.Make_Empty_Message ('1'));
      Queue (Channel, Protocol.Make_Empty_Message ('2'));
      Queue (Channel, Complete);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Parse_Complete_Response
         and then Next = Protocol.Bind_Complete_Response
         and then Next = Protocol.Command_Complete_Response,
         "the batch behind a failed one is answered normally");
      Assert
        (Next = Protocol.Ready_For_Query_Response
         and then Client.State (Session) = Client.Ready
         and then Client.Pending_Synchronizations (Session) = 0,
         "the last ReadyForQuery restores the ready state");

      Client.Prepare_Statement (Session, "third", "select 1", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Client.Prepare_Statement (Session, "fourth", "select 1", Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 1,
         "an open batch coexists with an outstanding earlier batch");
      Queue (Channel, Protocol.Make_Empty_Message ('1'));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Parse_Complete_Response
         and then Next = Protocol.Ready_For_Query_Response
         and then Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 0,
         "retiring an earlier batch leaves the open batch open");
      Client.Synchronize (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Ready_For_Query_Response
         and then Client.State (Session) = Client.Ready,
         "the last open batch completes through its own Sync");

      Client.Exit_Pipeline_Mode (Session);
      Assert
        (not Client.In_Pipeline_Mode (Session)
         and then Client.Is_Ready (Session),
         "pipeline mode ends once every batch is consumed");

      Client.Prepare_Statement (Session, "busy", "select 1", Timeout => 1.0);
      declare
         procedure Invalid_Enter is
         begin
            Client.Enter_Pipeline_Mode (Session);
         end Invalid_Enter;
      begin
         Assert
           (Rejected (Invalid_Enter'Access),
            "pipeline mode requires an idle session");
      end;
      Client.Synchronize (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Ready_For_Query_Response
         and then Client.Is_Ready (Session),
         "a non-pipelined cycle still ends at ReadyForQuery");

      Client.Enter_Pipeline_Mode (Session);
      Client.Enter_Pipeline_Mode (Session);
      Assert
        (Client.In_Pipeline_Mode (Session),
         "entering pipeline mode twice is a no-op");

      Client.Prepare_Statement
        (Session, "flushed", "select 1", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Awaiting_Ready
         and then Client.Pending_Synchronizations (Session) = 1,
         "Flush after Sync forces output without opening a batch");
      Queue (Channel, Protocol.Make_Empty_Message ('1'));
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Parse_Complete_Response
         and then Next = Protocol.Ready_For_Query_Response
         and then Client.State (Session) = Client.Ready
         and then Client.Pending_Synchronizations (Session) = 0,
         "a flushed pipelined batch still returns the session to Ready");

      Client.Prepare_Statement
        (Session, "unsynced", "select 1", Timeout => 1.0);
      Client.Flush (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Message ('E', Failure));
      Assert
        (Next = Protocol.Error_Response
         and then Client.State (Session) = Client.Recovery_Required
         and then Client.Pending_Synchronizations (Session) = 0,
         "an unsynchronized pipelined failure still requires recovery");
      Client.Synchronize (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Ready_For_Query_Response
         and then Client.Is_Ready (Session),
         "Synchronize recovers a pipelined session");

      --  A portal executed without Describe returns bare rows, which the
      --  extended path accepts. Only a description that arrived constrains
      --  the column count.
      Client.Prepare_Statement
        (Session, "bare", "select 1", Timeout => 1.0);
      Client.Bind_Portal (Session, "bare", "bare", Timeout => 1.0);
      Client.Execute_Portal (Session, "bare", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Queue (Channel, Protocol.Make_Empty_Message ('1'));
      Queue (Channel, Protocol.Make_Empty_Message ('2'));
      Queue (Channel, Single_Column_Row);
      Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Assert
        (Next = Protocol.Parse_Complete_Response
         and then Next = Protocol.Bind_Complete_Response
         and then Next = Protocol.Data_Row_Response
         and then Next = Protocol.Ready_For_Query_Response
         and then Client.Is_Ready (Session),
         "an undescribed portal may return rows without a RowDescription");

      Client.Exit_Pipeline_Mode (Session);
      Client.Exit_Pipeline_Mode (Session);
      Assert
        (not Client.In_Pipeline_Mode (Session),
         "leaving pipeline mode twice is a no-op");

      Client.Enter_Pipeline_Mode (Session);
      Client.Prepare_Statement
        (Session, "abandoned", "select 1", Timeout => 1.0);
      Client.Synchronize (Session, Timeout => 1.0);
      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 1.0);
      Assert
        (Client.State (Session) = Client.Closed
         and then not Client.In_Pipeline_Mode (Session)
         and then Client.Pending_Synchronizations (Session) = 0,
         "Terminate clears pipeline mode and its outstanding count");

      --  A rejected COPY response is terminal, so it needs its own session.
      Queue
        (Copy_Channel,
         Protocol.Make_Message
           ('R', Flyology.Bytes.To_Array (Authentication)));
      Queue (Copy_Channel, Protocol.Make_Message ('Z', Ready_Payload));
      Client.Startup (Copy_Session, User => "tester", Timeout => 1.0);
      Client.Enter_Pipeline_Mode (Copy_Session);
      Client.Prepare_Statement
        (Copy_Session, "copy", "copy t to stdout", Timeout => 1.0);
      Client.Bind_Portal (Copy_Session, "copy", "copy", Timeout => 1.0);
      Client.Execute_Portal (Copy_Session, "copy", Timeout => 1.0);
      Client.Synchronize (Copy_Session, Timeout => 1.0);
      Queue (Copy_Channel, Copy_Out_Response);
      --  The raise happens in the inner declarative part, which only an
      --  enclosing frame can handle.
      begin
         declare
            Ignored : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Copy_Session, Timeout => 1.0);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Protocol.Protocol_Error =>
            Copy_Rejected := True;
      end;
      Assert
        (Copy_Rejected
         and then Client.State (Copy_Session) = Client.Closed
         and then not Client.In_Pipeline_Mode (Copy_Session)
         and then Client.Pending_Synchronizations (Copy_Session) = 0,
         "a pipelined COPY response closes the session it arrives on");
   end Test_Pipelined_Client_State;

   function Decode_Is_Rejected
     (Code : Character; Contents : Protocol.Byte_Array) return Boolean is
   begin
      declare
         Ignored : constant Protocol.Backend_Message :=
           Protocol.Decode_Backend (Protocol.Make_Message (Code, Contents));
      begin
         return Protocol.Response_Kind (Ignored) = Protocol.Unknown_Response;
      end;
   exception
      when Protocol.Protocol_Error =>
         return True;
   end Decode_Is_Rejected;

   procedure Test_Malformed_Backend_Messages is
      Marker_Codes : constant String := "123ns";
      Empty : constant Protocol.Byte_Array (1 .. 0) := (others => 0);
      Row_Count_Only : constant Protocol.Byte_Array (1 .. 2) :=
        (1 => 0, 2 => 1);
      Data_Truncated : constant Protocol.Byte_Array (1 .. 6) :=
        (1 => 0, 2 => 1, 3 => 0, 4 => 0, 5 => 0, 6 => 2);
      Data_Trailing : constant Protocol.Byte_Array (1 .. 7) :=
        (1 => 0, 2 => 1, 3 => 0, 4 => 0, 5 => 0, 6 => 0, 7 => 99);
      Bad_Ready : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('?')));
      Missing_Diagnostic_Terminator : constant Protocol.Byte_Array (1 .. 3) :=
        (1 => Protocol.Byte (Character'Pos ('M')),
         2 => Protocol.Byte (Character'Pos ('x')),
         3 => 0);
      Parameter_Count_Only : constant Protocol.Byte_Array (1 .. 2) :=
        (1 => 0, 2 => 1);
      Parameter_Trailing : constant Protocol.Byte_Array (1 .. 3) :=
        (1 => 0, 2 => 0, 3 => 99);
      Copy_Truncated : constant Protocol.Byte_Array (1 .. 2) :=
        (1 => 0, 2 => 0);
      Copy_Bad_Overall : constant Protocol.Byte_Array (1 .. 3) :=
        (1 => 2, 2 => 0, 3 => 0);
      Copy_Bad_Count : constant Protocol.Byte_Array (1 .. 3) :=
        (1 => 0, 2 => 0, 3 => 1);
      Copy_Bad_Format : constant Protocol.Byte_Array (1 .. 5) :=
        (1 => 0, 2 => 0, 3 => 1, 4 => 0, 5 => 2);
   begin
      Assert
        (Decode_Is_Rejected ('T', Row_Count_Only),
         "impossible RowDescription counts are rejected");
      Assert
        (Decode_Is_Rejected ('D', Data_Truncated),
         "truncated DataRow values are rejected");
      Assert
        (Decode_Is_Rejected ('D', Data_Trailing),
         "DataRow trailing bytes are rejected");
      Assert
        (Decode_Is_Rejected ('C', Empty),
         "unterminated CommandComplete tags are rejected");
      Assert
        (Decode_Is_Rejected ('I', Bad_Ready),
         "nonempty EmptyQueryResponse payloads are rejected");
      Assert
        (Decode_Is_Rejected ('Z', Bad_Ready),
         "invalid ReadyForQuery states are rejected");
      Assert
        (Decode_Is_Rejected ('E', Missing_Diagnostic_Terminator),
         "diagnostics require a final message terminator");
      Assert
        (Decode_Is_Rejected ('S', Empty),
         "truncated ParameterStatus messages are rejected");
      Assert
        (Decode_Is_Rejected ('t', Parameter_Count_Only),
         "impossible ParameterDescription counts are rejected");
      Assert
        (Decode_Is_Rejected ('t', Parameter_Trailing),
         "ParameterDescription trailing bytes are rejected");
      for Code of Marker_Codes loop
         Assert
           (Decode_Is_Rejected (Code, Bad_Ready),
            "extended marker responses reject nonempty payloads");
      end loop;
      for Code of String'("GHW") loop
         Assert
           (Decode_Is_Rejected (Code, Copy_Truncated)
            and then Decode_Is_Rejected (Code, Copy_Bad_Overall)
            and then Decode_Is_Rejected (Code, Copy_Bad_Count)
            and then Decode_Is_Rejected (Code, Copy_Bad_Format),
            "malformed COPY formats and counts are rejected");
      end loop;
      Assert
        (Decode_Is_Rejected ('c', Bad_Ready),
         "backend CopyDone rejects a nonempty payload");
   end Test_Malformed_Backend_Messages;

   procedure Test_Composable_Client_Operations is

      procedure Start_Memory_Session
        (Item    : in out Client.Session;
         Channel : in out Memory_Transport) is
         Authentication : Flyology.Bytes.Unbounded_Bytes;
         Ready_Payload  : constant Protocol.Byte_Array (1 .. 1) :=
           (1 => Protocol.Byte (Character'Pos ('I')));
      begin
         Protocol.Append_U32 (Authentication, 0);
         Queue
           (Channel,
            Protocol.Make_Message
              ('R', Flyology.Bytes.To_Array (Authentication)));
         Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
         Client.Startup (Item, User => "operation-test", Timeout => 1.0);
      end Start_Memory_Session;

      procedure Test_Startup_Operations is
         Channel : aliased Memory_Transport;
         Session : aliased Client.Session (Channel'Access);
         Set     : aliased Operations.Completion_Set (Capacity => 2);
         Authentication : Flyology.Bytes.Unbounded_Bytes;
         Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
           (1 => Protocol.Byte (Character'Pos ('I')));
      begin
         Flyology.Bytes.Append
           (Channel.Input,
            (1 => Protocol.Byte (Character'Pos ('S'))));
         declare
            Request : Client.Startup_Operation :=
              Client.Negotiate_TLS
                (Set'Access, Session'Access, Timeout => 1.0);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Request);
            Assert
              (Client.State (Session) = Client.TLS_Negotiated,
               "scoped SSLRequest retains the accepted TLS boundary");
         end;

         Protocol.Append_U32 (Authentication, 0);
         Queue
           (Channel,
            Protocol.Make_Message
              ('R', Flyology.Bytes.To_Array (Authentication)));
         Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
         declare
            Start : Client.Startup_Operation :=
              Client.Startup
                (Set'Access,
                 Session'Access,
                 User    => "operation-test",
                 Timeout => 1.0);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Start);
            Assert
              (Client.Is_Ready (Session) and then not Channel.Engaged,
               "scoped startup authenticates and releases its capability");
         end;

         declare
            Refused_Channel : aliased Memory_Transport;
            Refused_Session : aliased Client.Session
              (Refused_Channel'Access);
            Refused_Set : aliased Operations.Completion_Set (Capacity => 1);
            Refused : Boolean := False;
         begin
            Flyology.Bytes.Append
              (Refused_Channel.Input,
               (1 => Protocol.Byte (Character'Pos ('N'))));
            declare
               Request : Client.Startup_Operation :=
                 Client.Negotiate_TLS
                   (Refused_Set'Access,
                    Refused_Session'Access,
                    Timeout => 1.0);
            begin
               Operations.Wait_All (Refused_Set);
               begin
                  Client.Finish (Request);
               exception
                  when Client.TLS_Not_Available =>
                     Refused := True;
               end;
            end;
            Assert
              (Refused
               and then Client.State (Refused_Session) = Client.Closed
               and then not Refused_Channel.Engaged,
               "TLS refusal is retained until Finish and is terminal");
         end;
      end Test_Startup_Operations;

      procedure Test_Partial_And_Gates is
         Channel : aliased Memory_Transport;
         Session : aliased Client.Session (Channel'Access);
         Set     : aliased Operations.Completion_Set (Capacity => 6);
         Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
           (1 => Protocol.Byte (Character'Pos ('I')));
      begin
         Start_Memory_Session (Session, Channel);
         declare
            Batch : Operations.Completion_Batch (Set.Capacity);
            Send  : Client.Send_Operation :=
              Client.Send_Query
                (Set'Access, Session'Access, "select 1", Timeout => 1.0);
            Timer : Timers.Timer_Operation :=
              Timers.Sleep_For (Set'Access, 0.001);
            Gate  : Operations.Gate_Operation :=
              Operations.Wait_For_Success
                (Set'Access,
                 Operations.Operation_Reference_Array'
                   (1 => Operations.Reference (Send),
                    2 => Operations.Reference (Timer)));
         begin
            Operations.Wait_All (Set);
            Operations.Finish (Gate, Batch);
            Client.Finish (Send);
            Timers.Finish (Timer);
            Assert
              (Client.State (Session) = Client.Simple_Query_Active,
               "scoped query send preserves synchronous state transition");
            Assert
              (not Channel.Engaged,
               "successful send releases the transport capability");
         end;

         Queue (Channel, Protocol.Make_Empty_Message ('I'));
         Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
         declare
            Event   : Protocol.Backend_Message;
            Receive : Client.Receive_Operation :=
              Client.Receive_Query_Event
                (Set'Access, Session'Access, Timeout => 1.0);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Receive, Event);
            Assert
              (Protocol.Response_Kind (Event) =
                 Protocol.Empty_Query_Response,
               "partial scoped receive returns the decoded query event");

            Client.Receive_Query_Event
              (Session'Access, Timeout => 1.0, Operation => Receive);
            Operations.Wait_All (Set);
            Client.Finish (Receive, Event);
            Assert
              (Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response,
               "reusable receive reaches ReadyForQuery");
            Assert
              (Client.Is_Ready (Session) and then not Channel.Engaged,
               "reusable receive releases ownership and restores readiness");
         end;
      end Test_Partial_And_Gates;

      procedure Test_Counted_Multiple_Connections is
         Left_Channel  : aliased Memory_Transport;
         Right_Channel : aliased Memory_Transport;
         Left_Session  : aliased Client.Session (Left_Channel'Access);
         Right_Session : aliased Client.Session (Right_Channel'Access);
         Set   : aliased Operations.Completion_Set (Capacity => 5);
         Batch : Operations.Completion_Batch (Set.Capacity);
         Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
           (1 => Protocol.Byte (Character'Pos ('I')));
      begin
         Start_Memory_Session (Left_Session, Left_Channel);
         Start_Memory_Session (Right_Session, Right_Channel);
         declare
            Left : Client.Send_Operation :=
              Client.Send_Query
                (Set'Access, Left_Session'Access, "select 1", 1.0);
            Right : Client.Send_Operation :=
              Client.Send_Query
                (Set'Access, Right_Session'Access, "select 2", 1.0);
            Successes : Operations.Gate_Operation :=
              Operations.Wait_For_Successes
                (Set'Access,
                 Operations.Operation_Reference_Array'
                   (1 => Operations.Reference (Left),
                    2 => Operations.Reference (Right)),
                 Required => 2);
         begin
            Operations.Wait_Some (Set, Required => 2, Completed => Batch);
            Assert
              (Batch.Count >= 2,
               "counted Wait_Some reports multiple connection operations");
            Operations.Wait_All (Set);
            Operations.Finish (Successes, Batch);
            Client.Finish (Left);
            Client.Finish (Right);
            Assert
              (not Left_Channel.Engaged
               and then not Right_Channel.Engaged,
               "multiple connection operations release both capabilities");

            Queue
              (Left_Channel, Protocol.Make_Message ('Z', Ready_Payload));
            Queue
              (Right_Channel, Protocol.Make_Message ('Z', Ready_Payload));
            declare
               Ignored_Left : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Left_Session, 1.0);
               Ignored_Right : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Right_Session, 1.0);
               pragma Unreferenced (Ignored_Left, Ignored_Right);
            begin
               null;
            end;
            Client.Send_Query
              (Left_Session'Access, "select 3", 1.0, Left);
            Client.Send_Query
              (Right_Session'Access, "select 4", 1.0, Right);
            Operations.Wait_At_Least (Set, 2, Batch);
            Assert
              (Batch.Count >= 2,
               "Wait_At_Least reports the requested operation count");
            Operations.Wait_All (Set);
            Client.Finish (Left);
            Client.Finish (Right);
         end;
      end Test_Counted_Multiple_Connections;

      procedure Test_Extended_Operations is
         Channel : aliased Memory_Transport;
         Session : aliased Client.Session (Channel'Access);
         Set     : aliased Operations.Completion_Set (Capacity => 2);
         Event   : Protocol.Backend_Message;
      begin
         Start_Memory_Session (Session, Channel);
         Client.Prepare_Statement
           (Session, Statement_Name => "statement", SQL => "select 1");
         Client.Bind_Portal
           (Session,
            Portal_Name    => "portal",
            Statement_Name => "statement");
         declare
            Execute : Client.Send_Operation :=
              Client.Execute_Portal
                (Set'Access,
                 Session'Access,
                 Portal_Name => "portal",
                 Maximum_Rows => 1,
                 Timeout => 1.0);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Execute);
         end;
         Queue (Channel, Protocol.Make_Empty_Message ('1'));
         declare
            Receive : Client.Receive_Operation :=
              Client.Receive_Extended_Event
                (Set'Access, Session'Access, Timeout => 1.0);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Receive, Event);
            Assert
              (Protocol.Response_Kind (Event) =
                 Protocol.Parse_Complete_Response,
               "scoped extended receive returns a typed event");
         end;
      end Test_Extended_Operations;

      procedure Test_Timeout_Cancel_Failure_And_Cleanup is
         Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
           (1 => Protocol.Byte (Character'Pos ('I')));

         procedure Begin_Query
           (Session : in out Client.Session;
            Channel : in out Memory_Transport) is
         begin
            Start_Memory_Session (Session, Channel);
            Client.Send_Query (Session, "select 1", Timeout => 1.0);
            Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
         end Begin_Query;
      begin
         declare
            Channel : aliased Memory_Transport;
            Session : aliased Client.Session (Channel'Access);
            Set     : aliased Operations.Completion_Set (Capacity => 1);
            Event   : Protocol.Backend_Message;
            Timed_Out : Boolean := False;
         begin
            Begin_Query (Session, Channel);
            Channel.Blocked := True;
            declare
               Receive : Client.Receive_Operation :=
                 Client.Receive_Query_Event
                   (Set'Access, Session'Access, Timeout => 0.001);
            begin
               Operations.Wait_All (Set);
               begin
                  Client.Finish (Receive, Event);
               exception
                  when Flyology.IO.Timeout_Error =>
                     Timed_Out := True;
               end;
            end;
            Assert
              (Timed_Out and then not Channel.Engaged,
               "timeout is retained until Finish and releases capability");
         end;

         declare
            Channel : aliased Memory_Transport;
            Session : aliased Client.Session (Channel'Access);
            Set     : aliased Operations.Completion_Set (Capacity => 1);
            Event   : Protocol.Backend_Message;
            Cancelled : Boolean := False;
         begin
            Begin_Query (Session, Channel);
            Channel.Blocked := True;
            declare
               Receive : Client.Receive_Operation :=
                 Client.Receive_Query_Event
                   (Set'Access, Session'Access, Timeout => 10.0);
            begin
               Operations.Cancel (Receive);
               begin
                  Client.Finish (Receive, Event);
               exception
                  when Operations.Operation_Cancelled =>
                     Cancelled := True;
               end;
            end;
            Assert
              (Cancelled and then not Channel.Engaged,
               "cancellation is retained until Finish and releases borrow");
         end;

         declare
            Channel : aliased Memory_Transport;
            Session : aliased Client.Session (Channel'Access);
            Set     : aliased Operations.Completion_Set (Capacity => 1);
            Event   : Protocol.Backend_Message;
            Failed  : Boolean := False;
         begin
            Begin_Query (Session, Channel);
            Channel.Fail_Receive := True;
            declare
               Receive : Client.Receive_Operation :=
                 Client.Receive_Query_Event
                   (Set'Access, Session'Access, Timeout => 1.0);
            begin
               Assert
                 (Operations.Is_Terminal (Receive)
                  and then Operations.Outcome (Receive) = Operations.Failed,
                  "provider failure is retained as a terminal outcome");
               begin
                  Client.Finish (Receive, Event);
               exception
                  when Program_Error =>
                     Failed := True;
               end;
            end;
            Assert
              (Failed and then not Channel.Engaged,
               "Finish reraises the retained provider failure");
         end;

         declare
            Channel : aliased Memory_Transport;
            Session : aliased Client.Session (Channel'Access);
            Set     : aliased Operations.Completion_Set (Capacity => 1);
         begin
            Begin_Query (Session, Channel);
            Channel.Blocked := True;
            declare
               Receive : Client.Receive_Operation :=
                 Client.Receive_Query_Event
                   (Set'Access, Session'Access, Timeout => 10.0);
               pragma Unreferenced (Receive);
            begin
               Assert (Channel.Engaged, "pending operation owns capability");
            end;
            Assert
              (not Channel.Engaged,
               "scope-exit finalization cancels and releases capability");
         end;
      end Test_Timeout_Cancel_Failure_And_Cleanup;

   begin
      Test_Startup_Operations;
      Test_Partial_And_Gates;
      Test_Counted_Multiple_Connections;
      Test_Extended_Operations;
      Test_Timeout_Cancel_Failure_And_Cleanup;
   end Test_Composable_Client_Operations;

   procedure Test_RFC_7677_SCRAM_SHA_256 is
      package SCRAM renames Flyology.Postgres.SCRAM;
      Client_Nonce : constant String := "rOprNGfwEbeRWgbNEkqO";
      Combined_Nonce : constant String :=
        "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
      Server_First : constant String :=
        "r=" & Combined_Nonce
        & ",s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
      Expected_Client_Final : constant String :=
        "c=biws,r=" & Combined_Nonce
        & ",p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
      Expected_Server_Final : constant String :=
        "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";
      Bare : constant String :=
        SCRAM.Client_First_Bare ("user", Client_Nonce);
      Signature : SCRAM.Digest;
      Final_Message : constant String :=
        SCRAM.Client_Final_Message
          ("pencil",
           Bare,
           Server_First,
           Client_Nonce,
           Signature);
      Credential : constant SCRAM.Verifier :=
        SCRAM.Parse_Verifier
          (SCRAM.Make_Verifier_Raw
             ("pencil",
              SCRAM.Base64_Decode ("W22ZaJ0SNY7soEsUEjb6gQ==")));
      Server_Signature : SCRAM.Digest;
      Valid : Boolean;
   begin
      Assert
        (Final_Message = Expected_Client_Final,
         "RFC 7677 client proof matches the published vector");
      SCRAM.Verify_Server_Final (Expected_Server_Final, Signature);
      SCRAM.Verify_Client_Final
        (Credential,
         Bare,
         Server_First,
         Combined_Nonce,
         Expected_Client_Final,
         Server_Signature,
         Valid);
      Assert (Valid, "RFC 7677 client proof is accepted");
      Assert
        (SCRAM.Base64_Encode
           (SCRAM.Byte_Array (Server_Signature)) =
           Expected_Server_Final (3 .. Expected_Server_Final'Last),
         "RFC 7677 server signature matches the published vector");
      SCRAM_Core.Wipe (Signature);
      SCRAM_Core.Wipe (Server_Signature);
   end Test_RFC_7677_SCRAM_SHA_256;

   procedure Test_SCRAM_Failures is
      package SCRAM renames Flyology.Postgres.SCRAM;
      Client_Nonce : constant String := "rOprNGfwEbeRWgbNEkqO";
      Combined_Nonce : constant String := Client_Nonce & "-server";
      Server_First : constant String :=
        "r=" & Combined_Nonce & ",s=U2FsdGVkU2FsdA==,i=4096";
      Bare : constant String :=
        SCRAM.Client_First_Bare ("user", Client_Nonce);
      Correct : constant SCRAM.Verifier :=
        SCRAM.Parse_Verifier
          (SCRAM.Make_Verifier_Raw
             ("correct", SCRAM.Base64_Decode ("U2FsdGVkU2FsdA==")));
      Signature : SCRAM.Digest;
      Wrong_Final : constant String :=
        SCRAM.Client_Final_Message
          ("wrong",
           Bare,
           Server_First,
           Client_Nonce,
           Signature);
      Wrong_Rejected : Boolean := False;
      Malformed_Rejected : Boolean := False;
      Verifier_Rejected : Boolean := False;
      Nonce_Rejected : Boolean := False;
      GS2_Rejected : Boolean := False;
      Y_Header_Accepted : Boolean := False;
      Valid : Boolean;
   begin
      SCRAM.Verify_Client_Final
        (Correct,
         Bare,
         Server_First,
         Combined_Nonce,
         Wrong_Final,
         Signature,
         Valid);
      Wrong_Rejected := not Valid;

      begin
         SCRAM.Verify_Server_Final ("v=not-base64", Signature);
      exception
         when SCRAM.SCRAM_Error =>
            Malformed_Rejected := True;
      end;

      begin
         declare
            Ignored : constant String :=
              SCRAM.Client_Final_Message
                ("correct",
                 Bare,
                 "r=unrelated-server-nonce,s=U2FsdGVkU2FsdA==,i=4096",
                 Client_Nonce,
                 Signature);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when SCRAM.SCRAM_Error =>
            Nonce_Rejected := True;
      end;

      Y_Header_Accepted :=
        SCRAM.Bare_From_Client_First
          ("y,,n=user,r=" & Client_Nonce) = "n=user,r=" & Client_Nonce
        and then SCRAM.Channel_Binding_From_Client_First
          ("y,,n=user,r=" & Client_Nonce) = "eSws";

      begin
         declare
            Ignored : constant String :=
              SCRAM.Bare_From_Client_First
                ("p=tls-server-end-point,,n=user,r=" & Client_Nonce);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when SCRAM.SCRAM_Error =>
            GS2_Rejected := True;
      end;

      begin
         declare
            Ignored : constant SCRAM.Verifier :=
              SCRAM.Parse_Verifier
                ("SCRAM-SHA-256$4096:bad$bad:bad");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when SCRAM.SCRAM_Error =>
            Verifier_Rejected := True;
      end;

      Assert (Wrong_Rejected, "wrong SCRAM passwords are rejected");
      Assert
        (Malformed_Rejected,
         "malformed SCRAM server-final messages are rejected");
      Assert
        (Verifier_Rejected,
         "malformed Postgres SCRAM verifiers are rejected");
      Assert (Nonce_Rejected, "mismatched server nonces are rejected");
      Assert
        (GS2_Rejected,
         "unsupported channel-binding client messages are rejected");
      Assert
        (Y_Header_Accepted,
         "non-binding clients that support channel binding are accepted");
      SCRAM_Core.Wipe (Signature);
   end Test_SCRAM_Failures;

   procedure Test_Raw_Password_Boundary is
      package SCRAM renames Flyology.Postgres.SCRAM;
      Salt : constant SCRAM.Byte_Array := SCRAM.To_Bytes ("fixed salt");
      NFC : constant String :=
        String'(1 => Character'Val (16#C3#),
                2 => Character'Val (16#A9#));
      NFD : constant String :=
        String'(1 => 'e',
                2 => Character'Val (16#CC#),
                3 => Character'Val (16#81#));
   begin
      Assert
        (SCRAM.Make_Verifier_Raw (NFC, Salt) /=
         SCRAM.Make_Verifier_Raw (NFD, Salt),
         "canonically equivalent UTF-8 stays distinct without SASLprep");
   end Test_Raw_Password_Boundary;

begin
   Test_Startup;
   Test_SSL_Request;
   Test_TLS_Refusal_Is_Terminal;
   Test_Message;
   Test_All_Frontend_Commands;
   Test_Malformed_String;
   Test_Proved_Wire_Core;
   Test_Variable_Cancellation_Key;
   Test_Invalid_Cancellation_Key_Length;
   Test_Malformed_Startup;
   Test_Typed_Row_Messages;
   Test_Typed_Query_Events;
   Test_Extended_Frontend_Messages;
   Test_Extended_Backend_Messages;
   Test_Copy_Protocol;
   Test_Negotiate_Protocol_Version;
   Test_Copy_Client_State;
   Test_Base_Backup_Client_State;
   Test_Extended_Client_State;
   Test_Pipelined_Client_State;
   Test_Malformed_Backend_Messages;
   Test_Composable_Client_Operations;
   Test_RFC_7677_SCRAM_SHA_256;
   Test_SCRAM_Failures;
   Test_Raw_Password_Boundary;
   Replication_Tests.Run;
   Ada.Text_IO.Put_Line ("all Flyology Postgres unit tests passed");
end Tests;
