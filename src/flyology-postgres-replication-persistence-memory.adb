with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;

package body Flyology.Postgres.Replication.Persistence.Memory is

   use type Ada.Streams.Stream_Element_Offset;
   use type UInt32;
   use type UInt64;
   use type LSN;

   function Slot_Index (Item : Store; Name : String) return Natural is
   begin
      for Index in Item.Slots'Range loop
         if Item.Slots (Index).State.Present
           and then To_String (Item.Slots (Index).Name) = Name
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Slot_Index;

   function Free_Slot_Index (Item : Store) return Natural is
   begin
      for Index in Item.Slots'Range loop
         if not Item.Slots (Index).State.Present then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Slot_Index;

   overriding procedure Create
     (Item   : in out Store;
      Name   : String;
      State  : Slot_State;
      Result : out Create_Result) is
      Index : Natural;
   begin
      if Name'Length = 0 or else not State.Present then
         raise Store_Error with "invalid replication slot creation";
      end if;
      if Slot_Index (Item, Name) /= 0 then
         Result := Already_Exists;
         return;
      end if;
      Index := Free_Slot_Index (Item);
      if Index = 0 then
         raise Store_Error with "replication slot capacity exhausted";
      end if;
      Item.Slots (Index) :=
        (Name => To_Unbounded_String (Name), State => State);
      Result := Created;
   end Create;

   overriding function Load
     (Item : Store; Name : String) return Slot_State is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      return (if Index = 0 then No_Slot else Item.Slots (Index).State);
   end Load;

   overriding procedure Drop
     (Item    : in out Store;
      Name    : String;
      Dropped : out Boolean) is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      Dropped := Index /= 0 and then not Item.Slots (Index).State.Active;
      if Dropped then
         Item.Slots (Index) := (others => <>);
      end if;
   end Drop;

   overriding procedure Acquire
     (Item       : in out Store;
      Name       : String;
      Expected   : Slot_Kind;
      Result     : out Acquire_Result;
      Lease      : out UInt64;
      State      : out Slot_State) is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      Lease := 0;
      State := No_Slot;
      if Index = 0 then
         Result := Missing;
      elsif Item.Slots (Index).State.Slot_Type /= Expected then
         Result := Kind_Mismatch;
         State := Item.Slots (Index).State;
      elsif Item.Slots (Index).State.Invalid then
         Result := Invalidated;
         State := Item.Slots (Index).State;
      elsif Item.Slots (Index).State.Active then
         Result := Already_Active;
         State := Item.Slots (Index).State;
      else
         if Item.Next_Generation = 0 then
            Item.Next_Generation := 1;
         end if;
         Item.Slots (Index).State.Active := True;
         Item.Slots (Index).State.Lease := Item.Next_Generation;
         Lease := Item.Next_Generation;
         Item.Next_Generation := Item.Next_Generation + 1;
         State := Item.Slots (Index).State;
         Result := Acquired;
      end if;
   end Acquire;

   overriding procedure Advance
     (Item          : in out Store;
      Name          : String;
      Lease         : UInt64;
      Restart       : LSN;
      Confirmed     : LSN;
      Advanced      : out Boolean) is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      Advanced := Index /= 0
        and then Item.Slots (Index).State.Active
        and then Lease /= 0
        and then Item.Slots (Index).State.Lease = Lease
        and then Restart >= Item.Slots (Index).State.Restart
        and then Confirmed >= Item.Slots (Index).State.Confirmed
        and then (Confirmed = 0 or else Confirmed >= Restart);
      if Advanced then
         Item.Slots (Index).State.Restart := Restart;
         Item.Slots (Index).State.Confirmed := Confirmed;
      end if;
   end Advance;

   overriding procedure Invalidate
     (Item        : in out Store;
      Name        : String;
      Invalidated : out Boolean) is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      Invalidated := Index /= 0;
      if Invalidated then
         Item.Slots (Index).State.Invalid := True;
      end if;
   end Invalidate;

   overriding procedure Release
     (Item     : in out Store;
      Name     : String;
      Lease    : UInt64;
      Released : out Boolean) is
      Index : constant Natural := Slot_Index (Item, Name);
   begin
      Released := Index /= 0
        and then Item.Slots (Index).State.Active
        and then Lease /= 0
        and then Item.Slots (Index).State.Lease = Lease;
      if Released then
         Item.Slots (Index).State.Active := False;
      end if;
   end Release;

   overriding function Oldest_Restart_LSN (Item : Store) return LSN is
      Result : LSN := 0;
   begin
      for Item_Entry of Item.Slots loop
         if Item_Entry.State.Present and then not Item_Entry.State.Invalid
           and then
             (Result = 0 or else Item_Entry.State.Restart < Result)
         then
            Result := Item_Entry.State.Restart;
         end if;
      end loop;
      return Result;
   end Oldest_Restart_LSN;

   overriding function First_LSN (Item : Store) return LSN is
     (Item.WAL_Base);

   overriding function Current_LSN (Item : Store) return LSN is
     (Item.WAL_Base + LSN (Flyology.Bytes.To_Array (Item.WAL_Data)'Length));

   overriding function Read
     (Item    : Store;
      Start   : LSN;
      Maximum : Positive) return Byte_Array is
      Data : constant Byte_Array := Flyology.Bytes.To_Array (Item.WAL_Data);
      Offset : LSN;
      Count  : Natural;
   begin
      if Start < Item.WAL_Base or else Start > Current_LSN (Item) then
         raise Store_Error with "requested WAL is outside retained range";
      end if;
      Offset := Start - Item.WAL_Base;
      Count := Natural'Min
        (Maximum, Data'Length - Natural (Offset));
      if Count = 0 then
         return (1 .. 0 => 0);
      end if;
      return Data
        (Data'First + Ada.Streams.Stream_Element_Offset (Offset) ..
         Data'First + Ada.Streams.Stream_Element_Offset (Offset + LSN (Count))
           - 1);
   end Read;

   overriding procedure Append
     (Item  : in out Store;
      Start : LSN;
      Data  : Byte_Array) is
   begin
      if Flyology.Bytes.To_Array (Item.WAL_Data)'Length = 0 then
         Item.WAL_Base := Start;
      elsif Start /= Current_LSN (Item) then
         raise Store_Error with "WAL append is not contiguous";
      end if;
      Flyology.Postgres.Protocol.Append_Bytes (Item.WAL_Data, Data);
   end Append;

   overriding procedure Retain_From
     (Item : in out Store; Oldest : LSN) is
      Data : constant Byte_Array := Flyology.Bytes.To_Array (Item.WAL_Data);
      Drop_Count : LSN;
   begin
      if Oldest <= Item.WAL_Base then
         return;
      elsif Oldest > Current_LSN (Item) then
         raise Store_Error with "WAL retention floor exceeds current LSN";
      end if;
      Drop_Count := Oldest - Item.WAL_Base;
      if Drop_Count = LSN (Data'Length) then
         Item.WAL_Data := Flyology.Bytes.Empty;
      else
         Item.WAL_Data := Flyology.Bytes.To_Unbounded_Bytes
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Drop_Count) ..
               Data'Last));
      end if;
      Item.WAL_Base := Oldest;
   end Retain_From;

   overriding function Current_Timeline (Item : Store) return UInt32 is
     (Item.Timeline);

   overriding function History
     (Item : Store; Timeline : UInt32) return Byte_Array is
   begin
      for Item_Entry of Item.Histories loop
         if Item_Entry.Timeline = Timeline then
            return Flyology.Bytes.To_Array (Item_Entry.Data);
         end if;
      end loop;
      return (1 .. 0 => 0);
   end History;

   overriding procedure Promote
     (Item         : in out Store;
      Parent       : UInt32;
      Fork_LSN     : LSN;
      New_Timeline : out UInt32) is
      Index : Natural := 0;
      Parent_Image : constant String := Ada.Strings.Fixed.Trim
        (UInt32'Image (Parent), Ada.Strings.Both);
   begin
      if Parent /= Item.Timeline or else Fork_LSN = 0 then
         raise Store_Error with "promotion parent or fork LSN is invalid";
      end if;
      for Candidate in Item.Histories'Range loop
         if Item.Histories (Candidate).Timeline = 0 then
            Index := Candidate;
            exit;
         end if;
      end loop;
      if Index = 0 or else Item.Timeline = UInt32'Last then
         raise Store_Error with "timeline history capacity exhausted";
      end if;
      New_Timeline := Item.Timeline + 1;
      Item.Histories (Index) :=
        (Timeline => New_Timeline,
         Data     => Flyology.Bytes.From_Byte_String
           (Parent_Image & Character'Val (9) & Replication.Image (Fork_LSN)
            & Character'Val (9) & "promotion" & Character'Val (10)));
      Item.Timeline := New_Timeline;
   end Promote;

   function Prepared_Index
     (Item : Store; Slot_Name : String; GID : String) return Natural is
   begin
      for Index in Item.Prepared_Entries'Range loop
         if Item.Prepared_Entries (Index).Transaction.Present
           and then To_String (Item.Prepared_Entries (Index).Slot) = Slot_Name
           and then To_String (Item.Prepared_Entries (Index).GID) = GID
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Prepared_Index;

   overriding procedure Put
     (Item        : in out Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Prepared_Transaction) is
      Index : Natural := Prepared_Index (Item, Slot_Name, GID);
   begin
      if Slot_Name'Length = 0 or else GID'Length = 0
        or else not Transaction.Present
      then
         raise Store_Error with "invalid prepared transaction";
      end if;
      if Index = 0 then
         for Candidate in Item.Prepared_Entries'Range loop
            if not Item.Prepared_Entries (Candidate).Transaction.Present then
               Index := Candidate;
               exit;
            end if;
         end loop;
      end if;
      if Index = 0 then
         raise Store_Error with "prepared transaction capacity exhausted";
      end if;
      Item.Prepared_Entries (Index) :=
        (Slot        => To_Unbounded_String (Slot_Name),
         GID         => To_Unbounded_String (GID),
         Transaction => Transaction);
   end Put;

   overriding function Load
     (Item      : Store;
      Slot_Name : String;
      GID       : String) return Prepared_Transaction is
      Index : constant Natural := Prepared_Index (Item, Slot_Name, GID);
   begin
      return
        (if Index = 0 then No_Prepared_Transaction
         else Item.Prepared_Entries (Index).Transaction);
   end Load;

   overriding procedure Mark_Target_Applied
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean) is
      Index : constant Natural := Prepared_Index (Item, Slot_Name, GID);
   begin
      Changed := Index /= 0
        and then Item.Prepared_Entries (Index).Transaction.State = Prepared;
      if Changed then
         Item.Prepared_Entries (Index).Transaction.State := Target_Applied;
      end if;
   end Mark_Target_Applied;

   overriding procedure Remove
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean) is
      Index : constant Natural := Prepared_Index (Item, Slot_Name, GID);
   begin
      Removed := Index /= 0;
      if Removed then
         Item.Prepared_Entries (Index) := (others => <>);
      end if;
   end Remove;

end Flyology.Postgres.Replication.Persistence.Memory;
