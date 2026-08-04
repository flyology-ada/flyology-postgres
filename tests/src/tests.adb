with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with Flyology.Postgres.Wire;

procedure Tests is

   package Protocol renames Flyology.Postgres.Protocol;
   package SCRAM_Core renames Flyology.Postgres.SCRAM_Core;

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Field_Format;
   use type Protocol.Frontend_Kind;
   use type Protocol.Initial_Kind;
   use type Protocol.Int16;
   use type Protocol.Int32;
   use type Protocol.Transaction_Status;
   use type Protocol.UInt16;
   use type Protocol.UInt32;
   use type Ada.Streams.Stream_Element_Array;

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
      Data     : Protocol.Byte_Array (-3 .. 0) := (others => 0);
      Found    : Boolean;
      Position : Wire.Wire_Length;
      Cursor   : Wire.Wire_Length;
      Value16  : Wire.UInt16;
      Success  : Boolean;
      View     : Wire.Byte_View;
   begin
      Wire.Encode_U32 (Data, Position => 0, Value => 16#1234_ABCD#);
      Assert
        (Wire.Decode_U32 (Data, Position => 0) = 16#1234_ABCD#,
         "proved endian primitives handle arbitrary array bounds");

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
   end Test_Malformed_Backend_Messages;

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
         "malformed PostgreSQL SCRAM verifiers are rejected");
      Assert (Nonce_Rejected, "mismatched server nonces are rejected");
      Assert
        (GS2_Rejected,
         "unsupported channel-binding client messages are rejected");
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
   Test_Message;
   Test_All_Frontend_Commands;
   Test_Malformed_String;
   Test_Proved_Wire_Core;
   Test_Variable_Cancellation_Key;
   Test_Invalid_Cancellation_Key_Length;
   Test_Malformed_Startup;
   Test_Typed_Row_Messages;
   Test_Typed_Query_Events;
   Test_Malformed_Backend_Messages;
   Test_RFC_7677_SCRAM_SHA_256;
   Test_SCRAM_Failures;
   Test_Raw_Password_Boundary;
   Ada.Text_IO.Put_Line ("all Flyology Postgres unit tests passed");
end Tests;
