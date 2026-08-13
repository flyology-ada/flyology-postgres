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

end Psqlbench_Context;
