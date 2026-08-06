with Ada.Strings.Fixed;
with Flyology.Postgres.Protocol;

package body Flyology.Postgres.Replication.Server_Sessions is

   package Protocol renames Flyology.Postgres.Protocol;

   use type UInt32;
   use type UInt64;

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Information;
      end if;
   end Require;

   function Decimal_Image (Value : UInt64) return String is
     (Ada.Strings.Fixed.Trim (UInt64'Image (Value), Ada.Strings.Both));

   function Decimal_Image (Value : UInt32) return String is
     (Ada.Strings.Fixed.Trim (UInt32'Image (Value), Ada.Strings.Both));

   function Timeline_File_Name (Value : UInt32) return String is
      Hexadecimal : constant String := "0123456789ABCDEF";
      Result      : String (1 .. 8) := (others => '0');
      Work        : UInt32 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Hexadecimal (Natural (Work mod 16) + 1);
         Work := Work / 16;
      end loop;
      return Result & ".history";
   end Timeline_File_Name;

   function History_Text (Contents : Byte_Array) return String is
      Result : String (1 .. Contents'Length);
      Cursor : Positive := Result'First;
   begin
      for Item of Contents loop
         Result (Cursor) := Character'Val (Item);
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end History_Text;

   procedure Send_Identify_System
     (Client         : in out Sessions.Session;
      System_Id      : UInt64;
      Timeline       : UInt32;
      Current_WAL    : LSN;
      Database       : String := "";
      Timeout        : Duration) is
   begin
      Require (System_Id > 0, "a primary system identifier must be positive");
      Require (Timeline > 0, "a primary timeline must be positive");
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description ("systemid"),
            Protocol.Make_Field_Description
              ("timeline", Type_Oid => 23, Type_Size => 4),
            Protocol.Make_Field_Description ("xlogpos"),
            Protocol.Make_Field_Description ("dbname")),
         Timeout => Timeout);
      Sessions.Send_Data_Row
        (Client,
         Values =>
           (Protocol.Text_Column (Decimal_Image (System_Id)),
            Protocol.Text_Column (Decimal_Image (Timeline)),
            Protocol.Text_Column (Image (Current_WAL)),
            (if Database'Length = 0
             then Protocol.Null_Column
             else Protocol.Text_Column (Database))),
         Timeout => Timeout);
      Sessions.Send_Command_Complete
        (Client, "IDENTIFY_SYSTEM", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_Identify_System;

   procedure Send_Show
     (Client    : in out Sessions.Session;
      Parameter : String;
      Value     : String;
      Timeout   : Duration) is
   begin
      Sessions.Send_Row_Description
        (Client, Parameter, Timeout => Timeout);
      Sessions.Send_Data_Row (Client, Value, Timeout);
      Sessions.Send_Command_Complete (Client, "SHOW", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_Show;

   procedure Send_Timeline_History
     (Client   : in out Sessions.Session;
      Timeline : UInt32;
      Contents : Byte_Array;
      Timeout  : Duration) is
      File_Name : constant String := Timeline_File_Name (Timeline);
   begin
      Require (Timeline > 0, "a timeline history number must be positive");
      Require
        (Contents'Length <= Protocol.Maximum_Message_Size - 64,
         "timeline history exceeds the configured message limit");
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description ("filename"),
            Protocol.Make_Field_Description ("content")),
         Timeout => Timeout);
      Sessions.Send_Data_Row
        (Client,
         Values =>
           (Protocol.Text_Column (File_Name),
            Protocol.Text_Column (History_Text (Contents))),
         Timeout => Timeout);
      Sessions.Send_Command_Complete
        (Client, "TIMELINE_HISTORY", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_Timeline_History;

   procedure Send_Create_Logical_Slot
     (Client           : in out Sessions.Session;
      Slot_Name        : String;
      Consistent_Point : LSN;
      Plugin           : String;
      Snapshot_Name    : String := "";
      Timeout          : Duration) is
   begin
      Require (Slot_Name'Length > 0, "a replication slot name is required");
      Require (Plugin'Length > 0, "a logical output plugin is required");
      Sessions.Send_Row_Description
        (Client,
         Columns =>
           (Protocol.Make_Field_Description ("slot_name"),
            Protocol.Make_Field_Description ("consistent_point"),
            Protocol.Make_Field_Description ("snapshot_name"),
            Protocol.Make_Field_Description ("output_plugin")),
         Timeout => Timeout);
      Sessions.Send_Data_Row
        (Client,
         Values =>
           (Protocol.Text_Column (Slot_Name),
            Protocol.Text_Column (Image (Consistent_Point)),
            (if Snapshot_Name'Length = 0
             then Protocol.Null_Column
             else Protocol.Text_Column (Snapshot_Name)),
            Protocol.Text_Column (Plugin)),
         Timeout => Timeout);
      Sessions.Send_Command_Complete
        (Client, "CREATE_REPLICATION_SLOT", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_Create_Logical_Slot;

   procedure Send_Drop_Replication_Slot
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Command_Complete
        (Client, "DROP_REPLICATION_SLOT", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Send_Drop_Replication_Slot;

   procedure Begin_Streaming
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_Both_Response
        (Client,
         Overall_Format => Protocol.Text_Format,
         Column_Formats => Protocol.No_Formats,
         Timeout => Timeout);
   end Begin_Streaming;

   procedure Send_XLog_Data
     (Client    : in out Sessions.Session;
      WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array;
      Timeout   : Duration) is
   begin
      Sessions.Send
        (Client,
         Make_XLog_Data (WAL_Start, WAL_End, Sent_At, Data),
         Timeout);
   end Send_XLog_Data;

   procedure Send_Primary_Keepalive
     (Client          : in out Sessions.Session;
      WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False;
      Timeout         : Duration) is
   begin
      Sessions.Send
        (Client,
         Make_Primary_Keepalive
           (WAL_End, Sent_At, Reply_Requested),
         Timeout);
   end Send_Primary_Keepalive;

   function Read_Standby_Message
     (Client : in out Sessions.Session; Timeout : Duration)
      return Stream_Message is
   begin
      return Decode (Sessions.Read_Command (Client, Timeout));
   end Read_Standby_Message;

   procedure Finish_Streaming
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Copy_Done (Client, Timeout);
   end Finish_Streaming;

   procedure Complete_Streaming
     (Client : in out Sessions.Session; Timeout : Duration) is
   begin
      Sessions.Send_Command_Complete
        (Client, "START_REPLICATION", Timeout);
      Sessions.Send_Ready (Client, Timeout => Timeout);
   end Complete_Streaming;

end Flyology.Postgres.Replication.Server_Sessions;
