with Ada.Streams;
with Ada.Unchecked_Conversion;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Logical;
with Interfaces;

package body Replication_Tests is

   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Logical renames Flyology.Postgres.Replication.Logical;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Logical.Message_Kind;
   use type Logical.Message_Level;
   use type Logical.Int32;
   use type Logical.Old_Tuple_Kind;
   use type Logical.Replica_Identity;
   use type Logical.Streaming_Mode;
   use type Logical.Tuple_Value_Kind;
   use type Protocol.Byte_Offset;
   use type Protocol.Replication_Connection_Mode;
   use type Protocol.UInt32;
   use type Replication.Int64;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Replication.Stream_Message_Kind;

   function To_UInt64 is new Ada.Unchecked_Conversion
     (Source => Replication.Int64, Target => Replication.UInt64);

   procedure Append_U64
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication.UInt64) is
   begin
      Protocol.Append_U32
        (Target,
         Protocol.UInt32 (Interfaces.Shift_Right (Value, 32)));
      Protocol.Append_U32
        (Target, Protocol.UInt32 (Value and 16#FFFF_FFFF#));
   end Append_U64;

   procedure Append_Time
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication.Replication_Timestamp) is
   begin
      Append_U64 (Target, To_UInt64 (Value));
   end Append_Time;

   function Logical_Message
     (Tag      : Character;
      Contents : Flyology.Bytes.Unbounded_Bytes) return Logical.Byte_Array is
      Result : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_Byte
        (Result, Protocol.Byte (Character'Pos (Tag)));
      Protocol.Append_Bytes
        (Result, Flyology.Bytes.To_Array (Contents));
      return Flyology.Bytes.To_Array (Result);
   end Logical_Message;

   function Empty_Logical_Message (Tag : Character)
      return Logical.Byte_Array is
      Empty : Flyology.Bytes.Unbounded_Bytes;
   begin
      return Logical_Message (Tag, Empty);
   end Empty_Logical_Message;

   function Query_Text (Item : Protocol.Message) return String is
      Data : constant Protocol.Byte_Array := Protocol.Payload (Item);
   begin
      Assert
        (Protocol.Code (Item) = 'Q' and then Data (Data'Last) = 0,
         "replication commands use simple Query framing");
      return Flyology.Bytes.To_Byte_String
        (Flyology.Bytes.To_Unbounded_Bytes
           (Data (Data'First .. Data'Last - 1)));
   end Query_Text;

   function Query (Text : String) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Text);
      return Protocol.Make_Message
        ('Q', Flyology.Bytes.To_Array (Contents));
   end Query;

   procedure Assert_Command_Rejected (Text : String) is
      Rejected : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Replication.Command :=
              Replication.Decode_Command (Query (Text));
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "malformed replication command is rejected");
   end Assert_Command_Rejected;

   procedure Assert_Rejected
     (Data      : Logical.Byte_Array;
      Version   : Logical.Protocol_Version;
      Streamed  : Boolean := False;
      Streaming : Logical.Streaming_Mode := Logical.Disabled) is
      Rejected : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Logical.Message :=
              Logical.Decode (Data, Version, Streamed, Streaming);
         begin
            Assert
              (Logical.Kind (Ignored) = Logical.Begin_Message,
               "unreachable malformed logical message");
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "malformed logical message is rejected");
   end Assert_Rejected;

   procedure Test_Commands_And_LSN is
      Options : constant Replication.Logical_Option_Array :=
        (Replication.Option ("proto_version", "4"),
         Replication.Option ("publication_names", "one'pub"),
         Replication.Option ("messages"),
         Replication.Option ("custom_empty", ""));

      procedure Check_Startup
        (Mode : Protocol.Replication_Connection_Mode) is
         Packet : constant Protocol.Byte_Array := Protocol.Encode_Startup
           (User             => "replicator",
            Database         => "example",
            Replication_Mode => Mode);
         Cursor : Protocol.Byte_Offset := Packet'First;
         Length : constant Protocol.UInt32 :=
           Protocol.Read_U32 (Packet, Cursor);
         Request : constant Protocol.Initial_Request :=
           Protocol.Decode_Initial (Packet (Cursor .. Packet'Last));
      begin
         Assert
           (Length = Protocol.UInt32 (Packet'Length)
            and then Protocol.Startup_Data (Request).Replication_Mode = Mode,
            "replication startup mode round-trips");
      end Check_Startup;
   begin
      Assert
        (Replication.Image (16#16_B374_D848#) = "16/B374D848",
         "LSNs format as two hexadecimal halves");
      Assert
        (Replication.Value ("16/b374d848") = 16#16_B374_D848#,
         "LSNs parse case-insensitively");
      Assert
        (Query_Text (Replication.Identify_System) = "IDENTIFY_SYSTEM",
         "IDENTIFY_SYSTEM command is typed");
      Assert
        (Query_Text (Replication.Show ("wal_level")) = "SHOW wal_level",
         "replication SHOW command is typed");
      Assert
        (Query_Text (Replication.Timeline_History (7)) =
           "TIMELINE_HISTORY 7",
         "timeline history command is typed");
      Assert
        (Query_Text
           (Replication.Start_Physical
              (16#16_B374_D848#,
               Slot_Name => "standby_1",
               Timeline  => 7)) =
           "START_REPLICATION SLOT standby_1 PHYSICAL 16/B374D848"
           & " TIMELINE 7",
         "physical replication command includes slot and timeline");
      Assert
        (Query_Text
           (Replication.Start_Logical
              ("subscriber_1", 16#16_B374_D848#, Options)) =
           "START_REPLICATION SLOT subscriber_1 LOGICAL 16/B374D848"
           & " (proto_version '4', publication_names 'one''pub',"
           & " messages, custom_empty '')",
         "valued, valueless, and empty logical options remain distinct");

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Start_Physical
              (16#16_B374_D848#,
               Slot_Name => "standby_1",
               Timeline  => 7));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Start_Physical_Command
            and then Replication.Slot_Name (Item) = "standby_1"
            and then Replication.Position (Item) = 16#16_B374_D848#
            and then Replication.Has_Timeline (Item)
            and then Replication.Timeline (Item) = 7,
            "primary-side decoding exposes physical start fields");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Start_Logical
              ("subscriber_1", 16#16_B374_D848#, Options));
         Parsed : constant Replication.Logical_Option_Array :=
           Replication.Options (Item);
      begin
         Assert
           (Replication.Kind (Item) = Replication.Start_Logical_Command
            and then Replication.Slot_Name (Item) = "subscriber_1"
            and then Replication.Position (Item) = 16#16_B374_D848#
            and then Parsed'Length = 4
            and then Replication.Option_Value (Parsed (2)) = "one'pub"
            and then not Replication.Option_Has_Value (Parsed (3))
            and then Replication.Option_Has_Value (Parsed (4))
            and then Replication.Option_Value (Parsed (4)) = "",
            "primary-side decoding preserves logical options");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Identify_System);
      begin
         Assert
           (Replication.Kind (Item) = Replication.Identify_System_Command,
            "primary-side decoding classifies IDENTIFY_SYSTEM");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Show ("wal_level"));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Show_Command
            and then Replication.Parameter (Item) = "wal_level",
            "primary-side decoding exposes SHOW parameters");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Timeline_History (7));
      begin
         Assert
           (Replication.Kind (Item) =
              Replication.Timeline_History_Command
            and then Replication.Timeline (Item) = 7,
            "primary-side decoding exposes timeline history requests");
      end;
      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Query
              (ASCII.LF & "start_replication" & ASCII.HT
               & "physical 16/B374D848" & ASCII.CR));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Start_Physical_Command
            and then Replication.Position (Item) = 16#16_B374_D848#,
            "primary-side decoding accepts PostgreSQL whitespace");
      end;
      Assert_Command_Rejected ("select 1");
      Assert_Command_Rejected
        ("START_REPLICATION SLOT subscriber_1 LOGICAL 0/0"
         & " (proto_version '4' trailing)");
      Check_Startup (Protocol.Physical_Replication_Connection);
      Check_Startup (Protocol.Logical_Replication_Connection);
   end Test_Commands_And_LSN;

   procedure Test_Physical_Messages is
      Bytes : constant Protocol.Byte_Array (1 .. 4) :=
        (1 => 0, 2 => 1, 3 => 16#FE#, 4 => 16#FF#);
   begin
      declare
         Item : constant Replication.Stream_Message := Replication.Decode
           (Replication.Make_XLog_Data
              (16#100#, 16#200#, -12, Bytes));
      begin
         Assert
           (Replication.Kind (Item) = Replication.XLog_Data
            and then Replication.WAL_Start (Item) = 16#100#
            and then Replication.WAL_End (Item) = 16#200#
            and then Replication.Sent_At (Item) = -12
            and then Replication.Data (Item) = Bytes,
            "XLogData round-trips its header and arbitrary WAL bytes");
      end;

      declare
         Item : constant Replication.Stream_Message := Replication.Decode
           (Replication.Make_Primary_Keepalive
              (16#300#, 99, Reply_Requested => True));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Primary_Keepalive
            and then Replication.WAL_End (Item) = 16#300#
            and then Replication.Reply_Requested (Item),
            "PrimaryKeepalive round-trips its reply request");
      end;

      declare
         Item : constant Replication.Stream_Message := Replication.Decode
           (Replication.Make_Standby_Status_Update
              (16#10#, 16#20#, 16#30#, 100, True));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Standby_Status_Update
            and then Replication.Received_LSN (Item) = 16#10#
            and then Replication.Flushed_LSN (Item) = 16#20#
            and then Replication.Applied_LSN (Item) = 16#30#
            and then Replication.Reply_Requested (Item),
            "StandbyStatusUpdate round-trips all progress positions");
      end;

      declare
         Item : constant Replication.Stream_Message := Replication.Decode
           (Replication.Make_Hot_Standby_Feedback
              (101, 4, 5, 6, 7));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Hot_Standby_Feedback
            and then Replication.Feedback_Xmin (Item) = 4
            and then Replication.Feedback_Xmin_Epoch (Item) = 5
            and then Replication.Feedback_Catalog_Xmin (Item) = 6
            and then Replication.Feedback_Catalog_Xmin_Epoch (Item) = 7,
            "HotStandbyFeedback round-trips xid epochs");
      end;
   end Test_Physical_Messages;

   procedure Test_Logical_Transaction_Messages is
      Seen : array (Logical.Message_Kind) of Boolean := (others => False);

      procedure Mark (Item : Logical.Message) is
      begin
         Seen (Logical.Kind (Item)) := True;
      end Mark;

      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_U64 (Contents, 16#101#);
      Append_Time (Contents, 10);
      Protocol.Append_U32 (Contents, 42);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('B', Contents), 1);
      begin
         Mark (Item);
         Assert
           (Logical.Final_LSN (Item) = 16#101#
            and then Logical.Event_Timestamp (Item) = 10
            and then Logical.Transaction (Item) = 42,
            "Begin decodes transaction-level fields");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_Byte (Contents, 0);
      Append_U64 (Contents, 16#102#);
      Append_U64 (Contents, 16#103#);
      Append_Time (Contents, 11);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('C', Contents), 1);
      begin
         Mark (Item);
         Assert
           (Logical.Commit_LSN (Item) = 16#102#
            and then Logical.End_LSN (Item) = 16#103#,
            "Commit decodes commit and end positions");
      end;

      Flyology.Bytes.Clear (Contents);
      Append_U64 (Contents, 16#104#);
      Protocol.Append_C_String (Contents, "upstream");
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('O', Contents), 1);
      begin
         Mark (Item);
         Assert
           (Logical.Origin_Commit_LSN (Item) = 16#104#
            and then Logical.Origin_Name (Item) = "upstream",
            "Origin decodes its commit position and name");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_Byte (Contents, 1);
      Append_U64 (Contents, 16#105#);
      Protocol.Append_C_String (Contents, "audit");
      Protocol.Append_U32 (Contents, 3);
      Protocol.Append_Bytes (Contents, (1 => 0, 2 => 1, 3 => 2));
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('M', Contents), 1);
      begin
         Mark (Item);
         Assert
           (Logical.Level (Item) = Logical.Transaction_Metadata
            and then Logical.Is_Transactional (Item)
            and then Logical.Message_LSN (Item) = 16#105#
            and then Logical.Prefix (Item) = "audit"
            and then Logical.Content (Item) =
              Protocol.Byte_Array'(1 => 0, 2 => 1, 3 => 2),
            "logical decoding Message preserves binary content");
      end;

      Flyology.Bytes.Clear (Contents);
      Append_U64 (Contents, 16#201#);
      Append_U64 (Contents, 16#202#);
      Append_Time (Contents, 20);
      Protocol.Append_U32 (Contents, 50);
      Protocol.Append_C_String (Contents, "gid-50");
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('b', Contents), 3);
      begin
         Mark (Item);
         Assert
           (Logical.Prepare_LSN (Item) = 16#201#
            and then Logical.End_LSN (Item) = 16#202#
            and then Logical.GID (Item) = "gid-50",
            "BeginPrepare decodes two-phase identity and positions");
      end;

      for Tag of String'("PK") loop
         Flyology.Bytes.Clear (Contents);
         Protocol.Append_Byte (Contents, 0);
         Append_U64 (Contents, 16#203#);
         Append_U64 (Contents, 16#204#);
         Append_Time (Contents, 21);
         Protocol.Append_U32 (Contents, 51);
         Protocol.Append_C_String (Contents, "gid-51");
         declare
            Item : constant Logical.Message := Logical.Decode
              (Logical_Message (Tag, Contents), 3);
         begin
            Mark (Item);
            Assert
              (Logical.GID (Item) = "gid-51",
               "Prepare and CommitPrepared decode their GID");
         end;
      end loop;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_Byte (Contents, 0);
      Append_U64 (Contents, 16#205#);
      Append_U64 (Contents, 16#206#);
      Append_Time (Contents, 22);
      Append_Time (Contents, 23);
      Protocol.Append_U32 (Contents, 52);
      Protocol.Append_C_String (Contents, "gid-52");
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('r', Contents), 3);
      begin
         Mark (Item);
         Assert
           (Logical.Rollback_Timestamp (Item) = 23,
            "RollbackPrepared decodes both timestamps");
      end;

      Assert
        (Seen (Logical.Begin_Message)
         and then Seen (Logical.Commit_Message)
         and then Seen (Logical.Origin_Message)
         and then Seen (Logical.Logical_Decoding_Message)
         and then Seen (Logical.Begin_Prepare_Message)
         and then Seen (Logical.Prepare_Message)
         and then Seen (Logical.Commit_Prepared_Message)
         and then Seen (Logical.Rollback_Prepared_Message),
         "transaction and two-phase logical message kinds are covered");
   end Test_Logical_Transaction_Messages;

   procedure Test_Logical_Row_Messages is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_C_String (Contents, "public");
      Protocol.Append_C_String (Contents, "things");
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('i')));
      Protocol.Append_U16 (Contents, 2);
      Protocol.Append_Byte (Contents, 1);
      Protocol.Append_C_String (Contents, "id");
      Protocol.Append_U32 (Contents, 23);
      Protocol.Append_U32 (Contents, Protocol.UInt32'Last);
      Protocol.Append_Byte (Contents, 0);
      Protocol.Append_C_String (Contents, "payload");
      Protocol.Append_U32 (Contents, 25);
      Protocol.Append_U32 (Contents, Protocol.UInt32'Last);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('R', Contents), 1);
         First : constant Logical.Relation_Column :=
           Logical.Relation_Column_At (Item, 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Relation_Message
            and then Logical.Relation_Id (Item) = 90
            and then Logical.Namespace_Name (Item) = "public"
            and then Logical.Object_Name (Item) = "things"
            and then Logical.Identity (Item) = Logical.Index_Identity
            and then Logical.Relation_Column_Count (Item) = 2
            and then Logical.Is_Key (First)
            and then Logical.Name (First) = "id"
            and then Logical.Type_Oid (First) = 23
            and then Logical.Type_Modifier (First) = -1,
            "Relation decodes published columns and replica identity");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 91);
      Protocol.Append_C_String (Contents, "public");
      Protocol.Append_C_String (Contents, "custom_type");
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('Y', Contents), 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Type_Message
            and then Logical.Relation_Id (Item) = 91,
            "Type decodes its OID and names");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('N')));
      Protocol.Append_U16 (Contents, 4);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('n')));
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('u')));
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('t')));
      Protocol.Append_U32 (Contents, 3);
      Protocol.Append_Bytes
        (Contents,
         (1 => Protocol.Byte (Character'Pos ('a')),
          2 => Protocol.Byte (Character'Pos ('b')),
          3 => Protocol.Byte (Character'Pos ('c'))));
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('b')));
      Protocol.Append_U32 (Contents, 2);
      Protocol.Append_Bytes (Contents, (1 => 0, 2 => 16#FF#));
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('I', Contents), 1);
         Tuple : constant Logical.Tuple_Data := Logical.New_Tuple (Item);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Insert_Message
            and then Logical.Level (Item) = Logical.Row_Change
            and then Logical.Column_Count (Tuple) = 4
            and then Logical.Kind (Logical.Column (Tuple, 1)) =
              Logical.Null_Value
            and then Logical.Kind (Logical.Column (Tuple, 2)) =
              Logical.Unchanged_Toast_Value
            and then Logical.Text (Logical.Column (Tuple, 3)) = "abc"
            and then Logical.Value (Logical.Column (Tuple, 4)) =
              Protocol.Byte_Array'(1 => 0, 2 => 16#FF#),
            "Insert decodes all TupleData value forms");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('K')));
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('t')));
      Protocol.Append_U32 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('1')));
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('N')));
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('t')));
      Protocol.Append_U32 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('2')));
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('U', Contents), 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Update_Message
            and then Logical.Old_Kind (Item) = Logical.Key_Old_Tuple
            and then Logical.Text
              (Logical.Column (Logical.Old_Tuple (Item), 1)) = "1"
            and then Logical.Text
              (Logical.Column (Logical.New_Tuple (Item), 1)) = "2",
            "Update distinguishes key and new tuples");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('O')));
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('n')));
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('D', Contents), 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Delete_Message
            and then Logical.Old_Kind (Item) = Logical.Full_Old_Tuple,
            "Delete distinguishes a full old tuple");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 2);
      Protocol.Append_Byte (Contents, 3);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_U32 (Contents, 91);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Logical_Message ('T', Contents), 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Truncate_Message
            and then Logical.Truncated_Relation_Count (Item) = 2
            and then Logical.Truncated_Relation (Item, 2) = 91
            and then Logical.Cascade (Item)
            and then Logical.Restart_Identity (Item),
            "Truncate decodes all relation IDs and option bits");
      end;
   end Test_Logical_Row_Messages;

   procedure Test_Logical_Streaming is
      Decoder  : Logical.Decoder;
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Assert
        (Logical.Minimum_Server_Major (1) = 10
         and then Logical.Minimum_Server_Major (2) = 14
         and then Logical.Minimum_Server_Major (3) = 15
         and then Logical.Minimum_Server_Major (4) = 16,
         "logical protocol versions expose their server compatibility");
      Assert
        (not Logical.Configuration_Is_Valid (1, Logical.In_Progress)
         and then not Logical.Configuration_Is_Valid (3, Logical.Parallel)
         and then Logical.Configuration_Is_Valid (4, Logical.Parallel),
         "logical streaming modes enforce protocol capabilities");

      Logical.Configure (Decoder, 4, Logical.Parallel);
      Protocol.Append_U32 (Contents, 100);
      Protocol.Append_Byte (Contents, 1);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('S', Contents));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Stream_Start_Message
            and then Logical.Is_First_Stream_Segment (Item)
            and then Logical.Inside_Stream (Decoder),
            "StreamStart enters an in-progress transaction segment");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 100);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('N')));
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('n')));
      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('I', Contents));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Insert_Message
            and then Logical.Is_Streamed (Item)
            and then Logical.Transaction (Item) = 100,
            "within-stream row changes decode their transaction ID");
      end;

      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Empty_Logical_Message ('E'));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Stream_Stop_Message
            and then not Logical.Inside_Stream (Decoder),
            "StreamStop exits an in-progress transaction segment");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 100);
      Protocol.Append_Byte (Contents, 0);
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('S', Contents));
      begin
         Assert
           (Logical.Kind (Ignored) = Logical.Stream_Start_Message,
            "a later stream segment starts");
      end;
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Empty_Logical_Message ('E'));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 100);
      Protocol.Append_Byte (Contents, 0);
      Append_U64 (Contents, 16#301#);
      Append_U64 (Contents, 16#302#);
      Append_Time (Contents, 30);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('c', Contents));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Stream_Commit_Message
            and then Logical.Commit_LSN (Item) = 16#301#
            and then not Logical.Inside_Stream (Decoder),
            "StreamCommit completes an in-progress transaction");
      end;

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 101);
      Protocol.Append_Byte (Contents, 1);
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('S', Contents));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Empty_Logical_Message ('E'));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 101);
      Protocol.Append_U32 (Contents, 102);
      Append_U64 (Contents, 16#303#);
      Append_Time (Contents, 31);
      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('A', Contents));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Stream_Abort_Message
            and then Logical.Subtransaction (Item) = 102
            and then Logical.Abort_LSN (Item) = 16#303#
            and then Logical.Event_Timestamp (Item) = 31,
            "v4 parallel StreamAbort decodes abort metadata");
      end;

      Logical.Configure (Decoder, 3, Logical.In_Progress);
      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 103);
      Protocol.Append_Byte (Contents, 1);
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('S', Contents));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      declare
         Ignored : constant Logical.Message := Logical.Decode
           (Decoder, Empty_Logical_Message ('E'));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      Flyology.Bytes.Clear (Contents);
      Protocol.Append_Byte (Contents, 0);
      Append_U64 (Contents, 16#304#);
      Append_U64 (Contents, 16#305#);
      Append_Time (Contents, 32);
      Protocol.Append_U32 (Contents, 103);
      Protocol.Append_C_String (Contents, "stream-gid");
      declare
         Item : constant Logical.Message := Logical.Decode
           (Decoder, Logical_Message ('p', Contents));
      begin
         Assert
           (Logical.Kind (Item) = Logical.Stream_Prepare_Message
            and then Logical.GID (Item) = "stream-gid"
            and then not Logical.Inside_Stream (Decoder),
            "v3 StreamPrepare completes a streamed prepared transaction");
      end;
   end Test_Logical_Streaming;

   procedure Test_Logical_Encoding is
      Seen : array (Logical.Message_Kind) of Boolean := (others => False);
      Tuple : constant Logical.Tuple_Data := Logical.Make_Tuple
        ((Logical.Null_Column,
          Logical.Unchanged_Toast_Column,
          Logical.Text_Column ("text"),
          Logical.Binary_Column ((1 => 0, 2 => 16#FF#))));
      Columns : constant Logical.Relation_Column_Array :=
        (1 => Logical.Make_Relation_Column
           ("id", 23, Is_Key => True),
         2 => Logical.Make_Relation_Column ("payload", 25));

      procedure Check
        (Item      : Logical.Message;
         Version   : Logical.Protocol_Version;
         Streaming : Logical.Streaming_Mode := Logical.Disabled;
         Streamed  : Boolean := False) is
         Encoded : constant Logical.Byte_Array :=
           Logical.Encode (Item, Version, Streaming);
         Decoded : constant Logical.Message := Logical.Decode
           (Encoded, Version, Streamed, Streaming);
      begin
         Assert
           (Logical.Kind (Decoded) = Logical.Kind (Item),
            "logical constructor preserves its message kind");
         Assert
           (Logical.Encode (Decoded, Version, Streaming) = Encoded,
            "logical messages have a canonical encode/decode round trip");
         Seen (Logical.Kind (Item)) := True;
      end Check;
   begin
      Check (Logical.Make_Begin (1, 2, 3), 1);
      Check (Logical.Make_Commit (4, 5, 6), 1);
      Check (Logical.Make_Origin (7, "origin"), 1);
      Check
        (Logical.Make_Logical_Decoding_Message
           (8, "prefix", (1 => 1, 2 => 2), True),
         1);
      Check
        (Logical.Make_Relation
           (10, "public", "items", Logical.Default_Identity, Columns),
         1);
      Check (Logical.Make_Type (11, "public", "item_type"), 1);
      Assert
        (Logical.Type_Id
           (Logical.Make_Type (11, "public", "item_type")) = 11,
         "Type exposes its type OID");
      Check (Logical.Make_Insert (10, Tuple), 1);
      Check
        (Logical.Make_Update
           (10, Tuple, Logical.Key_Old_Tuple, Tuple),
         1);
      Check
        (Logical.Make_Delete
           (10, Logical.Full_Old_Tuple, Tuple),
         1);
      Check
        (Logical.Make_Truncate ((10, 11), True, True), 1);

      Check
        (Logical.Make_Stream_Start (20, True),
         2,
         Logical.In_Progress);
      Check
        (Logical.Make_Stream_Stop, 2, Logical.In_Progress);
      Check
        (Logical.Make_Stream_Commit (20, 21, 22, 23),
         2,
         Logical.In_Progress);
      Check
        (Logical.Make_Stream_Abort (20, 20),
         2,
         Logical.In_Progress);
      Check
        (Logical.Make_Insert (10, Tuple, Xid => 20),
         2,
         Logical.In_Progress,
         Streamed => True);

      Check
        (Logical.Make_Begin_Prepare (30, 31, 32, 33, "gid-33"), 3);
      Check
        (Logical.Make_Prepare (34, 35, 36, 37, "gid-37"), 3);
      Check
        (Logical.Make_Commit_Prepared (38, 39, 40, 41, "gid-41"), 3);
      Check
        (Logical.Make_Rollback_Prepared
           (42, 43, 44, 45, 46, "gid-46"),
         3);
      Assert
        (Logical.Prepare_End_LSN
           (Logical.Make_Rollback_Prepared
              (42, 43, 44, 45, 46, "gid-46")) = 42,
         "RollbackPrepared exposes its prepare end LSN");
      Check
        (Logical.Make_Stream_Prepare (47, 48, 49, 50, "gid-50"),
         3,
         Logical.In_Progress);
      Check
        (Logical.Make_Stream_Abort (51, 52, 53, 54),
         4,
         Logical.Parallel);

      for Kind in Logical.Message_Kind loop
         Assert
           (Seen (Kind),
            "logical encoder covers " & Logical.Message_Kind'Image (Kind));
      end loop;
   end Test_Logical_Encoding;

   procedure Test_Logical_Failures is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, 1);
      Protocol.Append_Byte (Contents, 1);
      Assert_Rejected
        (Logical_Message ('S', Contents),
         Version   => 1,
         Streaming => Logical.Disabled);

      Flyology.Bytes.Clear (Contents);
      Append_U64 (Contents, 1);
      Append_U64 (Contents, 2);
      Append_Time (Contents, 3);
      Protocol.Append_U32 (Contents, 4);
      Protocol.Append_C_String (Contents, "gid");
      Assert_Rejected (Logical_Message ('b', Contents), Version => 2);

      Flyology.Bytes.Clear (Contents);
      Protocol.Append_U32 (Contents, 90);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('N')));
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_Byte
        (Contents, Protocol.Byte (Character'Pos ('x')));
      Assert_Rejected (Logical_Message ('I', Contents), Version => 1);

      Assert_Rejected
        (Empty_Logical_Message ('?'), Version => 4,
         Streaming => Logical.Parallel);
   end Test_Logical_Failures;

   procedure Run is
   begin
      Test_Commands_And_LSN;
      Test_Physical_Messages;
      Test_Logical_Transaction_Messages;
      Test_Logical_Row_Messages;
      Test_Logical_Streaming;
      Test_Logical_Encoding;
      Test_Logical_Failures;
   end Run;

end Replication_Tests;
