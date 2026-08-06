with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with Interfaces.C.Strings;

package body Replication_Test_Durable_Store is

   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;
   use type Persistence.Prepared_Phase;
   use type Persistence.Slot_Kind;

   Lock_Exclusive_Nonblocking : constant Interfaces.C.int := 6;
   Lock_Unlock                : constant Interfaces.C.int := 8;
   Open_Read_Only             : constant Interfaces.C.int := 0;
   Open_Read_Write            : constant Interfaces.C.int := 2;

   function C_Open
     (Path  : Interfaces.C.Strings.chars_ptr;
      Flags : Interfaces.C.int) return Interfaces.C.int
      with Import, Convention => C, External_Name => "open";
   function C_Close (File : Interfaces.C.int) return Interfaces.C.int
      with Import, Convention => C, External_Name => "close";
   function C_Fsync (File : Interfaces.C.int) return Interfaces.C.int
      with Import, Convention => C, External_Name => "fsync";
   function C_Flock
     (File      : Interfaces.C.int;
      Operation : Interfaces.C.int) return Interfaces.C.int
      with Import, Convention => C, External_Name => "flock";
   function C_Rename
     (Old_Path : Interfaces.C.Strings.chars_ptr;
      New_Path : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int
      with Import, Convention => C, External_Name => "rename";

   function Trimmed (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Image_U64 (Value : Persistence.UInt64) return String is
     (Trimmed (Persistence.UInt64'Image (Value)));

   function Image_U32
     (Value : Flyology.Postgres.Replication.UInt32) return String is
     (Trimmed (Flyology.Postgres.Replication.UInt32'Image (Value)));

   function Image_LSN
     (Value : Flyology.Postgres.Replication.LSN) return String is
     (Trimmed (Flyology.Postgres.Replication.LSN'Image (Value)));

   function Image_XID
     (Value : Flyology.Postgres.Replication.Transaction_Id) return String is
     (Trimmed
        (Flyology.Postgres.Replication.Transaction_Id'Image (Value)));

   function Hex_Digit (Value : Natural) return Character is
      Hex_Characters : constant String := "0123456789ABCDEF";
   begin
      return Hex_Characters (Value + 1);
   end Hex_Digit;

   function Hex_Value (Value : Character) return Natural is
      Upper : constant Character := Ada.Characters.Handling.To_Upper (Value);
   begin
      if Upper in '0' .. '9' then
         return Character'Pos (Upper) - Character'Pos ('0');
      elsif Upper in 'A' .. 'F' then
         return Character'Pos (Upper) - Character'Pos ('A') + 10;
      else
         raise Persistence.Store_Error with "invalid durable-store hex data";
      end if;
   end Hex_Value;

   function Encode (Value : String) return String is
      Result : String (1 .. Value'Length * 2);
      Cursor : Positive := Result'First;
   begin
      if Value'Length = 0 then
         return "-";
      end if;
      for Item of Value loop
         Result (Cursor) := Hex_Digit (Character'Pos (Item) / 16);
         Result (Cursor + 1) := Hex_Digit (Character'Pos (Item) mod 16);
         Cursor := Cursor + 2;
      end loop;
      return Result;
   end Encode;

   function Decode (Value : String) return String is
   begin
      if Value = "-" then
         return "";
      elsif Value'Length mod 2 /= 0 then
         raise Persistence.Store_Error with "odd durable-store hex data";
      end if;
      declare
         Result : String (1 .. Value'Length / 2);
         Cursor : Positive := Value'First;
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val
              (Hex_Value (Value (Cursor)) * 16
               + Hex_Value (Value (Cursor + 1)));
            Cursor := Cursor + 2;
         end loop;
         return Result;
      end;
   end Decode;

   function Encode (Value : Persistence.Byte_Array) return String is
      Result : String (1 .. Value'Length * 2);
      Cursor : Positive := Result'First;
   begin
      if Value'Length = 0 then
         return "-";
      end if;
      for Item of Value loop
         Result (Cursor) := Hex_Digit (Natural (Item) / 16);
         Result (Cursor + 1) := Hex_Digit (Natural (Item) mod 16);
         Cursor := Cursor + 2;
      end loop;
      return Result;
   end Encode;

   function Decode_Bytes (Value : String) return Persistence.Byte_Array is
   begin
      if Value = "-" then
         return (1 .. 0 => 0);
      elsif Value'Length mod 2 /= 0 then
         raise Persistence.Store_Error with "odd durable-store byte data";
      end if;
      declare
         Result : Persistence.Byte_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
         Cursor : Positive := Value'First;
      begin
         for Index in Result'Range loop
            Result (Index) := Ada.Streams.Stream_Element
              (Hex_Value (Value (Cursor)) * 16
               + Hex_Value (Value (Cursor + 1)));
            Cursor := Cursor + 2;
         end loop;
         return Result;
      end;
   end Decode_Bytes;

   function Checksum (Value : String) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Item of Value loop
         Result := Result xor Interfaces.Unsigned_64 (Character'Pos (Item));
         Result := Result * 16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Checksum;

   function Hex_16 (Value : Interfaces.Unsigned_64) return String is
      Result : String (1 .. 16);
      Work   : Interfaces.Unsigned_64 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Hex_Digit (Natural (Work mod 16));
         Work := Work / 16;
      end loop;
      return Result;
   end Hex_16;

   function Valid_Record (Line : String; Payload : out Unbounded_String)
      return Boolean is
      Expected : Interfaces.Unsigned_64 := 0;
   begin
      Payload := Null_Unbounded_String;
      if Line'Length < 18 or else Line (Line'First + 16) /= ' ' then
         return False;
      end if;
      for Index in Line'First .. Line'First + 15 loop
         Expected := Expected * 16
           + Interfaces.Unsigned_64 (Hex_Value (Line (Index)));
      end loop;
      Payload := To_Unbounded_String
        (Line (Line'First + 17 .. Line'Last));
      return Expected = Checksum (To_String (Payload));
   exception
      when Persistence.Store_Error =>
         return False;
   end Valid_Record;

   function Field (Value : String; Number : Positive) return String is
      First   : Positive := Value'First;
      Current : Positive := 1;
   begin
      for Index in Value'Range loop
         if Value (Index) = ' ' then
            if Current = Number then
               return Value (First .. Index - 1);
            end if;
            Current := Current + 1;
            First := Index + 1;
         end if;
      end loop;
      if Current = Number then
         return Value (First .. Value'Last);
      end if;
      raise Persistence.Store_Error with "missing durable-store record field";
   end Field;

   procedure Sync_Path (Path : String) is
      C_Path : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Path);
      Handle : Interfaces.C.int;
      Result : Interfaces.C.int;
   begin
      Handle := C_Open (C_Path, Open_Read_Only);
      Interfaces.C.Strings.Free (C_Path);
      if Handle < 0 then
         raise Persistence.Store_Error with "cannot open durable-store file";
      end if;
      Result := C_Fsync (Handle);
      if C_Close (Handle) /= 0 then
         null;
      end if;
      if Result /= 0 then
         raise Persistence.Store_Error with "cannot fsync durable-store file";
      end if;
   end Sync_Path;

   procedure Replace_File (Source : String; Target : String) is
      C_Source : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Source);
      C_Target : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Target);
      Result : Interfaces.C.int;
   begin
      Result := C_Rename (C_Source, C_Target);
      Interfaces.C.Strings.Free (C_Source);
      Interfaces.C.Strings.Free (C_Target);
      if Result /= 0 then
         raise Persistence.Store_Error with
           "cannot atomically repair durable-store journal";
      end if;
   end Replace_File;

   procedure Write_Exact_File (Path : String; Contents : String) is
      package Stream_IO renames Ada.Streams.Stream_IO;
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Create (File, Stream_IO.Out_File, Path);
      if Contents'Length > 0 then
         declare
            Data : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Contents'Length));
            Cursor : Ada.Streams.Stream_Element_Offset := Data'First;
         begin
            for Value of Contents loop
               Data (Cursor) := Ada.Streams.Stream_Element
                 (Character'Pos (Value));
               Cursor := Cursor + 1;
            end loop;
            Stream_IO.Write (File, Data);
         end;
      end if;
      Stream_IO.Close (File);
      Sync_Path (Path);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         raise;
   end Write_Exact_File;

   procedure Require_Open (Item : Store) is
   begin
      if not Item.Is_Open then
         raise Persistence.Store_Error with "durable store is not open";
      end if;
   end Require_Open;

   procedure Remember (Item : in out Store; Name : String) is
   begin
      for Index in 1 .. Item.Name_Count loop
         if To_String (Item.Names (Index)) = Name then
            return;
         end if;
      end loop;
      if Item.Name_Count = Capacity then
         raise Persistence.Store_Error with "durable slot index is full";
      end if;
      Item.Name_Count := Item.Name_Count + 1;
      Item.Names (Item.Name_Count) := To_Unbounded_String (Name);
   end Remember;

   procedure Persist (Item : in out Store; Payload : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Require_Open (Item);
      if Item.Replaying then
         return;
      end if;
      Ada.Text_IO.Open
        (File, Ada.Text_IO.Append_File, To_String (Item.Journal));
      Ada.Text_IO.Put_Line (File, Hex_16 (Checksum (Payload)) & " " & Payload);
      Ada.Text_IO.Flush (File);
      Sync_Path (To_String (Item.Journal));
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Persist;

   procedure Apply_Record (Item : in out Store; Payload : String) is
      Created      : Persistence.Create_Result;
      Acquired     : Persistence.Acquire_Result;
      State        : Persistence.Slot_State;
      Lease        : Persistence.UInt64;
      Changed      : Boolean;
      New_Timeline : Flyology.Postgres.Replication.UInt32;
      Code         : constant Character := Field (Payload, 1) (1);
   begin
      case Code is
         when 'C' =>
            declare
               Name : constant String := Decode (Field (Payload, 2));
               Kind : constant Persistence.Slot_Kind :=
                 (if Field (Payload, 3) = "P"
                  then Persistence.Physical_Slot
                  else Persistence.Logical_Slot);
            begin
               Remember (Item, Name);
               Memory.Create
                 (Item.Inner,
                  Name,
                  Persistence.Make_Slot
                    (Kind,
                     Flyology.Postgres.Replication.LSN'Value
                       (Field (Payload, 4)),
                     Flyology.Postgres.Replication.LSN'Value
                       (Field (Payload, 5)),
                     Decode (Field (Payload, 6))),
                  Created);
            end;
         when 'D' =>
            Memory.Drop
              (Item.Inner, Decode (Field (Payload, 2)), Changed);
         when 'A' =>
            Memory.Acquire
              (Item.Inner,
               Decode (Field (Payload, 2)),
               (if Field (Payload, 3) = "P"
                then Persistence.Physical_Slot
                else Persistence.Logical_Slot),
               Acquired, Lease, State);
         when 'V' =>
            Memory.Advance
              (Item.Inner,
               Decode (Field (Payload, 2)),
               Persistence.UInt64'Value (Field (Payload, 3)),
               Flyology.Postgres.Replication.LSN'Value (Field (Payload, 4)),
               Flyology.Postgres.Replication.LSN'Value (Field (Payload, 5)),
               Changed);
         when 'I' =>
            Memory.Invalidate
              (Item.Inner, Decode (Field (Payload, 2)), Changed);
         when 'R' =>
            Memory.Release
              (Item.Inner,
               Decode (Field (Payload, 2)),
               Persistence.UInt64'Value (Field (Payload, 3)),
               Changed);
         when 'W' =>
            Memory.Append
              (Item.Inner,
               Flyology.Postgres.Replication.LSN'Value (Field (Payload, 2)),
               Decode_Bytes (Field (Payload, 3)));
         when 'T' =>
            Memory.Retain_From
              (Item.Inner,
               Flyology.Postgres.Replication.LSN'Value (Field (Payload, 2)));
         when 'N' =>
            Memory.Promote
              (Item.Inner,
               Flyology.Postgres.Replication.UInt32'Value
                 (Field (Payload, 2)),
               Flyology.Postgres.Replication.LSN'Value (Field (Payload, 3)),
               New_Timeline);
         when 'Q' =>
            Memory.Put
              (Item.Inner,
               Decode (Field (Payload, 2)),
               Decode (Field (Payload, 3)),
               Persistence.Make_Prepared
                 (Flyology.Postgres.Replication.Transaction_Id'Value
                    (Field (Payload, 4)),
                  Flyology.Postgres.Replication.LSN'Value
                    (Field (Payload, 5)),
                  Decode_Bytes (Field (Payload, 7)),
                  (if Field (Payload, 6) = "P"
                   then Persistence.Prepared
                   else Persistence.Target_Applied)));
         when 'M' =>
            Memory.Mark_Target_Applied
              (Item.Inner,
               Decode (Field (Payload, 2)),
               Decode (Field (Payload, 3)),
               Changed);
         when 'O' =>
            Memory.Remove
              (Item.Inner,
               Decode (Field (Payload, 2)),
               Decode (Field (Payload, 3)),
               Changed);
         when others =>
            raise Persistence.Store_Error with
              "unknown durable-store journal operation";
      end case;
   exception
      when Constraint_Error | Persistence.Store_Error =>
         if Item.Replaying then
            null;
         else
            raise;
         end if;
   end Apply_Record;

   procedure Repair_Journal (Item : Store; Contents : String) is
      Temporary : constant String := To_String (Item.Journal) & ".repair";
   begin
      Write_Exact_File (Temporary, Contents);
      Replace_File (Temporary, To_String (Item.Journal));
      Sync_Path (To_String (Item.Journal));
   end Repair_Journal;

   procedure Replay (Item : in out Store) is
      File       : Ada.Text_IO.File_Type;
      Valid_Data : Unbounded_String;
      Repair     : Boolean := False;
   begin
      Item.Replaying := True;
      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, To_String (Item.Journal));
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line    : constant String := Ada.Text_IO.Get_Line (File);
            Payload : Unbounded_String;
         begin
            if Line'Length = 0 and then Length (Valid_Data) = 0 then
               --  Some Text_IO runtimes materialize an initial line marker
               --  when an empty text file is created. Normalize it away.
               Repair := True;
            elsif Valid_Record (Line, Payload) then
               Apply_Record (Item, To_String (Payload));
               Append (Valid_Data, Line);
               Append (Valid_Data, Character'Val (10));
            elsif Ada.Text_IO.End_Of_File (File) then
               Repair := True;
            else
               raise Persistence.Store_Error with
                 "durable-store corruption precedes the journal tail";
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      Item.Replaying := False;
      if Repair then
         Repair_Journal (Item, To_String (Valid_Data));
      end if;
   exception
      when others =>
         Item.Replaying := False;
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Replay;

   procedure Open (Item : in out Store; Directory : String) is
      Lock_Path : constant String := Directory & "/lock";
      Journal_Path : constant String := Directory & "/journal";
      File : Ada.Text_IO.File_Type;
      C_Path : Interfaces.C.Strings.chars_ptr;
      Ignored : Interfaces.C.int;
      Released : Boolean;
   begin
      if Item.Is_Open then
         raise Persistence.Store_Error with "durable store is already open";
      end if;
      if not Ada.Directories.Exists (Directory) then
         Ada.Directories.Create_Path (Directory);
      end if;
      if not Ada.Directories.Exists (Lock_Path) then
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Lock_Path);
         Ada.Text_IO.Close (File);
      end if;
      if not Ada.Directories.Exists (Journal_Path) then
         Write_Exact_File (Journal_Path, "");
      end if;

      C_Path := Interfaces.C.Strings.New_String (Lock_Path);
      Item.Lock_Handle := C_Open (C_Path, Open_Read_Write);
      Interfaces.C.Strings.Free (C_Path);
      if Item.Lock_Handle < 0
        or else C_Flock
          (Item.Lock_Handle, Lock_Exclusive_Nonblocking) /= 0
      then
         if Item.Lock_Handle >= 0 then
            Ignored := C_Close (Item.Lock_Handle);
         end if;
         Item.Lock_Handle := -1;
         raise Persistence.Store_Error with
           "durable store is locked by another process";
      end if;

      Item.Root := To_Unbounded_String (Directory);
      Item.Journal := To_Unbounded_String (Journal_Path);
      Item.Is_Open := True;
      Replay (Item);

      for Index in 1 .. Item.Name_Count loop
         declare
            Name  : constant String := To_String (Item.Names (Index));
            State : constant Persistence.Slot_State :=
              Memory.Load (Item.Inner, Name);
         begin
            if Persistence.Exists (State)
              and then Persistence.Is_Active (State)
            then
               Release
                 (Item, Name, Persistence.Generation (State), Released);
               if not Released then
                  raise Persistence.Store_Error with
                    "abandoned slot lease could not be fenced";
               end if;
            end if;
         end;
      end loop;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         if Item.Lock_Handle >= 0 then
            Ignored := C_Flock (Item.Lock_Handle, Lock_Unlock);
            Ignored := C_Close (Item.Lock_Handle);
         end if;
         Item.Lock_Handle := -1;
         Item.Is_Open := False;
         raise;
   end Open;

   procedure Close (Item : in out Store) is
      Ignored : Interfaces.C.int;
   begin
      if Item.Lock_Handle >= 0 then
         Ignored := C_Flock (Item.Lock_Handle, Lock_Unlock);
         Ignored := C_Close (Item.Lock_Handle);
      end if;
      Item.Lock_Handle := -1;
      Item.Is_Open := False;
   end Close;

   procedure Inject_Torn_Tail (Item : in out Store; Contents : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Require_Open (Item);
      Ada.Text_IO.Open
        (File, Ada.Text_IO.Append_File, To_String (Item.Journal));
      Ada.Text_IO.Put (File, Contents);
      Ada.Text_IO.Flush (File);
      Sync_Path (To_String (Item.Journal));
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Inject_Torn_Tail;

   overriding procedure Create
     (Item   : in out Store;
      Name   : String;
      State  : Persistence.Slot_State;
      Result : out Persistence.Create_Result) is
      Kind : constant String :=
        (if Persistence.Kind (State) = Persistence.Physical_Slot
         then "P" else "L");
   begin
      Persist
        (Item,
         "C " & Encode (Name) & " " & Kind & " "
         & Image_LSN (Persistence.Restart_LSN (State)) & " "
         & Image_LSN (Persistence.Confirmed_LSN (State)) & " "
         & Encode (Persistence.Plugin (State)));
      Remember (Item, Name);
      Memory.Create (Item.Inner, Name, State, Result);
   end Create;

   overriding function Load
     (Item : Store; Name : String) return Persistence.Slot_State is
   begin
      Require_Open (Item);
      return Memory.Load (Item.Inner, Name);
   end Load;

   overriding procedure Drop
     (Item    : in out Store;
      Name    : String;
      Dropped : out Boolean) is
   begin
      Persist (Item, "D " & Encode (Name));
      Memory.Drop (Item.Inner, Name, Dropped);
   end Drop;

   overriding procedure Acquire
     (Item       : in out Store;
      Name       : String;
      Expected   : Persistence.Slot_Kind;
      Result     : out Persistence.Acquire_Result;
      Lease      : out Persistence.UInt64;
      State      : out Persistence.Slot_State) is
   begin
      Persist
        (Item,
         "A " & Encode (Name) & " "
         & (if Expected = Persistence.Physical_Slot then "P" else "L"));
      Memory.Acquire
        (Item.Inner, Name, Expected, Result, Lease, State);
   end Acquire;

   overriding procedure Advance
     (Item      : in out Store;
      Name      : String;
      Lease     : Persistence.UInt64;
      Restart   : Flyology.Postgres.Replication.LSN;
      Confirmed : Flyology.Postgres.Replication.LSN;
      Advanced  : out Boolean) is
   begin
      Persist
        (Item,
         "V " & Encode (Name) & " " & Image_U64 (Lease) & " "
         & Image_LSN (Restart) & " " & Image_LSN (Confirmed));
      Memory.Advance
        (Item.Inner, Name, Lease, Restart, Confirmed, Advanced);
   end Advance;

   overriding procedure Invalidate
     (Item        : in out Store;
      Name        : String;
      Invalidated : out Boolean) is
   begin
      Persist (Item, "I " & Encode (Name));
      Memory.Invalidate (Item.Inner, Name, Invalidated);
   end Invalidate;

   overriding procedure Release
     (Item     : in out Store;
      Name     : String;
      Lease    : Persistence.UInt64;
      Released : out Boolean) is
   begin
      Persist (Item, "R " & Encode (Name) & " " & Image_U64 (Lease));
      Memory.Release (Item.Inner, Name, Lease, Released);
   end Release;

   overriding function Oldest_Restart_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN is
   begin
      Require_Open (Item);
      return Memory.Oldest_Restart_LSN (Item.Inner);
   end Oldest_Restart_LSN;

   overriding function First_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN is
   begin
      Require_Open (Item);
      return Memory.First_LSN (Item.Inner);
   end First_LSN;

   overriding function Current_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN is
   begin
      Require_Open (Item);
      return Memory.Current_LSN (Item.Inner);
   end Current_LSN;

   overriding function Read
     (Item    : Store;
      Start   : Flyology.Postgres.Replication.LSN;
      Maximum : Positive) return Persistence.Byte_Array is
   begin
      Require_Open (Item);
      return Memory.Read (Item.Inner, Start, Maximum);
   end Read;

   overriding procedure Append
     (Item  : in out Store;
      Start : Flyology.Postgres.Replication.LSN;
      Data  : Persistence.Byte_Array) is
   begin
      Persist (Item, "W " & Image_LSN (Start) & " " & Encode (Data));
      Memory.Append (Item.Inner, Start, Data);
   end Append;

   overriding procedure Retain_From
     (Item   : in out Store;
      Oldest : Flyology.Postgres.Replication.LSN) is
   begin
      Persist (Item, "T " & Image_LSN (Oldest));
      Memory.Retain_From (Item.Inner, Oldest);
   end Retain_From;

   overriding function Current_Timeline
     (Item : Store) return Flyology.Postgres.Replication.UInt32 is
   begin
      Require_Open (Item);
      return Memory.Current_Timeline (Item.Inner);
   end Current_Timeline;

   overriding function History
     (Item     : Store;
      Timeline : Flyology.Postgres.Replication.UInt32)
      return Persistence.Byte_Array is
   begin
      Require_Open (Item);
      return Memory.History (Item.Inner, Timeline);
   end History;

   overriding procedure Promote
     (Item         : in out Store;
      Parent       : Flyology.Postgres.Replication.UInt32;
      Fork_LSN     : Flyology.Postgres.Replication.LSN;
      New_Timeline : out Flyology.Postgres.Replication.UInt32) is
   begin
      Persist
        (Item,
         "N " & Image_U32 (Parent) & " " & Image_LSN (Fork_LSN));
      Memory.Promote (Item.Inner, Parent, Fork_LSN, New_Timeline);
   end Promote;

   overriding procedure Put
     (Item        : in out Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Persistence.Prepared_Transaction) is
      Phase : constant String :=
        (if Persistence.Phase (Transaction) = Persistence.Prepared
         then "P" else "A");
   begin
      Persist
        (Item,
         "Q " & Encode (Slot_Name) & " " & Encode (GID) & " "
         & Image_XID (Persistence.XID (Transaction)) & " "
         & Image_LSN (Persistence.Prepare_LSN (Transaction)) & " "
         & Phase & " " & Encode (Persistence.Payload (Transaction)));
      Memory.Put (Item.Inner, Slot_Name, GID, Transaction);
   end Put;

   overriding function Load
     (Item      : Store;
      Slot_Name : String;
      GID       : String) return Persistence.Prepared_Transaction is
   begin
      Require_Open (Item);
      return Memory.Load (Item.Inner, Slot_Name, GID);
   end Load;

   overriding procedure Mark_Target_Applied
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean) is
   begin
      Persist (Item, "M " & Encode (Slot_Name) & " " & Encode (GID));
      Memory.Mark_Target_Applied (Item.Inner, Slot_Name, GID, Changed);
   end Mark_Target_Applied;

   overriding procedure Remove
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean) is
   begin
      Persist (Item, "O " & Encode (Slot_Name) & " " & Encode (GID));
      Memory.Remove (Item.Inner, Slot_Name, GID, Removed);
   end Remove;

end Replication_Test_Durable_Store;
