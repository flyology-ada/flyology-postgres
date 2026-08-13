package body Psqlbench_Signals is

   protected body State is
      procedure Request_Stop is
      begin
         Stop := True;
      end Request_Stop;

      procedure Mark_Complete is
      begin
         Done := True;
      end Mark_Complete;

      function Stop_Requested return Boolean is (Stop);
      function Completed return Boolean is (Done);
   end State;

   function Stop_Requested return Boolean is (State.Stop_Requested);

   procedure Complete is
   begin
      State.Mark_Complete;
   end Complete;

   function Completed return Boolean is (State.Completed);

end Psqlbench_Signals;
