with Interfaces;

package Psqlbench_Context is

   Max_Event_Bytes : constant := 1_024;
   Event_Capacity  : constant := 256;
   Max_Instance_Name_Bytes : constant := 40;
   Max_Log_Bytes : constant := 2_048;
   Log_Capacity  : constant := 1_024;

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

   type Context is limited record
      Events : aliased Event_Log;
      Logs   : aliased Log_Store;
      Docker : Docker_Status;
   end record;

end Psqlbench_Context;
