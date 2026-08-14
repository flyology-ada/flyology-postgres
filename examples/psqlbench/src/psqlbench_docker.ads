with Ada.Real_Time;
with Flyology.Cancellation;

package Psqlbench_Docker is

   Max_Output_Bytes : constant := 64 * 1_024;

   type Result is record
      Success   : Boolean := False;
      Exit_Code : Integer := -1;
      Length    : Natural range 0 .. Max_Output_Bytes := 0;
      Output    : String (1 .. Max_Output_Bytes) := (others => ' ');
      Truncated : Boolean := False;
   end record;

   function Text (Item : Result) return String;

   procedure Start;
   procedure Shutdown;

   function Check
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Ensure_Network
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function List_Instances
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function List_Instance_Names
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Instance_Port
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Instance_Version
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Instance_Role
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Inspect_Instance
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Enable_Replication_Access
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Logs
     (Name     : String;
      Since    : String;
      Initial  : Boolean;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Create_Instance
     (Name     : String;
      Version  : String;
      Port     : Positive;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   function Bootstrap_Physical_Standby
     (Name       : String;
      Version    : String;
      Port       : Positive;
      Slot       : String;
      Relay_Port : Positive;
      Archive_Path : String;
      Token      : access Flyology.Cancellation.Token := null;
      Deadline   : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
      return Result;

   type Instance_Action is (Start_Instance, Stop_Instance, Remove_Instance);

   function Apply
     (Name     : String;
      Action   : Instance_Action;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

end Psqlbench_Docker;
