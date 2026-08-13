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
     (Link_Empty, Link_Pending, Link_Starting, Link_Running,
      Link_Stopping, Link_Stopped, Link_Failed);

   type Link_Mode is (Logical_Committed, Logical_Streaming);

   type Link_Record is record
      Status        : Link_Status := Link_Empty;
      Mode          : Link_Mode := Logical_Committed;
      Name_Length   : Natural range 0 .. Max_Link_Name_Bytes := 0;
      Name          : String (1 .. Max_Link_Name_Bytes) := (others => ' ');
      Source_Length : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Source        : String (1 .. Max_Instance_Name_Bytes) := (others => ' ');
      Target_Length : Natural range 0 .. Max_Instance_Name_Bytes := 0;
      Target        : String (1 .. Max_Instance_Name_Bytes) := (others => ' ');
      Table_Length  : Natural range 0 .. 63 := 0;
      Table_Name    : String (1 .. 63) := (others => ' ');
      Relay_Port    : Natural range 0 .. 65_535 := 0;
      Change_Count  : Event_Sequence := 0;
      Last_LSN      : Interfaces.Unsigned_64 := 0;
      Detail_Length : Natural range 0 .. Max_Link_Detail_Bytes := 0;
      Detail        : String (1 .. Max_Link_Detail_Bytes) := (others => ' ');
   end record;

   type Link_Array is array (Positive range 1 .. Max_Links) of Link_Record;

   type Link_Command_Kind is (Create_Link, Stop_Link, Remove_Link);

   type Link_Command is record
      Kind        : Link_Command_Kind := Create_Link;
      Name_Length : Natural range 0 .. Max_Link_Name_Bytes := 0;
      Name        : String (1 .. Max_Link_Name_Bytes) := (others => ' ');
   end record;

   type Link_Command_Array is
     array (Positive range 1 .. Link_Command_Capacity) of Link_Command;

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

   protected type Link_Registry is
      procedure Create
        (Name, Source, Target : String;
         Mode     : Link_Mode;
         Accepted : out Boolean;
         Detail   : out String;
         Last     : out Natural);
      procedure Request
        (Name     : String;
         Action   : Link_Command_Kind;
         Accepted : out Boolean);
      procedure Take_Command
        (Value : out Link_Command; Available : out Boolean);
      procedure Set_Status
        (Name : String; Status : Link_Status; Detail : String := "");
      procedure Forget (Name : String);
      procedure Record_Change
        (Name : String; LSN : Interfaces.Unsigned_64);
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
      Links  : Link_Registry;
   end record;

end Psqlbench_Context;
