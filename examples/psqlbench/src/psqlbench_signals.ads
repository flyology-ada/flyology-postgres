with Ada.Interrupts.Names;

package Psqlbench_Signals is

   function Stop_Requested return Boolean;
   procedure Complete;
   function Completed return Boolean;

private
   protected State is
      procedure Request_Stop with
        Attach_Handler => Ada.Interrupts.Names.SIGTERM;
      procedure Mark_Complete;
      function Stop_Requested return Boolean;
      function Completed return Boolean;
   private
      Stop : Boolean := False;
      Done : Boolean := False;
   end State;

end Psqlbench_Signals;
