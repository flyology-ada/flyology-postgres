with Ada.Interrupts.Names;

package Pgish_Signals is

   procedure Complete;
   function Stop_Requested return Boolean;
   function Server_Complete return Boolean;

private
   protected Signals is
      procedure Stop_Term with
        Attach_Handler => Ada.Interrupts.Names.SIGTERM;
      procedure Complete;
      function Stop_Requested return Boolean;
      function Server_Complete return Boolean;
   private
      Stopping : Boolean := False;
      Finished : Boolean := False;
   end Signals;

end Pgish_Signals;
