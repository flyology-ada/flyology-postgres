with Psqlbench_JSON;

package body Psqlbench_Context is

   function Managed_Table_Name (Name : String) return String is
      Result : String := "psqlbench_" & Name;
   begin
      for Index in Result'Range loop
         if Result (Index) = '-' then
            Result (Index) := '_';
         end if;
      end loop;
      return Result;
   end Managed_Table_Name;

   use type Event_Sequence;

   function Event_Too_Large return String is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value
        (Document, "type", "event-too-large");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Event_Too_Large;

   protected body Event_Log is
      procedure Append (Value : String) is
         Stored : constant String :=
           (if Value'Length <= Max_Event_Bytes
            then Value
            else Event_Too_Large);
         Slot : Positive;
      begin
         if Count = Event_Capacity then
            Slot := Head;
            Head := (if Head = Event_Capacity then 1 else Head + 1);
         else
            Slot := ((Head - 1 + Count) mod Event_Capacity) + 1;
            Count := Count + 1;
         end if;
         Events (Slot).Sequence := Next_Sequence;
         Events (Slot).Length := Stored'Length;
         Events (Slot).Data (1 .. Stored'Length) := Stored;
         Next_Sequence := Next_Sequence + 1;
      end Append;

      procedure Read_After
        (After     : Event_Sequence;
         Value     : out Event_Record;
         Available : out Boolean;
         Dropped   : out Event_Sequence)
      is
         Slot : Positive;
      begin
         Value := (others => <>);
         Available := False;
         Dropped := 0;
         if Count = 0 then
            return;
         end if;
         for Offset in 0 .. Count - 1 loop
            Slot := ((Head - 1 + Offset) mod Event_Capacity) + 1;
            if Events (Slot).Sequence > After then
               Value := Events (Slot);
               Available := True;
               Dropped := Events (Slot).Sequence - After - 1;
               return;
            end if;
         end loop;
      end Read_After;
   end Event_Log;

   protected body Log_Store is
      procedure Append (Name : String; Value : String) is
         Slot : Positive;
         Name_Size : constant Natural :=
           Natural'Min (Name'Length, Max_Instance_Name_Bytes);
         Data_Size : constant Natural :=
           Natural'Min (Value'Length, Max_Log_Bytes);
      begin
         if Count = Log_Capacity then
            Slot := Head;
            Head := (if Head = Log_Capacity then 1 else Head + 1);
         else
            Slot := ((Head - 1 + Count) mod Log_Capacity) + 1;
            Count := Count + 1;
         end if;
         Entries (Slot) := (others => <>);
         Entries (Slot).Sequence := Next_Sequence;
         Entries (Slot).Name_Length := Name_Size;
         Entries (Slot).Data_Length := Data_Size;
         if Name_Size > 0 then
            Entries (Slot).Name (1 .. Name_Size) :=
              Name (Name'First .. Name'First + Name_Size - 1);
         end if;
         if Data_Size > 0 then
            Entries (Slot).Data (1 .. Data_Size) :=
              Value (Value'First .. Value'First + Data_Size - 1);
         end if;
         Next_Sequence := Next_Sequence + 1;
      end Append;

      procedure Read_After
        (Name      : String;
         After     : Event_Sequence;
         Value     : out Log_Record;
         Available : out Boolean)
      is
         Slot : Positive;
      begin
         Value := (others => <>);
         Available := False;
         if Count = 0 then
            return;
         end if;
         for Offset in 0 .. Count - 1 loop
            Slot := ((Head - 1 + Offset) mod Log_Capacity) + 1;
            if Entries (Slot).Sequence > After
              and then Entries (Slot).Name_Length = Name'Length
              and then Entries (Slot).Name (1 .. Name'Length) = Name
            then
               Value := Entries (Slot);
               Available := True;
               return;
            end if;
         end loop;
      end Read_After;
   end Log_Store;

   protected body Docker_Status is
      procedure Set (Ready : Boolean; Detail : String) is
      begin
         Is_Ready := Ready;
         Detail_Size := Natural'Min (Detail'Length, Detail_Value'Length);
         if Detail_Size > 0 then
            Detail_Value (1 .. Detail_Size) :=
              Detail (Detail'First .. Detail'First + Detail_Size - 1);
         end if;
      end Set;

      function Ready return Boolean is (Is_Ready);

      procedure Read_Detail
        (Value : out String; Last : out Natural) is
      begin
         Last := Natural'Min (Detail_Size, Value'Length);
         if Last > 0 then
            Value (Value'First .. Value'First + Last - 1) :=
              Detail_Value (1 .. Last);
         end if;
      end Read_Detail;
   end Docker_Status;

   protected body Instance_Registry is
      function Same_Name
        (Item : Instance_Record; Name : String) return Boolean is
        (Item.Occupied
         and then Item.Name_Length = Name'Length
         and then Item.Name (1 .. Item.Name_Length) = Name);

      procedure Store
        (Target : out String; Length : out Natural; Value : String) is
      begin
         Length := Natural'Min (Target'Length, Value'Length);
         Target := (others => ' ');
         if Length > 0 then
            Target (Target'First .. Target'First + Length - 1) :=
              Value (Value'First .. Value'First + Length - 1);
         end if;
      end Store;

      procedure Upsert
        (Name, Version : String;
         Port          : Natural;
         Running       : Boolean;
         Accepted      : out Boolean)
      is
         Slot : Natural := 0;
      begin
         Accepted := False;
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Slot := Index;
               exit;
            elsif Slot = 0 and then not Entries (Index).Occupied then
               Slot := Index;
            end if;
         end loop;
         if Slot = 0 then
            return;
         end if;
         Entries (Slot) := (others => <>);
         Entries (Slot).Occupied := True;
         Entries (Slot).Desired_Running := Running;
         Store
           (Entries (Slot).Name, Entries (Slot).Name_Length, Name);
         Store
           (Entries (Slot).Version, Entries (Slot).Version_Length, Version);
         Entries (Slot).Port := Port;
         Accepted := True;
      end Upsert;

      procedure Set_Running
        (Name : String; Running : Boolean; Accepted : out Boolean) is
      begin
         Accepted := False;
         for Item of Entries loop
            if Same_Name (Item, Name) then
               Item.Desired_Running := Running;
               Accepted := True;
               return;
            end if;
         end loop;
      end Set_Running;

      procedure Forget (Name : String) is
      begin
         for Item of Entries loop
            if Same_Name (Item, Name) then
               Item := (others => <>);
               return;
            end if;
         end loop;
      end Forget;

      procedure Clear is
      begin
         Entries := (others => <>);
      end Clear;

      procedure Snapshot
        (Value : out Instance_Array; Count : out Natural) is
      begin
         Value := (others => <>);
         Count := 0;
         for Item of Entries loop
            if Item.Occupied then
               Count := Count + 1;
               Value (Count) := Item;
            end if;
         end loop;
      end Snapshot;
   end Instance_Registry;

   protected body Link_Registry is
      function Same_Name (Item : Link_Record; Name : String) return Boolean is
        (Item.Status /= Link_Empty
         and then Item.Name_Length = Name'Length
         and then Item.Name (1 .. Item.Name_Length) = Name);

      procedure Store
        (Target : out String; Length : out Natural; Value : String) is
      begin
         Length := Natural'Min (Target'Length, Value'Length);
         Target := (others => ' ');
         if Length > 0 then
            Target (Target'First .. Target'First + Length - 1) :=
              Value (Value'First .. Value'First + Length - 1);
         end if;
      end Store;

      procedure Enqueue (Kind : Link_Command_Kind; Name : String) is
         Slot : Positive;
      begin
         if Command_Count = Link_Command_Capacity then
            raise Constraint_Error with "link command queue is full";
         end if;
         Slot := ((Command_Head - 1 + Command_Count)
                  mod Link_Command_Capacity) + 1;
         Commands (Slot) := (others => <>);
         Commands (Slot).Kind := Kind;
         Store
           (Commands (Slot).Name, Commands (Slot).Name_Length, Name);
         Command_Count := Command_Count + 1;
      end Enqueue;

      procedure Create
        (Name, Source, Target : String;
         Mode     : Link_Mode;
         Source_Schema, Source_Table : String;
         Target_Schema, Target_Table : String;
         Target_Version : String;
         Target_Port : Natural;
         Accepted : out Boolean;
         Detail   : out String;
         Last     : out Natural;
         Desired_Running : Boolean := True;
         Restoring : Boolean := False;
         Column_Map : String := "")
      is
         Free : Natural := 0;
      begin
         Accepted := False;
         Last := 0;
         Detail := (others => ' ');
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               declare
                  Message : constant String := "link name is already in use";
               begin
                  Last := Natural'Min (Message'Length, Detail'Length);
                  Detail (Detail'First .. Detail'First + Last - 1) :=
                    Message (Message'First .. Message'First + Last - 1);
               end;
               return;
            elsif Free = 0 and then Entries (Index).Status = Link_Empty then
               Free := Index;
            end if;
         end loop;
         if Free = 0 or else Command_Count = Link_Command_Capacity then
            declare
               Message : constant String :=
                 "replication link capacity is full";
            begin
               Last := Natural'Min (Message'Length, Detail'Length);
               Detail (Detail'First .. Detail'First + Last - 1) :=
                 Message (Message'First .. Message'First + Last - 1);
            end;
            return;
         end if;

         Entries (Free) := (others => <>);
         Entries (Free).Status :=
           (if not Desired_Running then Link_Stopped
            elsif Restoring then Link_Restoring
            else Link_Pending);
         Entries (Free).Mode := Mode;
         Entries (Free).Desired_Running := Desired_Running;
         Store (Entries (Free).Name, Entries (Free).Name_Length, Name);
         Store
           (Entries (Free).Source, Entries (Free).Source_Length, Source);
         Store
           (Entries (Free).Target, Entries (Free).Target_Length, Target);
         Store
           (Entries (Free).Target_Version,
            Entries (Free).Target_Version_Length,
            Target_Version);
         Entries (Free).Target_Port := Target_Port;
         declare
            Table_Name : constant String := Managed_Table_Name (Name);
            Effective_Source_Schema : constant String :=
              (if Source_Schema'Length = 0 then "public" else Source_Schema);
            Effective_Source_Table : constant String :=
              (if Source_Table'Length = 0 then Table_Name else Source_Table);
            Effective_Target_Schema : constant String :=
              (if Target_Schema'Length = 0 then "public" else Target_Schema);
            Effective_Target_Table : constant String :=
              (if Target_Table'Length = 0 then Table_Name else Target_Table);
         begin
            for Index in Table_Name'Range loop
               Entries (Free).Table_Name (Index - Table_Name'First + 1) :=
                 Table_Name (Index);
            end loop;
            Entries (Free).Table_Length := Table_Name'Length;
            Store
              (Entries (Free).Source_Schema,
               Entries (Free).Source_Schema_Length,
               Effective_Source_Schema);
            Store
              (Entries (Free).Source_Table,
               Entries (Free).Source_Table_Length,
               Effective_Source_Table);
            Store
              (Entries (Free).Target_Schema,
               Entries (Free).Target_Schema_Length,
               Effective_Target_Schema);
            Store
              (Entries (Free).Target_Table,
               Entries (Free).Target_Table_Length,
               Effective_Target_Table);
            Store
              (Entries (Free).Column_Map,
               Entries (Free).Column_Map_Length,
               Column_Map);
         end;
         Entries (Free).Relay_Port := 58_000 + Free;
         if Desired_Running then
            Enqueue (Create_Link, Name);
         end if;
         Accepted := True;
      end Create;

      procedure Request
        (Name     : String;
         Action   : Link_Command_Kind;
         Accepted : out Boolean) is
      begin
         Accepted := False;
         if Command_Count = Link_Command_Capacity then
            return;
         end if;
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               if Action = Create_Link
                 and then Entries (Index).Status /= Link_Stopped
               then
                  return;
               end if;
               Enqueue (Action, Name);
               if Action = Create_Link then
                  Entries (Index).Status := Link_Restoring;
                  Entries (Index).Desired_Running := True;
               elsif Action = Stop_Link then
                  Entries (Index).Status := Link_Stopping;
                  Entries (Index).Desired_Running := False;
               end if;
               Accepted := True;
               return;
            end if;
         end loop;
      end Request;

      procedure Request_Remove_All (Count : out Natural) is
      begin
         Commands := (others => <>);
         Command_Head := 1;
         Command_Count := 0;
         Count := 0;
         for Item of Entries loop
            if Item.Status /= Link_Empty then
               Item.Status := Link_Stopping;
               Item.Desired_Running := False;
               Enqueue
                 (Remove_Link, Item.Name (1 .. Item.Name_Length));
               Count := Count + 1;
            end if;
         end loop;
      end Request_Remove_All;

      procedure Take_Command
        (Value : out Link_Command; Available : out Boolean) is
      begin
         Available := Command_Count > 0;
         Value := (others => <>);
         if Available then
            Value := Commands (Command_Head);
            Commands (Command_Head) := (others => <>);
            Command_Head :=
              (if Command_Head = Link_Command_Capacity
               then 1 else Command_Head + 1);
            Command_Count := Command_Count - 1;
         end if;
      end Take_Command;

      procedure Set_Status
        (Name : String; Status : Link_Status; Detail : String := "") is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Entries (Index).Status := Status;
               Store
                 (Entries (Index).Detail,
                  Entries (Index).Detail_Length,
                  Detail);
               return;
            end if;
         end loop;
      end Set_Status;

      procedure Forget (Name : String) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Entries (Index) := (others => <>);
               return;
            end if;
         end loop;
      end Forget;

      procedure Record_Change
        (Name : String; LSN : Interfaces.Unsigned_64) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Entries (Index).Change_Count :=
                 Entries (Index).Change_Count + 1;
               Entries (Index).Last_LSN := LSN;
               return;
            end if;
         end loop;
      end Record_Change;

      procedure Record_Start
        (Name : String; LSN : Interfaces.Unsigned_64) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Entries (Index).Start_LSN := LSN;
               if Entries (Index).Last_LSN < LSN then
                  Entries (Index).Last_LSN := LSN;
               end if;
               if Entries (Index).Applied_LSN < LSN then
                  Entries (Index).Applied_LSN := LSN;
               end if;
               return;
            end if;
         end loop;
      end Record_Start;

      procedure Record_Applied
        (Name : String; LSN : Interfaces.Unsigned_64) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               if LSN > Entries (Index).Applied_LSN then
                  Entries (Index).Applied_LSN := LSN;
               end if;
               return;
            end if;
         end loop;
      end Record_Applied;

      procedure Record_Observed
        (Name : String; LSN : Interfaces.Unsigned_64) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               if LSN > Entries (Index).Last_LSN then
                  Entries (Index).Last_LSN := LSN;
               end if;
               return;
            end if;
         end loop;
      end Record_Observed;

      procedure Record_Resolved_Column_Map
        (Name : String; Value : String) is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Store
                 (Entries (Index).Resolved_Column_Map,
                  Entries (Index).Resolved_Column_Map_Length,
                  Value);
               return;
            end if;
         end loop;
      end Record_Resolved_Column_Map;

      procedure Configure_Faults
        (Name : String;
         Paused : Boolean;
         Latency_Milliseconds : Natural;
         Bandwidth_Kib_Per_Second : Natural;
         Accepted : out Boolean) is
      begin
         Accepted := False;
         if Latency_Milliseconds > Max_Fault_Latency_Milliseconds
           or else Bandwidth_Kib_Per_Second > Max_Fault_Bandwidth_Kib
           or else Bandwidth_Kib_Per_Second in
             1 .. Min_Fault_Bandwidth_Kib - 1
         then
            return;
         end if;
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               Entries (Index).Faults.Paused := Paused;
               Entries (Index).Faults.Latency_Milliseconds :=
                 Latency_Milliseconds;
               Entries (Index).Faults.Bandwidth_Kib_Per_Second :=
                 Bandwidth_Kib_Per_Second;
               Accepted := True;
               return;
            end if;
         end loop;
      end Configure_Faults;

      procedure Trigger_Disconnect
        (Name : String; Accepted : out Boolean) is
      begin
         Accepted := False;
         if Command_Count = Link_Command_Capacity then
            return;
         end if;
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name)
              and then Entries (Index).Desired_Running
              and then Entries (Index).Status not in
                Link_Stopped | Link_Stopping
            then
               Entries (Index).Disconnect_Count :=
                 Entries (Index).Disconnect_Count + 1;
               Entries (Index).Status := Link_Stopping;
               Enqueue (Restart_Link, Name);
               Accepted := True;
               return;
            end if;
         end loop;
      end Trigger_Disconnect;

      function Read_Faults (Name : String) return Fault_Profile is
      begin
         for Index in Entries'Range loop
            if Same_Name (Entries (Index), Name) then
               return Entries (Index).Faults;
            end if;
         end loop;
         return (others => <>);
      end Read_Faults;

      function References_Instance (Name : String) return Boolean is
      begin
         for Item of Entries loop
            if Item.Status /= Link_Empty
              and then
                ((Item.Source_Length = Name'Length
                  and then Item.Source (1 .. Item.Source_Length) = Name)
                 or else
                   (Item.Target_Length = Name'Length
                    and then Item.Target (1 .. Item.Target_Length) = Name))
            then
               return True;
            end if;
         end loop;
         return False;
      end References_Instance;

      procedure Snapshot (Value : out Link_Array; Count : out Natural) is
      begin
         Value := (others => <>);
         Count := 0;
         for Item of Entries loop
            if Item.Status /= Link_Empty then
               Count := Count + 1;
               Value (Count) := Item;
            end if;
         end loop;
      end Snapshot;
   end Link_Registry;

end Psqlbench_Context;
