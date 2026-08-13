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

   function Create_Instance
     (Name     : String;
      Version  : String;
      Port     : Positive;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

   type Instance_Action is (Start_Instance, Stop_Instance, Remove_Instance);

   function Apply
     (Name     : String;
      Action   : Instance_Action;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result;

end Psqlbench_Docker;
