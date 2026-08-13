with Flyology.Supervision;
with Psqlbench_Context;

package Psqlbench_Logs is

   procedure Execute
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control);

end Psqlbench_Logs;
