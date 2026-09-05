with Ada.Streams;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Base_Backups;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Logical.Producer;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Flyology.Postgres.Replication.Prepared_Consumer;
with Flyology.Postgres.Wire;
with Replication_Persistence_Conformance;

package body Replication_Tests is

   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Base_Backups renames
     Flyology.Postgres.Replication.Base_Backups;
   package Logical renames Flyology.Postgres.Replication.Logical;
   package Producer renames
     Flyology.Postgres.Replication.Logical.Producer;
   package Persistence renames
     Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   procedure Conformance_Check (Condition : Boolean; Reason : String) is
   begin
      Assert (Condition, "persistence conformance: " & Reason);
   end Conformance_Check;

   package Persistence_Conformance is new
     Replication_Persistence_Conformance (Check => Conformance_Check);

   use type Ada.Streams.Stream_Element_Array;

   type Target_Context is limited record
      Applications : Natural := 0;
      Last_XID     : Replication.Transaction_Id := 0;
   end record;

   procedure Apply_Target
     (Context    : in out Target_Context;
      Slot_Name : String;
      GID        : String;
      XID        : Replication.Transaction_Id;
      Payload    : Persistence.Byte_Array) is
   begin
      Assert
        (Slot_Name = "logical" and then GID = "gid-restart"
         and then Payload = Persistence.Byte_Array'(6, 5, 4),
         "prepared consumer preserves its application identity and payload");
      Context.Applications := Context.Applications + 1;
      Context.Last_XID := XID;
   end Apply_Target;

   package Prepared_Consumers is new
     Flyology.Postgres.Replication.Prepared_Consumer
       (Target_Context => Target_Context,
        Apply_Target   => Apply_Target);
   package Wire renames Flyology.Postgres.Wire;

   use type Ada.Streams.Stream_Element;
   use type Logical.Message_Kind;
   use type Logical.Message_Level;
   use type Logical.Int32;
   use type Logical.Old_Tuple_Kind;
   use type Logical.Replica_Identity;
   use type Logical.Streaming_Mode;
   use type Logical.Tuple_Value_Kind;
   use type Producer.Transaction_State;
   use type Protocol.Byte_Offset;
   use type Protocol.Replication_Connection_Mode;
   use type Protocol.UInt32;
   use type Replication.Int64;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Replication.Snapshot_Action;
   use type Replication.Stream_Message_Kind;
   use type Base_Backups.Backup_Target;
   use type Persistence.Acquire_Result;
   use type Persistence.Create_Result;
   use type Persistence.Prepared_Phase;
   use type Persistence.Slot_Kind;

   procedure Append_U64
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication.UInt64) is
      Data : Protocol.Byte_Array (1 .. 8);
   begin
      Wire.Encode_U64 (Data, Position => 0, Value => Value);
      Protocol.Append_Bytes (Target, Data);
   end Append_U64;

   procedure Append_Time
     (Target : in out Flyology.Bytes.Unbounded_Bytes;
      Value  : Replication.Replication_Timestamp) is
   begin
      Append_U64 (Target, Wire.To_UInt64_Bits (Value));
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
           (Replication.Create_Logical_Slot
              ("sync_slot", Snapshot => Replication.Use_Snapshot)) =
           "CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput"
           & " (SNAPSHOT 'use')",
         "logical slot creation command is typed");
      Assert
        (Query_Text
           (Replication.Create_Logical_Slot
              ("legacy_slot", Server_Major => 14)) =
           "CREATE_REPLICATION_SLOT legacy_slot LOGICAL pgoutput"
           & " EXPORT_SNAPSHOT",
         "PostgreSQL 14 logical slot creation uses legacy syntax");
      Assert
        (Query_Text
           (Replication.Create_Logical_Slot
              ("prepared_slot", Two_Phase => True)) =
           "CREATE_REPLICATION_SLOT prepared_slot LOGICAL pgoutput"
           & " (SNAPSHOT 'export', TWO_PHASE 'true')",
         "logical slot creation can enable two-phase decoding");
      Assert
        (Query_Text (Replication.Drop_Replication_Slot ("sync_slot", True)) =
           "DROP_REPLICATION_SLOT sync_slot WAIT",
         "replication slot drop command is typed");
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
           (Query
              ("CREATE_REPLICATION_SLOT ""sync_slot"" LOGICAL pgoutput"
               & " (SNAPSHOT 'use')"));
      begin
         Assert
           (Replication.Kind (Item) =
              Replication.Create_Logical_Slot_Command
            and then Replication.Slot_Name (Item) = "sync_slot"
            and then Replication.Plugin (Item) = "pgoutput"
            and then Replication.Snapshot (Item) =
              Replication.Use_Snapshot,
            "primary-side decoding exposes logical slot creation");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Create_Logical_Slot
              ("prepared_slot", Snapshot => Replication.No_Snapshot,
               Two_Phase => True));
      begin
         Assert
           (Replication.Snapshot (Item) = Replication.No_Snapshot
            and then Replication.Two_Phase (Item),
            "primary-side decoding exposes two-phase slot creation");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Replication.Create_Logical_Slot
              ("legacy_slot", Server_Major => 14));
      begin
         Assert
           (Replication.Snapshot (Item) = Replication.Export_Snapshot
            and then not Replication.Two_Phase (Item),
            "primary-side decoding accepts PostgreSQL 14 slot syntax");
      end;

      declare
         Item : constant Replication.Command := Replication.Decode_Command
           (Query ("DROP_REPLICATION_SLOT ""sync_slot"" WAIT"));
      begin
         Assert
           (Replication.Kind (Item) =
              Replication.Drop_Replication_Slot_Command
            and then Replication.Slot_Name (Item) = "sync_slot"
            and then Replication.Wait (Item),
            "primary-side decoding exposes replication slot drop");
      end;

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
           (Query
              ("START_REPLICATION SLOT ""standby_1"" PHYSICAL"
               & " 16/B374D848 TIMELINE 7"));
      begin
         Assert
           (Replication.Kind (Item) = Replication.Start_Physical_Command
            and then Replication.Slot_Name (Item) = "standby_1"
            and then Replication.Position (Item) = 16#16_B374_D848#,
            "primary-side decoding accepts PostgreSQL quoted slots");
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
           (Query
              ("START_REPLICATION SLOT flyology_output LOGICAL 0/0"
               & " (""proto_version"" '1',"
               & " ""publication_names"" 'flyology_publication')"));
         Parsed : constant Replication.Logical_Option_Array :=
           Replication.Options (Item);
      begin
         Assert
           (Parsed'Length = 2
            and then Replication.Option_Name (Parsed (1)) = "proto_version"
            and then Replication.Option_Name (Parsed (2)) =
              "publication_names",
            "primary-side decoding accepts libpq quoted option names");
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
      Assert_Command_Rejected
        ("CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput"
         & " (TWO_PHASE)");
      Assert_Command_Rejected
        ("CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput"
         & " (SNAPSHOT 'use', SNAPSHOT 'nothing')");
      Check_Startup (Protocol.Physical_Replication_Connection);
      Check_Startup (Protocol.Logical_Replication_Connection);
   end Test_Commands_And_LSN;

   procedure Test_Base_Backup_Commands is
      Legacy : Base_Backups.Options := Base_Backups.Defaults (14);
      Modern : Base_Backups.Options := Base_Backups.Defaults (15);
      Incremental : Base_Backups.Options := Base_Backups.Defaults (17);
      Empty_Label : Base_Backups.Options := Base_Backups.Defaults (14);
      Rejected : Boolean := False;
   begin
      Base_Backups.Set_Label (Empty_Label, "");
      Assert
        (Query_Text (Base_Backups.Command (Empty_Label)) =
           "BASE_BACKUP LABEL ''",
         "an explicitly empty backup label is preserved");

      Base_Backups.Set_Label (Legacy, "night's backup");
      Base_Backups.Set_Progress (Legacy);
      Base_Backups.Set_Checkpoint
        (Legacy, Base_Backups.Fast_Checkpoint);
      Base_Backups.Include_WAL (Legacy);
      Base_Backups.Wait_For_Archive (Legacy, False);
      Base_Backups.Set_Maximum_Rate (Legacy, 32);
      Base_Backups.Include_Tablespace_Map (Legacy);
      Base_Backups.Verify_Checksums (Legacy, False);
      Base_Backups.Set_Manifest
        (Legacy, Base_Backups.Include_Manifest,
         Base_Backups.SHA256_Checksum);
      Assert
        (Query_Text (Base_Backups.Command (Legacy)) =
           "BASE_BACKUP LABEL 'night''s backup' PROGRESS FAST WAL NOWAIT"
           & " MAX_RATE 32 TABLESPACE_MAP NOVERIFY_CHECKSUMS"
           & " MANIFEST 'yes' MANIFEST_CHECKSUMS 'SHA256'",
         "PostgreSQL 14 BASE_BACKUP uses the legacy option grammar");

      Base_Backups.Set_Target
        (Modern, Base_Backups.Server_Target, "/srv/backups/nightly");
      Base_Backups.Set_Compression
        (Modern, Base_Backups.Zstandard_Compression, "level=7,workers=2");
      Base_Backups.Set_Progress (Modern);
      Base_Backups.Set_Checkpoint
        (Modern, Base_Backups.Fast_Checkpoint);
      Base_Backups.Include_WAL (Modern);
      Base_Backups.Wait_For_Archive (Modern, False);
      Base_Backups.Include_Tablespace_Map (Modern);
      Base_Backups.Verify_Checksums (Modern, False);
      Base_Backups.Set_Manifest
        (Modern, Base_Backups.Force_Encode_Manifest,
         Base_Backups.No_Checksum);
      Assert
        (Query_Text (Base_Backups.Command (Modern)) =
           "BASE_BACKUP (TARGET 'server', TARGET_DETAIL"
           & " '/srv/backups/nightly', PROGRESS true, CHECKPOINT 'fast',"
           & " WAL true, WAIT false, COMPRESSION 'zstd',"
           & " COMPRESSION_DETAIL 'level=7,workers=2',"
           & " TABLESPACE_MAP true, VERIFY_CHECKSUMS false,"
           & " MANIFEST 'force-encode', MANIFEST_CHECKSUMS 'NONE')",
         "PostgreSQL 15 BASE_BACKUP uses typed parenthesized options");

      Base_Backups.Set_Incremental (Incremental);
      Assert
        (Query_Text (Base_Backups.Command (Incremental)) =
           "BASE_BACKUP (INCREMENTAL)"
         and then Query_Text
           (Base_Backups.Upload_Manifest_Command (17)) = "UPLOAD_MANIFEST",
         "PostgreSQL 17 exposes incremental backup and manifest upload");

      Assert
        (Replication.Kind
           (Replication.Decode_Command (Base_Backups.Command (Legacy))) =
           Replication.Base_Backup_Command
         and then Replication.Kind
           (Replication.Decode_Command
              (Base_Backups.Upload_Manifest_Command (18))) =
           Replication.Upload_Manifest_Command,
         "primary command decoding classifies backup protocol commands");

      begin
         Base_Backups.Set_Incremental (Legacy);
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected,
         "incremental backup is rejected before PostgreSQL 17");
      Rejected := False;
      begin
         Base_Backups.Set_Compression
           (Legacy, Base_Backups.Gzip_Compression);
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected,
         "server compression is rejected for PostgreSQL 14");
      Rejected := False;
      begin
         Base_Backups.Set_Maximum_Rate (Legacy, 31);
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "invalid backup throttling is rejected locally");
   end Test_Base_Backup_Commands;

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

   procedure Test_Persistence_Contracts is
      Store : aliased Memory.Store;
      Conformance_Store : aliased Memory.Store;
      Created : Persistence.Create_Result;
      Acquired : Persistence.Acquire_Result;
      State : Persistence.Slot_State;
      Lease_1 : Persistence.UInt64;
      Lease_2 : Persistence.UInt64;
      Changed : Boolean;
      Bytes : constant Persistence.Byte_Array := (1, 2, 3, 4, 5, 6);
      Prepared : Persistence.Prepared_Transaction;
      Timeline : Replication.UInt32;
      Target : aliased Target_Context;
      First_Consumer : Prepared_Consumers.Consumer
        (Store => Store'Access, Target => Target'Access);
      Restarted_Consumer : Prepared_Consumers.Consumer
        (Store => Store'Access, Target => Target'Access);
   begin
      Persistence_Conformance.Run
        (Conformance_Store, Conformance_Store,
         Conformance_Store, Conformance_Store);

      Memory.Create
        (Store,
         "physical",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 100),
         Created);
      Assert (Created = Persistence.Created, "memory slot is created");
      Memory.Create
        (Store,
         "physical",
         Persistence.Make_Slot
           (Persistence.Physical_Slot, Restart_LSN => 100),
         Created);
      Assert
        (Created = Persistence.Already_Exists,
         "memory slot creation is idempotently classified");

      Memory.Acquire
        (Store, "physical", Persistence.Physical_Slot,
         Acquired, Lease_1, State);
      Assert
        (Acquired = Persistence.Acquired and then Lease_1 /= 0
         and then Persistence.Is_Active (State),
         "slot acquisition returns an active lease");
      Memory.Acquire
        (Store, "physical", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Assert
        (Acquired = Persistence.Already_Active and then Lease_2 = 0,
         "concurrent slot acquisition is rejected");
      Memory.Advance
        (Store, "physical", Lease_1,
         Restart => 120, Confirmed => 0, Advanced => Changed);
      Assert (Changed, "leased slot advances monotonically");
      Memory.Advance
        (Store, "physical", Lease_1,
         Restart => 119, Confirmed => 0, Advanced => Changed);
      Assert (not Changed, "slot restart LSN cannot move backwards");
      Memory.Release (Store, "physical", Lease_1, Changed);
      Assert (Changed, "matching lease releases the slot");
      Memory.Acquire
        (Store, "physical", Persistence.Physical_Slot,
         Acquired, Lease_2, State);
      Assert
        (Acquired = Persistence.Acquired and then Lease_2 > Lease_1,
         "reacquisition changes the lease generation");
      Memory.Advance
        (Store, "physical", Lease_1,
         Restart => 130, Confirmed => 0, Advanced => Changed);
      Assert (not Changed, "stale lease cannot advance a slot");
      Memory.Release (Store, "physical", Lease_2, Changed);

      Memory.Create
        (Store,
         "logical",
         Persistence.Make_Slot
           (Persistence.Logical_Slot,
            Restart_LSN => 110,
            Confirmed_LSN => 115,
            Plugin => "pgoutput"),
         Created);
      Assert
        (Memory.Oldest_Restart_LSN (Store) = 110,
         "oldest slot restart LSN controls retention");

      Memory.Append (Store, Start => 100, Data => Bytes);
      Assert
        (Memory.First_LSN (Store) = 100
         and then Memory.Current_LSN (Store) = 106
         and then Memory.Read (Store, 102, 3) =
           Persistence.Byte_Array'(3, 4, 5),
         "memory WAL store preserves exact positions and bytes");
      Memory.Retain_From (Store, 103);
      Assert
        (Memory.First_LSN (Store) = 103
         and then Memory.Read (Store, 103, 10) =
           Persistence.Byte_Array'(4, 5, 6),
         "memory WAL retention removes only the requested prefix");

      Memory.Promote (Store, Parent => 1, Fork_LSN => 105,
                      New_Timeline => Timeline);
      Assert
        (Timeline = 2 and then Memory.Current_Timeline (Store) = 2
         and then Memory.History (Store, 2)'Length > 0,
         "memory timeline promotion persists its history");

      Prepared := Persistence.Make_Prepared
        (XID => 77, Prepare_LSN => 150, Payload => (9, 8, 7));
      Memory.Put (Store, "logical", "gid-77", Prepared);
      Prepared := Memory.Load (Store, "logical", "gid-77");
      Assert
        (Persistence.Exists (Prepared)
         and then Persistence.XID (Prepared) = 77
         and then Persistence.Payload (Prepared) =
           Persistence.Byte_Array'(9, 8, 7)
         and then Persistence.Phase (Prepared) = Persistence.Prepared,
         "prepared transaction survives a new store client view");
      Memory.Mark_Target_Applied
        (Store, "logical", "gid-77", Changed);
      Assert
        (Changed
         and then Persistence.Phase
           (Memory.Load (Store, "logical", "gid-77")) =
             Persistence.Target_Applied,
         "target application is durably classified before acknowledgement");
      Memory.Mark_Target_Applied
        (Store, "logical", "gid-77", Changed);
      Assert (not Changed, "target application marker is idempotent");
      Memory.Remove (Store, "logical", "gid-77", Changed);
      Assert
        (Changed
         and then not Persistence.Exists
           (Memory.Load (Store, "logical", "gid-77")),
         "prepared transaction removal is observable");

      Prepared_Consumers.Prepare
        (First_Consumer,
         "logical",
         "gid-restart",
         XID => 88,
         Prepare_LSN => 180,
         Payload => (6, 5, 4));
      Prepared_Consumers.Commit
        (Restarted_Consumer, "logical", "gid-restart", Changed);
      Assert
        (Changed and then Target.Applications = 1
         and then Target.Last_XID = 88,
         "restarted prepared consumer applies durable state once");
      Prepared_Consumers.Commit
        (First_Consumer, "logical", "gid-restart", Changed);
      Assert
        (not Changed and then Target.Applications = 1,
         "applied prepared marker prevents duplicate target application");
      Prepared_Consumers.Acknowledge_Commit
        (Restarted_Consumer, "logical", "gid-restart");
      Assert
        (not Persistence.Exists
           (Memory.Load (Store, "logical", "gid-restart")),
         "source acknowledgement removes prepared replay state");
   end Test_Persistence_Contracts;

   procedure Test_Logical_Producer is
      Encoder : Producer.Encoder;
      Tuple : constant Logical.Tuple_Data := Logical.Make_Tuple
        ((Logical.Text_Column ("1"), Logical.Text_Column ("value")));
      Rejected : Boolean := False;

      procedure Emit
        (Message : Logical.Message; Start, Finish : Logical.LSN) is
         Data : constant Logical.Byte_Array :=
           Producer.Emit (Encoder, Message, Start, Finish);
      begin
         Assert (Data'Length > 0, "pgoutput producer emits message bytes");
      end Emit;

      procedure Assert_Producer_Rejected
        (Message : Logical.Message;
         Start, Finish : Logical.LSN;
         Description : String) is
         Previous_State : constant Producer.Transaction_State :=
           Producer.State (Encoder);
         Previous_XID : constant Logical.Transaction_Id :=
           Producer.Transaction (Encoder);
         Previous_End : constant Logical.LSN :=
           Producer.Last_WAL_End (Encoder);
         Was_Rejected : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Logical.Byte_Array :=
                 Producer.Emit (Encoder, Message, Start, Finish);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Protocol.Protocol_Error =>
               Was_Rejected := True;
         end;
         Assert (Was_Rejected, Description);
         Assert
           (Producer.State (Encoder) = Previous_State
            and then Producer.Transaction (Encoder) = Previous_XID
            and then Producer.Last_WAL_End (Encoder) = Previous_End,
            Description & " without changing producer state");
      end Assert_Producer_Rejected;

      function Logical_Message
        (Transactional : Boolean := False;
         XID : Logical.Transaction_Id := 0) return Logical.Message is
        (Logical.Make_Logical_Decoding_Message
           (Message_LSN   => 16#0102_0304#,
            Prefix        => "flyology",
            Content       => (1, 2, 3, 4),
            Transactional => Transactional,
            Xid           => XID));
   begin
      Producer.Configure (Encoder, Version => 1);
      Emit (Logical.Make_Begin (101, 0, 10), 100, 101);
      Emit
        (Logical.Make_Relation
           (42, "public", "items", Logical.Default_Identity,
            (Logical.Make_Relation_Column
               ("id", Type_Oid => 23, Is_Key => True),
             Logical.Make_Relation_Column
               ("value", Type_Oid => 25))),
         101, 102);
      Emit (Logical.Make_Insert (42, Tuple), 102, 103);
      Emit (Logical.Make_Commit (103, 104, 0), 103, 104);
      Assert
        (Producer.State (Encoder) = Producer.Idle
         and then Producer.Last_WAL_End (Encoder) = 104,
         "regular pgoutput production ends at its commit LSN");

      Producer.Configure
        (Encoder, Version => 2, Streaming => Logical.In_Progress);
      Emit (Logical.Make_Stream_Start (20, True), 200, 201);
      Emit (Logical.Make_Insert (42, Tuple, Xid => 20), 201, 202);
      Emit (Logical.Make_Stream_Stop, 202, 203);
      Emit (Logical.Make_Stream_Commit (20, 203, 204, 0), 203, 204);
      Assert
        (Producer.State (Encoder) = Producer.Idle,
         "streamed pgoutput production commits the paused XID");

      Producer.Configure
        (Encoder, Version => 2, Streaming => Logical.In_Progress);
      Emit (Logical.Make_Stream_Start (20, True), 200, 201);
      Emit (Logical.Make_Origin (201, "origin"), 201, 202);

      Producer.Configure
        (Encoder, Version => 2, Streaming => Logical.In_Progress);
      Emit (Logical.Make_Stream_Start (20, True), 200, 201);
      Assert_Producer_Rejected
        (Logical.Make_Insert (42, Tuple), 201, 202,
         "stream segments reject row changes without their XID");
      Assert_Producer_Rejected
        (Logical_Message (Transactional => True), 201, 202,
         "stream segments reject transactional messages without their XID");
      Emit (Logical.Make_Insert (42, Tuple, Xid => 20), 201, 202);
      Emit (Logical.Make_Stream_Stop, 202, 203);
      Emit (Logical.Make_Stream_Abort (Xid => 20, Subxid => 21), 203, 204);
      Assert
        (Producer.State (Encoder) = Producer.Stream_Paused
         and then Producer.Transaction (Encoder) = 20,
         "subtransaction abort preserves its paused top-level transaction");
      Assert_Producer_Rejected
        (Logical.Make_Stream_Prepare
           (Prepare_LSN => 204,
            End_LSN     => 205,
            Prepare_At => 0,
            Xid         => 20,
            GID         => "unsupported"),
         204,
         205,
         "failed stream preparation restores the complete paused set");
      Emit (Logical.Make_Stream_Start (20, False), 204, 205);
      Emit (Logical.Make_Stream_Stop, 205, 206);

      Emit (Logical.Make_Begin (207, 0, 30), 206, 207);
      Emit (Logical.Make_Commit (207, 208, 0), 207, 208);
      Assert
        (Producer.State (Encoder) = Producer.Stream_Paused
         and then Producer.Transaction (Encoder) = 20,
         "regular transactions may run between streamed segments");

      Emit (Logical.Make_Stream_Start (40, True), 208, 209);
      Emit (Logical.Make_Stream_Stop, 209, 210);
      Assert
        (Producer.State (Encoder) = Producer.Stream_Paused
         and then Producer.Transaction (Encoder) = 40,
         "a second stream may pause and becomes the reported transaction");
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit (Encoder, Logical_Message, 210, 211);
         Item : constant Logical.Message :=
           Logical.Decode
             (Data,
              Version   => 2,
              Streaming => Logical.In_Progress);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Logical_Decoding_Message
            and then not Logical.Is_Transactional (Item)
            and then Logical.Prefix (Item) = "flyology"
            and then Logical.Content (Item) =
              Logical.Byte_Array'(1, 2, 3, 4),
            "nontransactional messages are emitted between stream segments");
      end;
      Emit (Logical.Make_Stream_Commit (40, 211, 212, 0), 211, 212);
      Assert
        (Producer.State (Encoder) = Producer.Stream_Paused
         and then Producer.Transaction (Encoder) = 20,
         "stream completion restores the most recently remaining paused XID");
      Emit (Logical.Make_Stream_Commit (20, 212, 213, 0), 212, 213);
      Assert
        (Producer.State (Encoder) = Producer.Idle
         and then Producer.Transaction (Encoder) = 0,
         "completing every paused stream returns the producer to idle");

      Producer.Configure (Encoder, Version => 1);
      declare
         Data : constant Logical.Byte_Array :=
           Producer.Emit (Encoder, Logical_Message, 300, 301);
         Item : constant Logical.Message :=
           Logical.Decode (Data, Version => 1);
      begin
         Assert
           (Logical.Kind (Item) = Logical.Logical_Decoding_Message
            and then not Logical.Is_Transactional (Item)
            and then Logical.Message_LSN (Item) = 16#0102_0304#,
            "nontransactional logical messages are emitted while idle");
      end;
      Assert_Producer_Rejected
        (Logical_Message (Transactional => True), 301, 302,
         "transactional logical messages remain invalid while idle");

      begin
         declare
            Ignored : constant Logical.Byte_Array := Producer.Emit
              (Encoder, Logical.Make_Insert (42, Tuple), 301, 302);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected,
         "pgoutput producer rejects row changes outside transactions");

      Producer.Configure (Encoder, Version => 2);
      Rejected := False;
      begin
         declare
            Ignored : constant Logical.Byte_Array := Producer.Emit
              (Encoder,
               Logical.Make_Begin_Prepare
                 (Prepare_LSN => 301,
                  End_LSN    => 302,
                  Prepare_At => 0,
                  Xid        => 30,
                  GID        => "unsupported"),
               300,
               301);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Protocol.Protocol_Error =>
            Rejected := True;
      end;
      Assert
        (Rejected and then Producer.State (Encoder) = Producer.Idle
         and then Producer.Last_WAL_End (Encoder) = 0,
         "failed pgoutput encoding rolls producer state back atomically");
   end Test_Logical_Producer;

   procedure Run is
   begin
      Test_Commands_And_LSN;
      Test_Base_Backup_Commands;
      Test_Physical_Messages;
      Test_Logical_Transaction_Messages;
      Test_Logical_Row_Messages;
      Test_Logical_Streaming;
      Test_Logical_Encoding;
      Test_Logical_Failures;
      Test_Persistence_Contracts;
      Test_Logical_Producer;
   end Run;

end Replication_Tests;
