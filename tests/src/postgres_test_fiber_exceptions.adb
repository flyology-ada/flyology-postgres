with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;

procedure Postgres_Test_Fiber_Exceptions is

   Marker : constant String := "Flyology fiber exception smoke";

   protected Result is
      procedure Complete (Succeeded : Boolean);
      entry Await (Succeeded : out Boolean);
   private
      Done : Boolean := False;
      Good : Boolean := False;
   end Result;

   protected body Result is
      procedure Complete (Succeeded : Boolean) is
      begin
         Good := Succeeded;
         Done := True;
      end Complete;

      entry Await (Succeeded : out Boolean) when Done is
      begin
         Succeeded := Good;
      end Await;
   end Result;

   task Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
   begin
      begin
         raise Program_Error with Marker;
      exception
         when Error : Program_Error =>
            Result.Complete
              (Ada.Exceptions.Exception_Message (Error) = Marker);
         when others =>
            Result.Complete (False);
      end;
   end Worker;

   Succeeded : Boolean;
begin
   Result.Await (Succeeded);
   if not Succeeded then
      raise Program_Error with
        "an exception raised on a Flyology fiber was not reported normally";
   end if;
   Ada.Text_IO.Put_Line ("Flyology fiber exception reporting passed");
end Postgres_Test_Fiber_Exceptions;
