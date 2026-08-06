with Ada.Strings.Unbounded;
with Flyology.Bytes;

generic
   Capacity : Positive := 32;
package Flyology.Postgres.Replication.Persistence.Memory is

   --  Volatile reference implementation. It is intended for deterministic
   --  tests and ephemeral servers; applications requiring crash durability
   --  should implement the same interfaces with a durable backend.
   type Store is limited new Slot_Store and WAL_Store and Timeline_Store
     and Prepared_Store with private;

   overriding procedure Create
     (Item   : in out Store;
      Name   : String;
      State  : Slot_State;
      Result : out Create_Result);
   overriding function Load
     (Item : Store; Name : String) return Slot_State;
   overriding procedure Drop
     (Item    : in out Store;
      Name    : String;
      Dropped : out Boolean);
   overriding procedure Acquire
     (Item       : in out Store;
      Name       : String;
      Expected   : Slot_Kind;
      Result     : out Acquire_Result;
      Lease      : out UInt64;
      State      : out Slot_State);
   overriding procedure Advance
     (Item          : in out Store;
      Name          : String;
      Lease         : UInt64;
      Restart       : LSN;
      Confirmed     : LSN;
      Advanced      : out Boolean);
   overriding procedure Invalidate
     (Item        : in out Store;
      Name        : String;
      Invalidated : out Boolean);
   overriding procedure Release
     (Item     : in out Store;
      Name     : String;
      Lease    : UInt64;
      Released : out Boolean);
   overriding function Oldest_Restart_LSN (Item : Store) return LSN;

   overriding function First_LSN (Item : Store) return LSN;
   overriding function Current_LSN (Item : Store) return LSN;
   overriding function Read
     (Item    : Store;
      Start   : LSN;
      Maximum : Positive) return Byte_Array;
   overriding procedure Append
     (Item  : in out Store;
      Start : LSN;
      Data  : Byte_Array);
   overriding procedure Retain_From
     (Item : in out Store; Oldest : LSN);

   overriding function Current_Timeline (Item : Store) return UInt32;
   overriding function History
     (Item : Store; Timeline : UInt32) return Byte_Array;
   overriding procedure Promote
     (Item         : in out Store;
      Parent       : UInt32;
      Fork_LSN     : LSN;
      New_Timeline : out UInt32);

   overriding procedure Put
     (Item        : in out Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Prepared_Transaction);
   overriding function Load
     (Item      : Store;
      Slot_Name : String;
      GID       : String) return Prepared_Transaction;
   overriding procedure Mark_Target_Applied
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean);
   overriding procedure Remove
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean);

private
   type Slot_Entry is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      State : Slot_State;
   end record;
   type Slot_Array is array (Positive range 1 .. Capacity) of Slot_Entry;

   type Prepared_Entry is record
      Slot        : Ada.Strings.Unbounded.Unbounded_String;
      GID         : Ada.Strings.Unbounded.Unbounded_String;
      Transaction : Prepared_Transaction;
   end record;
   type Prepared_Array is
     array (Positive range 1 .. Capacity) of Prepared_Entry;

   type History_Entry is record
      Timeline : UInt32 := 0;
      Data     : Flyology.Bytes.Unbounded_Bytes;
   end record;
   type History_Array is
     array (Positive range 1 .. Capacity) of History_Entry;

   type Store is limited new Slot_Store and WAL_Store and Timeline_Store
     and Prepared_Store with record
      Slots            : Slot_Array;
      Next_Generation  : UInt64 := 1;
      WAL_Base         : LSN := 0;
      WAL_Data         : Flyology.Bytes.Unbounded_Bytes;
      Timeline         : UInt32 := 1;
      Histories        : History_Array;
      Prepared_Entries : Prepared_Array;
   end record;

end Flyology.Postgres.Replication.Persistence.Memory;
