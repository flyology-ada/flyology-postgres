with Ada.Calendar;
with Ada.Task_Identification;
with Pgish_SQL;

package Pgish_State is

   Maximum_Sessions : constant := 16;
   Maximum_Commits  : constant := 32;

   subtype Name_Text is Pgish_SQL.Name_Text;
   subtype Value_Text is Pgish_SQL.Value_Text;
   subtype Path_Text is Pgish_SQL.Text (1_024);
   subtype Query_Text is
     Pgish_SQL.Text (Pgish_SQL.Maximum_Query_Length);

   type Configuration is record
      Host            : Name_Text;
      Port            : Natural range 1 .. 65_535 := 55_432;
      Repository_Path : Path_Text;
      Task_Mode       : Name_Text;
      Started_At      : Ada.Calendar.Time := Ada.Calendar.Clock;
   end record;

   type Commit is record
      Hash         : Name_Text;
      Short_Hash   : Name_Text;
      Author       : Value_Text;
      Committed_At : Name_Text;
      Subject      : Value_Text;
   end record;
   type Commit_Array is array (Positive range 1 .. Maximum_Commits) of Commit;

   type Session_Snapshot is record
      Session_Id      : Natural := 0;
      User_Name       : Name_Text;
      Database_Name   : Name_Text;
      Application_Name : Name_Text;
      Query_Count     : Natural := 0;
      Connected_At    : Ada.Calendar.Time := Ada.Calendar.Clock;
      State           : Name_Text;
      Current_Query   : Value_Text;
   end record;
   type Session_Array is
     array (Positive range 1 .. Maximum_Sessions) of Session_Snapshot;

   type Server_State is limited private;

   procedure Initialize
     (Item : in out Server_State; Config : Configuration);
   function Config (Item : Server_State) return Configuration;
   function Repository_Head (Item : Server_State) return String;
   procedure Repository_Commits
     (Item : Server_State; Values : out Commit_Array; Count : out Natural);

   procedure Register_Session
     (Item             : in out Server_State;
      User_Name        : String;
      Database_Name    : String;
      Application_Name : String;
      Accepted         : out Boolean);
   procedure Begin_Query
     (Item : in out Server_State; SQL : String; Session : out Session_Snapshot);
   procedure Current_Session
     (Item : in out Server_State; Session : out Session_Snapshot);
   procedure End_Query (Item : in out Server_State);
   procedure Remove_Session (Item : in out Server_State);
   procedure Sessions
     (Item : in out Server_State;
      Values : out Session_Array;
      Count : out Natural);
   procedure Store_Statement
     (Item : in out Server_State; Name : String; SQL : String);
   procedure Bind_Portal
     (Item : in out Server_State; Portal_Name : String; Statement_Name : String);
   function Statement_SQL
     (Item : Server_State; Name : String; Found : out Boolean) return String;
   function Portal_SQL
     (Item : Server_State; Name : String; Found : out Boolean) return String;
   procedure Close_Extended
     (Item : in out Server_State; Portal : Boolean; Name : String);
   procedure Set_Extended_Failed (Item : in out Server_State; Value : Boolean);
   function Extended_Failed (Item : Server_State) return Boolean;

private
   subtype Task_Id is Ada.Task_Identification.Task_Id;

   type Session_Slot is record
      Occupied : Boolean := False;
      Owner    : Task_Id := Ada.Task_Identification.Null_Task_Id;
      Value    : Session_Snapshot;
      Statement_Name : Name_Text;
      Statement_SQL  : Query_Text;
      Portal_Name    : Name_Text;
      Portal_SQL     : Query_Text;
      Failed_Extended : Boolean := False;
   end record;
   type Session_Slot_Array is
     array (Positive range 1 .. Maximum_Sessions) of Session_Slot;

   protected type Session_Registry is
      procedure Register
        (Owner            : Task_Id;
         User_Name        : String;
         Database_Name    : String;
         Application_Name : String;
         Accepted         : out Boolean);
      procedure Begin_Query
        (Owner : Task_Id; SQL : String; Session : out Session_Snapshot);
      procedure End_Query (Owner : Task_Id);
      procedure Current (Owner : Task_Id; Session : out Session_Snapshot);
      procedure Remove (Owner : Task_Id);
      procedure Snapshot (Values : out Session_Array; Count : out Natural);
      procedure Store_Statement
        (Owner : Task_Id; Name : String; SQL : String);
      procedure Bind_Portal
        (Owner : Task_Id; Portal_Name : String; Statement_Name : String);
      function Get_SQL
        (Owner : Task_Id; Portal : Boolean; Name : String) return Query_Text;
      procedure Close_Extended
        (Owner : Task_Id; Portal : Boolean; Name : String);
      procedure Set_Failed (Owner : Task_Id; Value : Boolean);
      function Is_Failed (Owner : Task_Id) return Boolean;
   private
      Slots   : Session_Slot_Array;
      Next_Id : Natural := 1;
   end Session_Registry;

   type Server_State is limited record
      Settings     : Configuration;
      Head         : Name_Text;
      Commit_Data  : Commit_Array;
      Commit_Count : Natural range 0 .. Maximum_Commits := 0;
      Registry     : Session_Registry;
   end record;

end Pgish_State;
