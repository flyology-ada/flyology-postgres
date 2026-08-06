with Ada.Strings.Unbounded;
with Interfaces.C;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;

generic
   Capacity : Positive := 32;
package Replication_Test_Durable_Store is

   package Persistence renames
     Flyology.Postgres.Replication.Persistence;

   type Store is limited new Persistence.Slot_Store
     and Persistence.WAL_Store
     and Persistence.Timeline_Store
     and Persistence.Prepared_Store with private;

   procedure Open (Item : in out Store; Directory : String);
   --  Acquire the store's exclusive process lock, replay its checksummed
   --  journal, repair an incomplete final record, and fence abandoned slot
   --  leases. Raises Store_Error when another process owns the directory.

   procedure Close (Item : in out Store);
   --  Release the process lock. Slot leases must be released separately.

   procedure Inject_Torn_Tail (Item : in out Store; Contents : String);
   --  Test hook that fsyncs an invalid, unterminated journal tail. Recovery
   --  must discard it without changing the last acknowledged state.

   overriding procedure Create
     (Item   : in out Store;
      Name   : String;
      State  : Persistence.Slot_State;
      Result : out Persistence.Create_Result);
   overriding function Load
     (Item : Store; Name : String) return Persistence.Slot_State;
   overriding procedure Drop
     (Item    : in out Store;
      Name    : String;
      Dropped : out Boolean);
   overriding procedure Acquire
     (Item       : in out Store;
      Name       : String;
      Expected   : Persistence.Slot_Kind;
      Result     : out Persistence.Acquire_Result;
      Lease      : out Persistence.UInt64;
      State      : out Persistence.Slot_State);
   overriding procedure Advance
     (Item      : in out Store;
      Name      : String;
      Lease     : Persistence.UInt64;
      Restart   : Flyology.Postgres.Replication.LSN;
      Confirmed : Flyology.Postgres.Replication.LSN;
      Advanced  : out Boolean);
   overriding procedure Invalidate
     (Item        : in out Store;
      Name        : String;
      Invalidated : out Boolean);
   overriding procedure Release
     (Item     : in out Store;
      Name     : String;
      Lease    : Persistence.UInt64;
      Released : out Boolean);
   overriding function Oldest_Restart_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN;

   overriding function First_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN;
   overriding function Current_LSN
     (Item : Store) return Flyology.Postgres.Replication.LSN;
   overriding function Read
     (Item    : Store;
      Start   : Flyology.Postgres.Replication.LSN;
      Maximum : Positive) return Persistence.Byte_Array;
   overriding procedure Append
     (Item  : in out Store;
      Start : Flyology.Postgres.Replication.LSN;
      Data  : Persistence.Byte_Array);
   overriding procedure Retain_From
     (Item   : in out Store;
      Oldest : Flyology.Postgres.Replication.LSN);

   overriding function Current_Timeline
     (Item : Store) return Flyology.Postgres.Replication.UInt32;
   overriding function History
     (Item     : Store;
      Timeline : Flyology.Postgres.Replication.UInt32)
      return Persistence.Byte_Array;
   overriding procedure Promote
     (Item         : in out Store;
      Parent       : Flyology.Postgres.Replication.UInt32;
      Fork_LSN     : Flyology.Postgres.Replication.LSN;
      New_Timeline : out Flyology.Postgres.Replication.UInt32);

   overriding procedure Put
     (Item        : in out Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Persistence.Prepared_Transaction);
   overriding function Load
     (Item      : Store;
      Slot_Name : String;
      GID       : String) return Persistence.Prepared_Transaction;
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
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity);

   type Name_Array is array (Positive range 1 .. Capacity) of
     Ada.Strings.Unbounded.Unbounded_String;

   type Store is limited new Persistence.Slot_Store
     and Persistence.WAL_Store
     and Persistence.Timeline_Store
     and Persistence.Prepared_Store with record
      Inner       : Memory.Store;
      Root        : Ada.Strings.Unbounded.Unbounded_String;
      Journal     : Ada.Strings.Unbounded.Unbounded_String;
      Lock_Handle : Interfaces.C.int := Interfaces.C.int'First;
      Is_Open     : Boolean := False;
      Replaying   : Boolean := False;
      Names       : Name_Array;
      Name_Count  : Natural := 0;
   end record;

end Replication_Test_Durable_Store;
