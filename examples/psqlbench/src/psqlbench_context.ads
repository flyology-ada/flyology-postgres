with Interfaces;

package Psqlbench_Context is

   Max_Event_Bytes : constant := 1_024;
   Event_Capacity  : constant := 256;
   Max_Instance_Name_Bytes : constant := 40;
   Max_Log_Bytes : constant := 2_048;
   Log_Capacity  : constant := 1_024;
   Max_Links     : constant := 8;
   Link_Command_Capacity : constant := 16;
   Max_Link_Name_Bytes : constant := 24;
   Max_Link_Detail_Bytes : constant := 192;
   Max_Column_Map_Bytes : constant := 2_048;
   Max_Instances : constant := 32;

   subtype Event_Sequence is Interfaces.Unsigned_64;

   type Event_Record is record
      Sequence : Event_Sequence := 0;
      Length   : Natural range 0 .. Max_Event_Bytes := 0;
      Data     : String (1 .. Max_Event_Bytes) := (others => ' ');
   end record;

   type Event_Array is array (Positive range <>) of Event_Record;

   type Log_Record is record
      Sequence    : Event_Sequence := 0;
      Name_Length : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Name        : String (1 .. Max_Instance_Name_Bytes) := (others => ' ');
      Data_Length : Natural range 0 .. Max_Log_Bytes := 0;
      Data        : String (1 .. Max_Log_Bytes) := (others => ' ');
   end record;

   type Log_Array is array (Positive range <>) of Log_Record;

   type Link_Status is
     (Link_Empty, Link_Pending, Link_Restoring, Link_Starting, Link_Running,
      Link_Stopping, Link_Stopped, Link_Failed);

   type Link_Mode is
     (Logical_Committed, Logical_Streaming,
      Logical_Two_Phase, Logical_Two_Phase_Streaming,
      Physical_Streaming);

   Max_Fault_Latency_Milliseconds : constant := 5_000;
   Min_Fault_Bandwidth_Kib : constant := 16;
   Max_Fault_Bandwidth_Kib : constant := 10_240;

   type Fault_Profile is record
      Paused : Boolean := False;
      Latency_Milliseconds : Natural range
        0 .. Max_Fault_Latency_Milliseconds := 0;
      Bandwidth_Kib_Per_Second : Natural range
        0 .. Max_Fault_Bandwidth_Kib := 0;
   end record;

   type Link_Record is record
      Status        : Link_Status := Link_Empty;
      Mode          : Link_Mode := Logical_Committed;
      Name_Length   : Natural range 0 .. Max_Link_Name_Bytes := 0;
      Name          : String (1 .. Max_Link_Name_Bytes) := (others => ' ');
      Source_Length : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Source        : String (1 .. Max_Instance_Name_Bytes) := (others => ' ');
      Target_Length : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Target        : String (1 .. Max_Instance_Name_Bytes) := (others => ' ');
      Target_Version_Length : Natural range 0 .. 16 := 0;
      Target_Version : String (1 .. 16) := (others => ' ');
      Target_Port   : Natural range 0 .. 65_535 := 0;
      Table_Length  : Natural range 0 .. 63 := 0;
      Table_Name    : String (1 .. 63) := (others => ' ');
      Source_Schema_Length : Natural range 0 .. 63 := 0;
      Source_Schema : String (1 .. 63) := (others => ' ');
      Source_Table_Length : Natural range 0 .. 63 := 0;
      Source_Table : String (1 .. 63) := (others => ' ');
      Target_Schema_Length : Natural range 0 .. 63 := 0;
      Target_Schema : String (1 .. 63) := (others => ' ');
      Target_Table_Length : Natural range 0 .. 63 := 0;
      Target_Table : String (1 .. 63) := (others => ' ');
      Column_Map_Length : Natural range 0 .. Max_Column_Map_Bytes := 0;
      Column_Map : String (1 .. Max_Column_Map_Bytes) := (others => ' ');
      Relay_Port    : Natural range 0 .. 65_535 := 0;
      Change_Count  : Event_Sequence := 0;
      Start_LSN     : Interfaces.Unsigned_64 := 0;
      Last_LSN      : Interfaces.Unsigned_64 := 0;
      Applied_LSN   : Interfaces.Unsigned_64 := 0;
      Faults         : Fault_Profile;
      Disconnect_Count : Event_Sequence := 0;
      Desired_Running : Boolean := True;
      Detail_Length : Natural range 0 .. Max_Link_Detail_Bytes := 0;
      Detail        : String (1 .. Max_Link_Detail_Bytes) := (others => ' ');
   end record;

   type Link_Array is array (Positive range 1 .. Max_Links) of Link_Record;

   type Link_Command_Kind is
     (Create_Link, Stop_Link, Restart_Link, Remove_Link);

   type Link_Command is record
      Kind        : Link_Command_Kind := Create_Link;
      Name_Length : Natural range 0 .. Max_Link_Name_Bytes := 0;
      Name        : String (1 .. Max_Link_Name_Bytes) := (others => ' ');
   end record;

   type Link_Command_Array is
     array (Positive range 1 .. Link_Command_Capacity) of Link_Command;

   type Instance_Record is record
      Occupied       : Boolean := False;
      Desired_Running : Boolean := True;
      Name_Length    : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Name           : String (1 .. Max_Instance_Name_Bytes) :=
        (others => ' ');
      Version_Length : Natural range 0 .. 16 := 0;
      Version        : String (1 .. 16) := (others => ' ');
      Port           : Natural range 0 .. 65_535 := 0;
   end record;

   type Instance_Array is
     array (Positive range 1 .. Max_Instances) of Instance_Record;

   protected type Event_Log is
      procedure Append (Value : String);
      procedure Read_After
        (After     : Event_Sequence;
         Value     : out Event_Record;
         Available : out Boolean;
         Dropped   : out Event_Sequence);
   private
      Events        : Event_Array (1 .. Event_Capacity);
      Head          : Positive := 1;
      Count         : Natural range 0 .. Event_Capacity := 0;
      Next_Sequence : Event_Sequence := 1;
   end Event_Log;

   protected type Log_Store is
      procedure Append (Name : String; Value : String);
      procedure Read_After
        (Name      : String;
         After     : Event_Sequence;
         Value     : out Log_Record;
         Available : out Boolean);
   private
      Entries       : Log_Array (1 .. Log_Capacity);
      Head          : Positive := 1;
      Count         : Natural range 0 .. Log_Capacity := 0;
      Next_Sequence : Event_Sequence := 1;
   end Log_Store;

   protected type Docker_Status is
      procedure Set (Ready : Boolean; Detail : String);
      function Ready return Boolean;
      procedure Read_Detail
        (Value : out String; Last : out Natural);
   private
      Is_Ready     : Boolean := False;
      Detail_Size  : Natural range 0 .. 256 := 0;
      Detail_Value : String (1 .. 256) := (others => ' ');
   end Docker_Status;

   protected type Instance_Registry is
      procedure Upsert
        (Name, Version : String;
         Port          : Natural;
         Running       : Boolean;
         Accepted      : out Boolean);
      procedure Set_Running
        (Name : String; Running : Boolean; Accepted : out Boolean);
      procedure Forget (Name : String);
      procedure Clear;
      procedure Snapshot (Value : out Instance_Array; Count : out Natural);
   private
      Entries : Instance_Array;
   end Instance_Registry;

   protected type Link_Registry is
      procedure Create
        (Name, Source, Target : String;
         Mode     : Link_Mode;
         Source_Schema, Source_Table : String;
         Target_Schema, Target_Table : String;
         Target_Version : String;
         Target_Port : Natural;
         Accepted : out Boolean;
         Detail   : out String;
         Last     : out Natural;
         Desired_Running : Boolean := True;
         Restoring : Boolean := False;
         Column_Map : String := "");
      procedure Request
        (Name     : String;
         Action   : Link_Command_Kind;
         Accepted : out Boolean);
      procedure Request_Remove_All (Count : out Natural);
      procedure Take_Command
        (Value : out Link_Command; Available : out Boolean);
      procedure Set_Status
        (Name : String; Status : Link_Status; Detail : String := "");
      procedure Forget (Name : String);
      procedure Record_Change
        (Name : String; LSN : Interfaces.Unsigned_64);
      procedure Record_Start
        (Name : String; LSN : Interfaces.Unsigned_64);
      procedure Record_Applied
        (Name : String; LSN : Interfaces.Unsigned_64);
      procedure Record_Observed
        (Name : String; LSN : Interfaces.Unsigned_64);
      procedure Configure_Faults
        (Name : String;
         Paused : Boolean;
         Latency_Milliseconds : Natural;
         Bandwidth_Kib_Per_Second : Natural;
         Accepted : out Boolean);
      procedure Trigger_Disconnect
        (Name : String; Accepted : out Boolean);
      function Read_Faults (Name : String) return Fault_Profile;
      function References_Instance (Name : String) return Boolean;
      procedure Snapshot (Value : out Link_Array; Count : out Natural);
   private
      Entries : Link_Array;
      Commands : Link_Command_Array;
      Command_Head : Positive := 1;
      Command_Count : Natural range 0 .. Link_Command_Capacity := 0;
   end Link_Registry;

   type Context is limited record
      Events : aliased Event_Log;
      Logs   : aliased Log_Store;
      Docker : Docker_Status;
      Instances : Instance_Registry;
      Links  : Link_Registry;
   end record;

end Psqlbench_Context;
