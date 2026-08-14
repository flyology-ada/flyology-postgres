with Ada.Real_Time;
with Flyology.Cancellation;
with Psqlbench_Context;

package Psqlbench_Persistence is

   function State_Path return String;

   procedure Load_And_Reconcile
     (Context  : in out Psqlbench_Context.Context;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last);

   procedure Save (Context : in out Psqlbench_Context.Context);

end Psqlbench_Persistence;
