with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Wire;

procedure Tests is

   package Protocol renames Flyology.Postgres.Protocol;

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;
   use type Protocol.Initial_Kind;
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
      use type Wire.UInt16;
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
   end Test_Proved_Wire_Core;

   procedure Test_Variable_Cancellation_Key is
      Contents : Flyology.Bytes.Unbounded_Bytes;
      Secret   : constant Protocol.Byte_Array (1 .. 8) :=
        (1 => 16#10#,
         2 => 16#20#,
         3 => 16#30#,
         4 => 16#40#,
         5 => 16#50#,
         6 => 16#60#,
         7 => 16#70#,
         8 => 16#80#);
   begin
      Protocol.Append_U32 (Contents, 80_877_102);
      Protocol.Append_U32 (Contents, 42);
      Protocol.Append_Bytes (Contents, Secret);
      declare
         Initial : constant Protocol.Initial_Request :=
           Protocol.Decode_Initial (Flyology.Bytes.To_Array (Contents));
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

begin
   Test_Startup;
   Test_Message;
   Test_All_Frontend_Commands;
   Test_Malformed_String;
   Test_Proved_Wire_Core;
   Test_Variable_Cancellation_Key;
   Test_Malformed_Startup;
   Ada.Text_IO.Put_Line ("all Flyology Postgres unit tests passed");
end Tests;
