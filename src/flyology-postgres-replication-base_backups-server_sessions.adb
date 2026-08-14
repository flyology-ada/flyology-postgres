with Ada.Strings.Fixed;
with Flyology.Bytes;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Replication.Base_Backups.Server_Sessions is

   use type UInt32;
   use type UInt64;

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Information;
      end if;
   end Require;

   function Decimal (Value : UInt32) return String is
     (Ada.Strings.Fixed.Trim (UInt32'Image (Value), Ada.Strings.Both));

   function Decimal (Value : UInt64) return String is
     (Ada.Strings.Fixed.Trim (UInt64'Image (Value), Ada.Strings.Both));

   procedure Send_Position
     (Client   : in out Sessions.Session;
      Position : LSN;
      Timeline : UInt32;
      Timeout  : Duration) is
   begin
      Require (Timeline > 0, "a backup timeline must be positive");
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description ("recptr"),
            Protocol.Make_Field_Description
              ("tli", Type_Oid => 23, Type_Size => 4)),
         Timeout => Timeout);
      Sessions.Send_Data_Row
        (Client,
         Values =>
           (Protocol.Text_Column (Image (Position)),
            Protocol.Text_Column (Decimal (Timeline))),
         Timeout => Timeout);
      Sessions.Send_Command_Complete (Client, "SELECT 1", Timeout);
   end Send_Position;

   procedure Send_Start_Position
     (Client   : in out Sessions.Session;
      Position : LSN;
      Timeline : UInt32;
      Timeout  : Duration) is
   begin
      Send_Position (Client, Position, Timeline, Timeout);
   end Send_Start_Position;

   procedure Begin_Tablespaces
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description
              ("spcoid", Type_Oid => 26, Type_Size => 4),
            Protocol.Make_Field_Description ("spclocation"),
            Protocol.Make_Field_Description
              ("size", Type_Oid => 20, Type_Size => 8)),
         Timeout => Timeout);
   end Begin_Tablespaces;

   procedure Send_Tablespace
     (Client           : in out Sessions.Session;
      Oid_Present      : Boolean;
      Oid              : UInt32 := 0;
      Location_Present : Boolean;
      Location         : String := "";
      Size_Present     : Boolean;
      Size_KiB         : UInt64 := 0;
      Timeout          : Duration) is
   begin
      Require
        (Oid_Present = Location_Present,
         "base directory tablespace OID and location must both be NULL");
      Sessions.Send_Data_Row
        (Client,
         Values =>
           ((if Oid_Present
             then Protocol.Text_Column (Decimal (Oid))
             else Protocol.Null_Column),
            (if Location_Present
             then Protocol.Text_Column (Location)
             else Protocol.Null_Column),
            (if Size_Present
             then Protocol.Text_Column (Decimal (Size_KiB))
             else Protocol.Null_Column)),
         Timeout => Timeout);
   end Send_Tablespace;

   procedure Complete_Tablespaces
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Command_Complete (Client, "SELECT", Timeout);
   end Complete_Tablespaces;

   procedure Begin_Stream
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_Out_Response
        (Client,
         Overall_Format => Protocol.Text_Format,
         Column_Formats => Protocol.No_Formats,
         Timeout        => Timeout);
   end Begin_Stream;

   procedure Send_Archive_Start
     (Client    : in out Sessions.Session;
      File_Name : String;
      Location  : String;
      Timeout   : Duration) is
      Payload : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_Byte
        (Payload, Protocol.Byte (Character'Pos ('n')));
      Protocol.Append_C_String (Payload, File_Name);
      Protocol.Append_C_String (Payload, Location);
      Sessions.Send_Copy_Data
        (Client, Flyology.Bytes.To_Array (Payload), Timeout);
   end Send_Archive_Start;

   procedure Send_Manifest_Start
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_Data
        (Client,
         (1 => Protocol.Byte (Character'Pos ('m'))),
         Timeout);
   end Send_Manifest_Start;

   procedure Send_Data
     (Client  : in out Sessions.Session;
      Major   : Server_Major;
      Data    : Byte_Array;
      Timeout : Duration) is
      Payload : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Major = 14 then
         Sessions.Send_Copy_Data (Client, Data, Timeout);
      else
         Require
           (Data'Length <= Protocol.Maximum_Message_Size - 6,
            "multiplexed backup chunk exceeds the configured limit");
         Protocol.Append_Byte
           (Payload, Protocol.Byte (Character'Pos ('d')));
         Protocol.Append_Bytes (Payload, Data);
         Sessions.Send_Copy_Data
           (Client, Flyology.Bytes.To_Array (Payload), Timeout);
      end if;
   end Send_Data;

   procedure Send_Progress
     (Client          : in out Sessions.Session;
      Bytes_Completed : UInt64;
      Timeout         : Duration) is
      Payload : Byte_Array (1 .. 9);
   begin
      Require
        (Bytes_Completed <= UInt64 (Int64'Last),
         "backup progress must fit PostgreSQL int64");
      Payload (1) := Protocol.Byte (Character'Pos ('p'));
      Flyology.Postgres.Wire.Encode_U64
        (Payload, Position => 1, Value => Bytes_Completed);
      Sessions.Send_Copy_Data (Client, Payload, Timeout);
   end Send_Progress;

   procedure Finish_Stream
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_Done (Client, Timeout);
   end Finish_Stream;

   procedure Send_End_Position
     (Client   : in out Sessions.Session;
      Position : LSN;
      Timeline : UInt32;
      Timeout  : Duration) is
   begin
      Send_Position (Client, Position, Timeline, Timeout);
      Sessions.Send_Command_Complete (Client, "BASE_BACKUP", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_End_Position;

   procedure Begin_Manifest_Upload
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_In_Response
        (Client,
         Overall_Format => Protocol.Text_Format,
         Column_Formats => Protocol.No_Formats,
         Timeout        => Timeout);
   end Begin_Manifest_Upload;

   function Read_Manifest_Command
     (Client : in out Sessions.Session; Timeout : Duration)
      return Protocol.Frontend_Copy_Message is
   begin
      return Sessions.Read_Copy_Command (Client, Timeout);
   end Read_Manifest_Command;

   procedure Complete_Manifest_Upload
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Command_Complete (Client, "UPLOAD_MANIFEST", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Complete_Manifest_Upload;

end Flyology.Postgres.Replication.Base_Backups.Server_Sessions;
