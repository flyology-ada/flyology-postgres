with Psqlbench_JSON;

package body Psqlbench_Context is

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
         Accepted : out Boolean;
         Detail   : out String;
         Last     : out Natural)
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
               Message : constant String := "logical link capacity is full";
            begin
               Last := Natural'Min (Message'Length, Detail'Length);
               Detail (Detail'First .. Detail'First + Last - 1) :=
                 Message (Message'First .. Message'First + Last - 1);
            end;
            return;
         end if;

         Entries (Free) := (others => <>);
         Entries (Free).Status := Link_Pending;
         Entries (Free).Mode := Mode;
         Store (Entries (Free).Name, Entries (Free).Name_Length, Name);
         Store
           (Entries (Free).Source, Entries (Free).Source_Length, Source);
         Store
           (Entries (Free).Target, Entries (Free).Target_Length, Target);
         declare
            Table_Name : constant String := "psqlbench_" & Name;
         begin
            for Index in Table_Name'Range loop
               Entries (Free).Table_Name (Index - Table_Name'First + 1) :=
                 (if Table_Name (Index) = '-' then '_' else Table_Name (Index));
            end loop;
            Entries (Free).Table_Length := Table_Name'Length;
         end;
         Entries (Free).Relay_Port := 58_000 + Free;
         Enqueue (Create_Link, Name);
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
               Enqueue (Action, Name);
               if Action = Stop_Link then
                  Entries (Index).Status := Link_Stopping;
               end if;
               Accepted := True;
               return;
            end if;
         end loop;
      end Request;

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
