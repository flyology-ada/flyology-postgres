with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Replication.Base_Backups is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Client.Operation_State;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Byte_Offset;
   use type UInt32;
   use type UInt64;

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Information;
      end if;
   end Require;

   function Text (Value : Flyology.Bytes.Unbounded_Bytes) return String is
     (Flyology.Bytes.To_Byte_String (Value));

   function Bytes (Value : String) return Flyology.Bytes.Unbounded_Bytes is
     (Flyology.Bytes.From_Byte_String (Value));

   procedure Validate_Text (Value : String; Name : String) is
   begin
      Require
        ((for all Item of Value => Item /= Character'Val (0)),
         Name & " contains an embedded zero byte");
      Require
        (Value'Length <= Protocol.Maximum_Message_Size - 32,
         Name & " exceeds the configured protocol limit");
   end Validate_Text;

   function SQL_Literal (Value : String) return String is
      Quotes : Natural := 0;
   begin
      Validate_Text (Value, "BASE_BACKUP option");
      for Item of Value loop
         if Item = ''' then
            Quotes := Quotes + 1;
         end if;
      end loop;
      declare
         Result : String (1 .. Value'Length + Quotes + 2);
         Cursor : Positive := Result'First;
      begin
         Result (Cursor) := ''';
         Cursor := Cursor + 1;
         for Item of Value loop
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

   function Query (Value : String) return Protocol.Message is
      Payload : Flyology.Bytes.Unbounded_Bytes;
   begin
      Require
        (Value'Length <= Protocol.Maximum_Message_Size - 5,
         "BASE_BACKUP command exceeds the configured protocol limit");
      Protocol.Append_C_String (Payload, Value);
      return Protocol.Make_Message ('Q', Flyology.Bytes.To_Array (Payload));
   end Query;

   function Decimal (Value : UInt32) return String is
     (Ada.Strings.Fixed.Trim (UInt32'Image (Value), Ada.Strings.Both));

   function Defaults (Major : Server_Major) return Options is
     (Version => Major, others => <>);

   function Major (Item : Options) return Server_Major is (Item.Version);

   procedure Set_Label (Item : in out Options; Label : String) is
   begin
      Validate_Text (Label, "backup label");
      Item.Label_Present := True;
      Item.Label_Data := Bytes (Label);
   end Set_Label;

   procedure Set_Target
     (Item   : in out Options;
      Target : Backup_Target;
      Detail : String := "") is
   begin
      Require
        (Item.Version >= 15,
         "BASE_BACKUP TARGET requires PostgreSQL 15 or newer");
      Validate_Text (Detail, "backup target detail");
      Require
        ((Target = Server_Target and then Detail'Length > 0)
         or else (Target /= Server_Target and then Detail'Length = 0),
         "TARGET_DETAIL is required only for the server backup target");
      Item.Target_Value := Target;
      Item.Target_Detail_Data := Bytes (Detail);
   end Set_Target;

   procedure Set_Progress (Item : in out Options; Enabled : Boolean := True) is
   begin
      Item.Progress_Value := Enabled;
   end Set_Progress;

   procedure Set_Checkpoint
     (Item : in out Options; Mode : Checkpoint_Mode) is
   begin
      Item.Checkpoint_Value := Mode;
   end Set_Checkpoint;

   procedure Include_WAL (Item : in out Options; Enabled : Boolean := True) is
   begin
      Item.WAL_Value := Enabled;
   end Include_WAL;

   procedure Wait_For_Archive
     (Item : in out Options; Enabled : Boolean := True) is
   begin
      Item.Archive_Wait_Value := Enabled;
   end Wait_For_Archive;

   procedure Set_Compression
     (Item   : in out Options;
      Method : Compression_Method;
      Detail : String := "") is
   begin
      Require
        (Item.Version >= 15,
         "server-side BASE_BACKUP compression requires PostgreSQL 15 or newer");
      Validate_Text (Detail, "compression detail");
      Require
        (Method /= No_Compression or else Detail'Length = 0,
         "compression detail requires a compression method");
      Item.Compression_Value := Method;
      Item.Compression_Detail := Bytes (Detail);
   end Set_Compression;

   procedure Set_Maximum_Rate
     (Item : in out Options; Kilobytes_Per_Second : UInt32) is
   begin
      Require
        (Kilobytes_Per_Second = 0
         or else Kilobytes_Per_Second in 32 .. 1_048_576,
         "BASE_BACKUP rate must be 0 or 32 through 1048576 KiB/s");
      Item.Maximum_Rate_Value := Kilobytes_Per_Second;
   end Set_Maximum_Rate;

   procedure Include_Tablespace_Map
     (Item : in out Options; Enabled : Boolean := True) is
   begin
      Item.Tablespace_Map := Enabled;
   end Include_Tablespace_Map;

   procedure Verify_Checksums
     (Item : in out Options; Enabled : Boolean := True) is
   begin
      Item.Verify_Value := Enabled;
   end Verify_Checksums;

   procedure Set_Manifest
     (Item      : in out Options;
      Mode      : Manifest_Mode;
      Checksums : Manifest_Checksum := CRC32C_Checksum) is
   begin
      Require
        (Mode /= No_Manifest or else Checksums = CRC32C_Checksum,
         "manifest checksums require an enabled backup manifest");
      Item.Manifest_Value := Mode;
      Item.Checksum_Value := Checksums;
   end Set_Manifest;

   procedure Set_Incremental
     (Item : in out Options; Enabled : Boolean := True) is
   begin
      Require
        (not Enabled or else Item.Version >= 17,
         "incremental BASE_BACKUP requires PostgreSQL 17 or newer");
      Item.Incremental_Value := Enabled;
   end Set_Incremental;

   function Checksum_Text (Value : Manifest_Checksum) return String is
     (case Value is
        when No_Checksum     => "NONE",
        when CRC32C_Checksum => "CRC32C",
        when SHA224_Checksum => "SHA224",
        when SHA256_Checksum => "SHA256",
        when SHA384_Checksum => "SHA384",
        when SHA512_Checksum => "SHA512");

   function Command (Item : Options) return Protocol.Message is
      Result : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String ("BASE_BACKUP");

      procedure Add (Value : String) is
      begin
         if Item.Version = 14 then
            Unbounded.Append (Result, " " & Value);
         elsif Unbounded.Length (Result) = String'("BASE_BACKUP")'Length then
            Unbounded.Append (Result, " (" & Value);
         else
            Unbounded.Append (Result, ", " & Value);
         end if;
      end Add;

      function Target_Text return String is
        (case Item.Target_Value is
           when Client_Target    => "client",
           when Server_Target    => "server",
           when Blackhole_Target => "blackhole");

      function Compression_Text return String is
        (case Item.Compression_Value is
           when No_Compression       => "",
           when Gzip_Compression     => "gzip",
           when LZ4_Compression      => "lz4",
           when Zstandard_Compression => "zstd");
   begin
      if Item.Label_Present then
         Add ("LABEL " & SQL_Literal (Text (Item.Label_Data)));
      end if;

      if Item.Version >= 15 and then Item.Target_Value /= Client_Target then
         Add ("TARGET " & SQL_Literal (Target_Text));
         if Item.Target_Value = Server_Target then
            Add
              ("TARGET_DETAIL "
               & SQL_Literal (Text (Item.Target_Detail_Data)));
         end if;
      end if;

      if Item.Progress_Value then
         Add (if Item.Version = 14 then "PROGRESS" else "PROGRESS true");
      end if;
      if Item.Checkpoint_Value = Fast_Checkpoint then
         Add
           (if Item.Version = 14
            then "FAST"
            else "CHECKPOINT " & SQL_Literal ("fast"));
      end if;
      if Item.WAL_Value then
         Add (if Item.Version = 14 then "WAL" else "WAL true");
      end if;
      if not Item.Archive_Wait_Value then
         Add (if Item.Version = 14 then "NOWAIT" else "WAIT false");
      end if;
      if Item.Version >= 15
        and then Item.Compression_Value /= No_Compression
      then
         Add ("COMPRESSION " & SQL_Literal (Compression_Text));
         if Text (Item.Compression_Detail)'Length > 0 then
            Add
              ("COMPRESSION_DETAIL "
               & SQL_Literal (Text (Item.Compression_Detail)));
         end if;
      end if;
      if Item.Maximum_Rate_Value /= 0 then
         Add ("MAX_RATE " & Decimal (Item.Maximum_Rate_Value));
      end if;
      if Item.Tablespace_Map then
         Add
           (if Item.Version = 14
            then "TABLESPACE_MAP"
            else "TABLESPACE_MAP true");
      end if;
      if not Item.Verify_Value then
         Add
           (if Item.Version = 14
            then "NOVERIFY_CHECKSUMS"
            else "VERIFY_CHECKSUMS false");
      end if;
      if Item.Manifest_Value /= No_Manifest then
         Add
           ("MANIFEST "
            & SQL_Literal
                (if Item.Manifest_Value = Include_Manifest
                 then "yes"
                 else "force-encode"));
         if Item.Checksum_Value /= CRC32C_Checksum then
            Add
              ("MANIFEST_CHECKSUMS "
               & SQL_Literal (Checksum_Text (Item.Checksum_Value)));
         end if;
      end if;
      if Item.Incremental_Value then
         Add ("INCREMENTAL");
      end if;

      if Item.Version >= 15
        and then Unbounded.Length (Result) > String'("BASE_BACKUP")'Length
      then
         Unbounded.Append (Result, ")");
      end if;
      return Query (Unbounded.To_String (Result));
   end Command;

   function Upload_Manifest_Command
     (Major : Server_Major) return Protocol.Message is
   begin
      Require
        (Major >= 17, "UPLOAD_MANIFEST requires PostgreSQL 17 or newer");
      return Query ("UPLOAD_MANIFEST");
   end Upload_Manifest_Command;

   procedure Raise_Database_Error (Response : Protocol.Backend_Message) is
      Details : constant Protocol.Diagnostic :=
        Protocol.Diagnostic_Data (Response);
   begin
      raise Client.Database_Error with
        Protocol.Diagnostic_SQL_State (Details) & ": "
        & Protocol.Diagnostic_Message (Details);
   end Raise_Database_Error;

   procedure Begin_Manifest_Upload
     (Connection : in out Client.Session;
      Major      : Server_Major;
      Timeout    : Duration := 30.0) is
   begin
      Client.Send_Command
        (Connection, Upload_Manifest_Command (Major), Timeout);
      loop
         declare
            Response : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Connection, Timeout);
         begin
            case Protocol.Response_Kind (Response) is
               when Protocol.Copy_In_Response =>
                  return;
               when Protocol.Error_Response =>
                  Raise_Database_Error (Response);
               when Protocol.Notice_Response |
                    Protocol.Parameter_Status_Response =>
                  null;
               when others =>
                  raise Protocol.Protocol_Error with
                    "unexpected response before UPLOAD_MANIFEST COPY IN";
            end case;
         end;
      end loop;
   end Begin_Manifest_Upload;

   procedure Send_Manifest_Chunk
     (Connection : in out Client.Session;
      Data       : Byte_Array;
      Timeout    : Duration := 30.0) is
   begin
      Client.Send_Copy_Data (Connection, Data, Timeout);
   end Send_Manifest_Chunk;

   procedure Finish_Manifest_Upload
     (Connection : in out Client.Session;
      Timeout    : Duration := 30.0) is
   begin
      Client.Finish_Copy (Connection, Timeout);
   end Finish_Manifest_Upload;

   procedure Abort_Manifest_Upload
     (Connection : in out Client.Session;
      Reason     : String;
      Timeout    : Duration := 30.0) is
   begin
      Client.Abort_Copy (Connection, Reason, Timeout);
   end Abort_Manifest_Upload;

   function Kind (Item : Event) return Event_Kind is (Item.Event_Type);

   procedure Require_Kind
     (Item : Event; Allowed : Event_Kind; Information : String) is
   begin
      Require (Item.Event_Type = Allowed, Information);
   end Require_Kind;

   function Start_LSN (Item : Event) return LSN is
   begin
      Require_Kind (Item, Backup_Start, "event has no backup start LSN");
      return Item.First_Position;
   end Start_LSN;

   function End_LSN (Item : Event) return LSN is
   begin
      Require_Kind (Item, Backup_End, "event has no backup end LSN");
      return Item.Last_Position;
   end End_LSN;

   function Timeline (Item : Event) return UInt32 is
   begin
      Require
        (Item.Event_Type in Backup_Start | Backup_End,
         "event has no backup timeline");
      return Item.Timeline_Value;
   end Timeline;

   function Has_Tablespace_Oid (Item : Event) return Boolean is
   begin
      Require_Kind (Item, Tablespace, "event is not tablespace metadata");
      return Item.Oid_Present;
   end Has_Tablespace_Oid;

   function Tablespace_Oid (Item : Event) return UInt32 is
   begin
      Require
        (Item.Event_Type = Tablespace and then Item.Oid_Present,
         "tablespace event has no OID");
      return Item.Oid_Value;
   end Tablespace_Oid;

   function Has_Tablespace_Location (Item : Event) return Boolean is
   begin
      Require_Kind (Item, Tablespace, "event is not tablespace metadata");
      return Item.Location_Present;
   end Has_Tablespace_Location;

   function Tablespace_Location (Item : Event) return String is
   begin
      Require
        (Item.Event_Type = Tablespace and then Item.Location_Present,
         "tablespace event has no location");
      return Text (Item.Location_Data);
   end Tablespace_Location;

   function Has_Tablespace_Size (Item : Event) return Boolean is
   begin
      Require_Kind (Item, Tablespace, "event is not tablespace metadata");
      return Item.Size_Present;
   end Has_Tablespace_Size;

   function Tablespace_Size_KiB (Item : Event) return UInt64 is
   begin
      Require
        (Item.Event_Type = Tablespace and then Item.Size_Present,
         "tablespace event has no estimated size");
      return Item.Size_Value;
   end Tablespace_Size_KiB;

   function Archive_Name (Item : Event) return String is
   begin
      Require_Kind (Item, Archive_Start, "event does not start an archive");
      return Text (Item.Name_Data);
   end Archive_Name;

   function Archive_Location (Item : Event) return String is
   begin
      Require_Kind (Item, Archive_Start, "event does not start an archive");
      return Text (Item.Location_Data);
   end Archive_Location;

   function Stream_Index (Item : Event) return Positive is
   begin
      Require
        (Item.Event_Type in Archive_Start | Archive_Data |
           Manifest_Start | Manifest_Data,
         "event has no backup stream index");
      return Item.Stream_Number;
   end Stream_Index;

   function Data (Item : Event) return Byte_Array is
   begin
      Require
        (Item.Event_Type in Archive_Data | Manifest_Data,
         "event carries no archive or manifest data");
      return Flyology.Bytes.To_Array (Item.Bytes);
   end Data;

   function Bytes_Completed (Item : Event) return UInt64 is
   begin
      Require_Kind (Item, Progress, "event is not a progress report");
      return Item.Progress_Value;
   end Bytes_Completed;

   function Diagnostic (Item : Event) return Protocol.Diagnostic is
   begin
      Require
        (Item.Event_Type in Notice | Error,
         "event carries no PostgreSQL diagnostic");
      return Protocol.Diagnostic_Data (Protocol.Decode_Backend (Item.Raw));
   end Diagnostic;

   function Status (Item : Event) return Protocol.Parameter_Status is
   begin
      Require_Kind
        (Item, Parameter_Status, "event is not a parameter status update");
      return Protocol.Parameter_Data (Protocol.Decode_Backend (Item.Raw));
   end Status;

   function Original_Message (Item : Event) return Protocol.Message is
     (Item.Raw);

   function Parse_UInt32 (Value : String; Name : String) return UInt32 is
   begin
      Require
        (Value'Length > 0
         and then (for all Item of Value => Item in '0' .. '9'),
         Name & " is not an unsigned decimal integer");
      return UInt32'Value (Value);
   exception
      when Constraint_Error =>
         raise Protocol.Protocol_Error with Name & " is outside uint32";
   end Parse_UInt32;

   function Parse_UInt64 (Value : String; Name : String) return UInt64 is
   begin
      Require
        (Value'Length > 0
         and then (for all Item of Value => Item in '0' .. '9'),
         Name & " is not an unsigned decimal integer");
      return UInt64'Value (Value);
   exception
      when Constraint_Error =>
         raise Protocol.Protocol_Error with Name & " is outside uint64";
   end Parse_UInt64;

   function Basic_Event
     (Kind : Event_Kind; Raw : Protocol.Message) return Event is
     (Event_Type => Kind, Raw => Raw, others => <>);

   procedure Start
     (Item    : in out Receiver;
      Options : Base_Backups.Options;
      Timeout : Duration := 30.0) is
   begin
      if Item.Phase /= Not_Started then
         raise Program_Error with "BASE_BACKUP receiver was already started";
      end if;
      Require
        (Options.Target_Value = Client_Target,
         "streaming Receiver requires the client backup target");
      Item.Version := Options.Version;
      Item.Manifest_Expected := Options.Manifest_Value /= No_Manifest;
      Client.Send_Command (Item.Connection.all, Command (Options), Timeout);
      Item.Phase := Start_Result;
   end Start;

   function Position_Event
     (Item     : in out Receiver;
      Response : Protocol.Backend_Message;
      Ending   : Boolean) return Event is
      Row : constant Protocol.Data_Row := Protocol.Row_Data (Response);
      Position_Column : Protocol.Column_Value;
      Timeline_Column : Protocol.Column_Value;
      Position_Value  : LSN;
      Timeline_Value  : UInt32;
   begin
      Require
        (Protocol.Column_Count (Row) = 2,
         "BASE_BACKUP position row must contain two columns");
      Position_Column := Protocol.Column_At (Row, 1);
      Timeline_Column := Protocol.Column_At (Row, 2);
      Require
        (not Protocol.Is_Null (Position_Column)
         and then not Protocol.Is_Null (Timeline_Column),
         "BASE_BACKUP position and timeline cannot be NULL");
      Position_Value := Value (Protocol.Column_Text (Position_Column));
      Timeline_Value := Parse_UInt32
        (Protocol.Column_Text (Timeline_Column), "BASE_BACKUP timeline");
      Require (Timeline_Value > 0, "BASE_BACKUP timeline must be positive");

      if Ending then
         Require
           (Position_Value >= Item.Start_Position,
            "BASE_BACKUP end LSN precedes its start LSN");
         Require
           (Timeline_Value = Item.Start_Timeline,
            "BASE_BACKUP start and end timelines differ");
         return
           (Event_Type     => Backup_End,
            Raw            => Protocol.Original_Message (Response),
            Last_Position  => Position_Value,
            Timeline_Value => Timeline_Value,
            others         => <>);
      else
         Item.Start_Position := Position_Value;
         Item.Start_Timeline := Timeline_Value;
         return
           (Event_Type     => Backup_Start,
            Raw            => Protocol.Original_Message (Response),
            First_Position => Position_Value,
            Timeline_Value => Timeline_Value,
            others         => <>);
      end if;
   end Position_Event;

   function Tablespace_Event
     (Item     : in out Receiver;
      Response : Protocol.Backend_Message) return Event is
      Row : constant Protocol.Data_Row := Protocol.Row_Data (Response);
      Oid_Column      : Protocol.Column_Value;
      Location_Column : Protocol.Column_Value;
      Size_Column     : Protocol.Column_Value;
      Result : Event :=
        (Event_Type => Tablespace,
         Raw        => Protocol.Original_Message (Response),
         others     => <>);
   begin
      Require
        (Protocol.Column_Count (Row) = 3,
         "BASE_BACKUP tablespace row must contain three columns");
      Oid_Column := Protocol.Column_At (Row, 1);
      Location_Column := Protocol.Column_At (Row, 2);
      Size_Column := Protocol.Column_At (Row, 3);
      if not Protocol.Is_Null (Oid_Column) then
         Result.Oid_Present := True;
         Result.Oid_Value := Parse_UInt32
           (Protocol.Column_Text (Oid_Column), "tablespace OID");
      end if;
      if not Protocol.Is_Null (Location_Column) then
         Result.Location_Present := True;
         Result.Location_Data := Bytes
           (Protocol.Column_Text (Location_Column));
      end if;
      if not Protocol.Is_Null (Size_Column) then
         Result.Size_Present := True;
         Result.Size_Value := Parse_UInt64
           (Protocol.Column_Text (Size_Column), "tablespace size");
      end if;
      Item.Tablespace_Count := Item.Tablespace_Count + 1;
      return Result;
   end Tablespace_Event;

   function Multiplexed_Event
     (Item     : in out Receiver;
      Response : Protocol.Backend_Message) return Event is
      Payload : constant Byte_Array := Protocol.Copy_Data (Response);
      Raw     : constant Protocol.Message := Protocol.Original_Message (Response);
      Tag     : Character;
   begin
      Require (Payload'Length > 0, "empty multiplexed BASE_BACKUP CopyData");
      Tag := Character'Val (Payload (Payload'First));
      case Tag is
         when 'n' =>
            Require
              (not Item.Manifest_Seen,
               "BASE_BACKUP archive marker followed its manifest");
            declare
               Cursor : Protocol.Byte_Offset := Payload'First + 1;
               Name : constant String := Protocol.Read_C_String (Payload, Cursor);
               Location : constant String :=
                 Protocol.Read_C_String (Payload, Cursor);
            begin
               Require
                 (Cursor = Payload'First + Payload'Length,
                  "new-archive BASE_BACKUP frame has trailing bytes");
               Item.Streams_Started := Item.Streams_Started + 1;
               Item.Archive_Count := Item.Archive_Count + 1;
               Item.Current_Is_Manifest := False;
               return
                 (Event_Type       => Archive_Start,
                  Raw              => Raw,
                  Name_Data        => Bytes (Name),
                  Location_Data    => Bytes (Location),
                  Location_Present => True,
                  Stream_Number    => Item.Streams_Started,
                  others           => <>);
            end;
         when 'm' =>
            Require
              (Payload'Length = 1,
               "manifest-start BASE_BACKUP frame has trailing bytes");
            Require
              (Item.Manifest_Expected,
               "server sent an unrequested backup manifest");
            Require
              (not Item.Manifest_Seen,
               "server sent more than one backup manifest");
            Item.Streams_Started := Item.Streams_Started + 1;
            Item.Manifest_Seen := True;
            Item.Current_Is_Manifest := True;
            return
              (Event_Type    => Manifest_Start,
               Raw           => Raw,
               Stream_Number => Item.Streams_Started,
               others        => <>);
         when 'd' =>
            Require
              (Item.Streams_Started > 0,
               "BASE_BACKUP data arrived before a stream marker");
            declare
               Contents : Flyology.Bytes.Unbounded_Bytes;
            begin
               if Payload'Length > 1 then
                  Contents := Flyology.Bytes.To_Unbounded_Bytes
                    (Payload (Payload'First + 1 .. Payload'Last));
               end if;
               return
                 (Event_Type =>
                    (if Item.Current_Is_Manifest
                     then Manifest_Data
                     else Archive_Data),
                  Raw           => Raw,
                  Stream_Number => Item.Streams_Started,
                  Bytes         => Contents,
                  others        => <>);
            end;
         when 'p' =>
            Require
              (Payload'Length = 9,
               "BASE_BACKUP progress frame must contain one int64");
            declare
               Completed : constant UInt64 :=
                 Flyology.Postgres.Wire.Decode_U64
                   (Payload, Position => 1);
            begin
               Require
                 (Completed <= UInt64 (Int64'Last),
                  "BASE_BACKUP progress cannot be negative");
               return
                 (Event_Type     => Progress,
                  Raw            => Raw,
                  Progress_Value => Completed,
                  others         => <>);
            end;
         when others =>
            raise Protocol.Protocol_Error with
              "unknown multiplexed BASE_BACKUP frame " & Tag;
      end case;
   end Multiplexed_Event;

   function Legacy_Data_Event
     (Item     : Receiver;
      Response : Protocol.Backend_Message) return Event is
      Raw : constant Protocol.Message := Protocol.Original_Message (Response);
   begin
      Require
        (Item.Streams_Started > 0,
         "legacy BASE_BACKUP data arrived before CopyOutResponse");
      return
        (Event_Type =>
           (if Item.Current_Is_Manifest then Manifest_Data else Archive_Data),
         Raw           => Raw,
         Stream_Number => Item.Streams_Started,
         Bytes         => Flyology.Bytes.To_Unbounded_Bytes
           (Protocol.Copy_Data (Response)),
         others        => <>);
   end Legacy_Data_Event;

   function Receive
     (Item : in out Receiver; Timeout : Duration := 30.0) return Event is
   begin
      if Item.Phase in Not_Started | Finished then
         raise Program_Error with "BASE_BACKUP receiver is not active";
      end if;

      loop
         if Client.State (Item.Connection.all) = Client.Simple_Query_Active then
            declare
               Response : constant Protocol.Backend_Message :=
                 Client.Receive_Query_Event (Item.Connection.all, Timeout);
               Raw : constant Protocol.Message :=
                 Protocol.Original_Message (Response);
            begin
               case Protocol.Response_Kind (Response) is
                  when Protocol.Row_Description_Response =>
                     null;
                  when Protocol.Data_Row_Response =>
                     case Item.Phase is
                        when Start_Result =>
                           return Position_Event (Item, Response, False);
                        when Tablespace_Result =>
                           return Tablespace_Event (Item, Response);
                        when End_Result =>
                           return Position_Event (Item, Response, True);
                        when others =>
                           raise Protocol.Protocol_Error with
                             "unexpected BASE_BACKUP result row";
                     end case;
                  when Protocol.Command_Complete_Response =>
                     case Item.Phase is
                        when Start_Result =>
                           Item.Phase := Tablespace_Result;
                        when Tablespace_Result =>
                           Require
                             (Item.Tablespace_Count > 0,
                              "BASE_BACKUP returned no main tablespace row");
                           Item.Phase := Streams;
                        when End_Result =>
                           Item.Phase := Awaiting_Ready;
                        when others =>
                           null;
                     end case;
                  when Protocol.Copy_Out_Response =>
                     Require
                       (Item.Phase = Streams,
                        "BASE_BACKUP COPY OUT began outside stream phase");
                     if Item.Version = 14 then
                        Item.Streams_Started := Item.Streams_Started + 1;
                        Require
                          (Item.Streams_Started <= Item.Tablespace_Count
                             + (if Item.Manifest_Expected then 1 else 0),
                           "legacy server sent too many backup streams");
                        Item.Current_Is_Manifest :=
                          Item.Streams_Started > Item.Tablespace_Count;
                        Require
                          (not Item.Current_Is_Manifest
                           or else Item.Manifest_Expected,
                           "legacy server sent an unrequested manifest stream");
                        if Item.Current_Is_Manifest then
                           Item.Manifest_Seen := True;
                        else
                           Item.Archive_Count := Item.Archive_Count + 1;
                        end if;
                        return
                          (Event_Type =>
                             (if Item.Current_Is_Manifest
                              then Manifest_Start
                              else Archive_Start),
                           Raw           => Raw,
                           Stream_Number => Item.Streams_Started,
                           others        => <>);
                     end if;
                  when Protocol.Notice_Response =>
                     return Basic_Event (Notice, Raw);
                  when Protocol.Parameter_Status_Response =>
                     return Basic_Event (Parameter_Status, Raw);
                  when Protocol.Error_Response =>
                     Item.Phase := Awaiting_Ready;
                     return Basic_Event (Error, Raw);
                  when Protocol.Ready_For_Query_Response =>
                     Require
                       (Item.Phase = Awaiting_Ready,
                        "BASE_BACKUP became ready before its final result");
                     Item.Phase := Finished;
                     return Basic_Event (Complete, Raw);
                  when others =>
                     raise Protocol.Protocol_Error with
                       "unexpected response during BASE_BACKUP";
               end case;
            end;
         elsif Client.State (Item.Connection.all) in
           Client.Copy_Out_Active | Client.Copy_Completion_Active
         then
            declare
               Response : constant Protocol.Backend_Message :=
                 Client.Receive_Copy_Event (Item.Connection.all, Timeout);
               Raw : constant Protocol.Message :=
                 Protocol.Original_Message (Response);
            begin
               case Protocol.Response_Kind (Response) is
                  when Protocol.Copy_Data_Response =>
                     if Item.Version = 14 then
                        return Legacy_Data_Event (Item, Response);
                     else
                        return Multiplexed_Event (Item, Response);
                     end if;
                  when Protocol.Copy_Done_Response =>
                     if Item.Version >= 15 then
                        Require
                          (Item.Archive_Count = Item.Tablespace_Count,
                           "BASE_BACKUP archive count differs from tablespaces");
                        Require
                          (Item.Manifest_Seen = Item.Manifest_Expected,
                           "BASE_BACKUP manifest presence differs from request");
                        Item.Phase := End_Result;
                     elsif Item.Streams_Started = Item.Tablespace_Count
                       + (if Item.Manifest_Expected then 1 else 0)
                     then
                        Item.Phase := End_Result;
                     end if;
                  when Protocol.Copy_Out_Response =>
                     Require
                       (Item.Version = 14 and then Item.Phase = Streams,
                        "unexpected additional BASE_BACKUP COPY stream");
                     Item.Streams_Started := Item.Streams_Started + 1;
                     Require
                       (Item.Streams_Started <= Item.Tablespace_Count
                          + (if Item.Manifest_Expected then 1 else 0),
                        "legacy server sent too many backup streams");
                     Item.Current_Is_Manifest :=
                       Item.Streams_Started > Item.Tablespace_Count;
                     if Item.Current_Is_Manifest then
                        Require
                          (not Item.Manifest_Seen,
                           "legacy server sent more than one backup manifest");
                        Item.Manifest_Seen := True;
                     else
                        Item.Archive_Count := Item.Archive_Count + 1;
                     end if;
                     return
                       (Event_Type =>
                          (if Item.Current_Is_Manifest
                           then Manifest_Start
                           else Archive_Start),
                        Raw           => Raw,
                        Stream_Number => Item.Streams_Started,
                        others        => <>);
                  when Protocol.Row_Description_Response =>
                     Require
                       (Item.Phase = End_Result,
                        "BASE_BACKUP stop result began before COPY completed");
                  when Protocol.Command_Complete_Response =>
                     if Item.Version >= 15
                       or else Item.Streams_Started = Item.Tablespace_Count
                         + (if Item.Manifest_Expected then 1 else 0)
                     then
                        Item.Phase := End_Result;
                     end if;
                  when Protocol.Notice_Response =>
                     return Basic_Event (Notice, Raw);
                  when Protocol.Parameter_Status_Response =>
                     return Basic_Event (Parameter_Status, Raw);
                  when Protocol.Error_Response =>
                     Item.Phase := Awaiting_Ready;
                     return Basic_Event (Error, Raw);
                  when Protocol.Ready_For_Query_Response =>
                     Item.Phase := Finished;
                     return Basic_Event (Complete, Raw);
                  when others =>
                     raise Protocol.Protocol_Error with
                       "unexpected COPY response during BASE_BACKUP";
               end case;
            end;
         else
            raise Protocol.Protocol_Error with
              "client state diverged from active BASE_BACKUP receiver";
         end if;
      end loop;
   end Receive;

   procedure Cancel
     (Item                  : Receiver;
      Cancellation_Channel : in out Transports.Transport'Class;
      Timeout               : Duration := 30.0) is
   begin
      if Item.Phase in Not_Started | Finished then
         raise Program_Error with "no active BASE_BACKUP to cancel";
      end if;
      Client.Send_Cancel_Request
        (Item.Connection.all, Cancellation_Channel, Timeout);
   end Cancel;

end Flyology.Postgres.Replication.Base_Backups;
