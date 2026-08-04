package body Pgish_Signals is

   protected body Signals is
      procedure Stop_Term is
      begin
         Stopping := True;
      end Stop_Term;

      procedure Complete is
      begin
         Finished := True;
      end Complete;

      function Stop_Requested return Boolean is (Stopping);
      function Server_Complete return Boolean is (Finished);
   end Signals;

   procedure Complete is
   begin
      Signals.Complete;
   end Complete;

   function Stop_Requested return Boolean is (Signals.Stop_Requested);
   function Server_Complete return Boolean is (Signals.Server_Complete);

end Pgish_Signals;
