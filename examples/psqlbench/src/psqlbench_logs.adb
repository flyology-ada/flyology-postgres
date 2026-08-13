with Ada.Real_Time;
with Ada.Strings.Bounded;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.Cancellation;
with Psqlbench_Docker;
with Psqlbench_JSON;

package body Psqlbench_Logs is

   package Names is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => Psqlbench_Context.Max_Instance_Name_Bytes);
   package Timestamps is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => 64);
   package Lines is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => Psqlbench_Context.Max_Log_Bytes);

   Max_Instances : constant := 32;

   function Ready_Document return String is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "type", "logs.ready");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Ready_Document;

   type Tracker is record
      Active    : Boolean := False;
      Seen      : Boolean := False;
      Initial   : Boolean := True;
      Name      : Names.Bounded_String;
      Since     : Timestamps.Bounded_String;
      Last_Line : Lines.Bounded_String;
   end record;

   type Tracker_Array is array (Positive range 1 .. Max_Instances) of Tracker;

   function Timestamp_Of (Line : String) return String is
      Space : constant Natural := Ada.Strings.Fixed.Index (Line, " ");
   begin
      return
        (if Space = 0 then ""
         else Line (Line'First .. Space - 1));
   end Timestamp_Of;

   procedure For_Each_Line
     (Value  : String;
      Visit  : not null access procedure (Line : String))
   is
      First : Natural := Value'First;
   begin
      while First <= Value'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Value'Last
              and then Value (Last) not in ASCII.LF | ASCII.CR
            loop
               Last := Last + 1;
            end loop;
            if Last > First then
               Visit (Value (First .. Last - 1));
            end if;
            while Last <= Value'Last
              and then Value (Last) in ASCII.LF | ASCII.CR
            loop
               Last := Last + 1;
            end loop;
            First := Last;
         end;
      end loop;
   end For_Each_Line;

   procedure Execute
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      use type Ada.Real_Time.Time;
      Trackers : Tracker_Array;
      Ready    : Boolean := False;

      function Find_Or_Create (Name : String) return Positive is
      begin
         for Index in Trackers'Range loop
            if Trackers (Index).Active
              and then Names.To_String (Trackers (Index).Name) = Name
            then
               return Index;
            end if;
         end loop;
         for Index in Trackers'Range loop
            if not Trackers (Index).Active then
               Trackers (Index) := (others => <>);
               Trackers (Index).Active := True;
               Trackers (Index).Seen := True;
               Trackers (Index).Name := Names.To_Bounded_String (Name);
               return Index;
            end if;
         end loop;
         raise Program_Error with "psqlbench log collector instance limit reached";
      end Find_Or_Create;

      procedure Collect (Index : Positive) is
         Item : Tracker renames Trackers (Index);
         Name : constant String := Names.To_String (Item.Name);
         Value : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Logs
             (Name,
              Since => Timestamps.To_String (Item.Since),
              Initial => Item.Initial,
              Token => Flyology.Supervision.Stopping (Control.all),
              Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5));
         Previous : constant String := Lines.To_String (Item.Last_Line);
         Found_Previous : Boolean := Item.Initial or else Previous'Length = 0;

         procedure Consume (Line : String) is
            Stamp : constant String := Timestamp_Of (Line);
         begin
            if not Found_Previous then
               if Line = Previous then
                  Found_Previous := True;
               end if;
               return;
            end if;
            Context.Logs.Append (Name, Line);
            Item.Last_Line := Lines.To_Bounded_String
              (Line (Line'First ..
                 Line'First + Natural'Min
                   (Line'Length, Lines.Max_Length) - 1));
            if Stamp'Length > 0 and then Stamp'Length <= Timestamps.Max_Length
            then
               Item.Since := Timestamps.To_Bounded_String (Stamp);
            end if;
         end Consume;
      begin
         if not Value.Success then
            return;
         end if;
         For_Each_Line (Psqlbench_Docker.Text (Value), Consume'Access);
         if not Found_Previous then
            Found_Previous := True;
            For_Each_Line (Psqlbench_Docker.Text (Value), Consume'Access);
         end if;
         Item.Initial := False;
      end Collect;

      procedure Scan is
         Value : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.List_Instance_Names
             (Flyology.Supervision.Stopping (Control.all),
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5));

         procedure See (Name : String) is
            Index : Positive;
         begin
            if Name'Length = 0
              or else Name'Length > Psqlbench_Context.Max_Instance_Name_Bytes
            then
               return;
            end if;
            Index := Find_Or_Create (Name);
            Trackers (Index).Seen := True;
            Collect (Index);
         end See;
      begin
         if not Value.Success then
            raise Program_Error with
              "cannot list instances for log collection: "
              & Psqlbench_Docker.Text (Value);
         end if;
         for Item of Trackers loop
            Item.Seen := False;
         end loop;
         For_Each_Line (Psqlbench_Docker.Text (Value), See'Access);
         for Item of Trackers loop
            if Item.Active and then not Item.Seen then
               Item := (others => <>);
            end if;
         end loop;
      end Scan;
   begin
      loop
         Scan;
         if not Ready then
            Context.Events.Append (Ready_Document);
            Flyology.Supervision.Mark_Ready (Control.all);
            Ready := True;
         end if;
         for Step in 1 .. 10 loop
            if Flyology.Supervision.Stopping (Control.all).Requested then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            delay 0.050;
         end loop;
      end loop;
   end Execute;

end Psqlbench_Logs;
