with Ada.Strings.Unbounded;
with Flyology.Bytes;

--  Bounded volatile reference implementation of every persistence interface.
--  It is deterministic and intended for tests or ephemeral single-owner
--  servers; it is neither concurrent nor crash durable.
--
--  @formal Capacity Maximum number of slots, timeline-history entries, and
--     prepared transactions retained by one Store.
generic
   Capacity : Positive := 32;
package Flyology.Postgres.Replication.Persistence.Memory is

   type Store is limited new Slot_Store and WAL_Store and Timeline_Store
     and Prepared_Store with private;
   --  In-memory implementation sharing one bounded state allocation across
   --  slot, WAL, timeline, and prepared-transaction operations.

   overriding procedure Create
     (Item   : in out Store;
      Name   : String;
      State  : Slot_State;
      Result : out Create_Result);
   --  Create a slot according to Slot_Store.Create.
   --  @param Item Memory store to mutate.
   --  @param Name Nonempty slot name.
   --  @param State Initial state created by Make_Slot.
   --  @param Result Creation outcome.
   --  @exception Store_Error State is invalid or capacity is exhausted.
   overriding function Load
     (Item : Store; Name : String) return Slot_State;
   --  Load a slot snapshot according to Slot_Store.Load.
   --  @param Item Memory store to query.
   --  @param Name Slot name.
   --  @return Stored state, or No_Slot.
   overriding procedure Drop
     (Item    : in out Store;
      Name    : String;
      Dropped : out Boolean);
   --  Drop an inactive slot according to Slot_Store.Drop.
   --  @param Item Memory store to mutate.
   --  @param Name Slot name.
   --  @param Dropped Whether a stored inactive slot was removed.
   overriding procedure Acquire
     (Item       : in out Store;
      Name       : String;
      Expected   : Slot_Kind;
      Result     : out Acquire_Result;
      Lease      : out UInt64;
      State      : out Slot_State);
   --  Acquire an exclusive generation lease according to Slot_Store.Acquire.
   --  @param Item Memory store to mutate.
   --  @param Name Slot name.
   --  @param Expected Required slot category.
   --  @param Result Acquisition outcome.
   --  @param Lease New nonzero generation on success, otherwise zero.
   --  @param State Snapshot associated with Result.
   overriding procedure Advance
     (Item          : in out Store;
      Name          : String;
      Lease         : UInt64;
      Restart       : LSN;
      Confirmed     : LSN;
      Advanced      : out Boolean);
   --  Conditionally advance monotonic slot positions in memory.
   --  @param Item Memory store to mutate.
   --  @param Name Slot name.
   --  @param Lease Active generation.
   --  @param Restart New restart position.
   --  @param Confirmed New confirmed position; use zero when not applicable.
   --  @param Advanced Whether the active lease and monotonicity checks passed.
   overriding procedure Invalidate
     (Item        : in out Store;
      Name        : String;
      Invalidated : out Boolean);
   --  Invalidate a stored slot.
   --  @param Item Memory store to mutate.
   --  @param Name Slot name.
   --  @param Invalidated Whether the named slot existed.
   overriding procedure Release
     (Item     : in out Store;
      Name     : String;
      Lease    : UInt64;
      Released : out Boolean);
   --  Release a matching active generation lease.
   --  @param Item Memory store to mutate.
   --  @param Name Slot name.
   --  @param Lease Active generation.
   --  @param Released Whether the matching lease was released.
   overriding function Oldest_Restart_LSN (Item : Store) return LSN;
   --  Compute the non-invalidated slot retention floor.
   --  @param Item Memory store to query.
   --  @return Oldest restart LSN, or zero when no slot retains WAL.

   overriding function First_LSN (Item : Store) return LSN;
   --  Read the in-memory WAL base.
   --  @param Item Memory store to query.
   --  @return Inclusive first retained LSN.
   overriding function Current_LSN (Item : Store) return LSN;
   --  Read the in-memory WAL end.
   --  @param Item Memory store to query.
   --  @return Exclusive end LSN.
   overriding function Read
     (Item    : Store;
      Start   : LSN;
      Maximum : Positive) return Byte_Array;
   --  Copy a bounded retained WAL range.
   --  @param Item Memory store to query.
   --  @param Start Inclusive retained LSN.
   --  @param Maximum Maximum bytes to return.
   --  @return Contiguous WAL bytes, possibly empty at Current_LSN.
   --  @exception Store_Error Start is outside the retained range.
   overriding procedure Append
     (Item  : in out Store;
      Start : LSN;
      Data  : Byte_Array);
   --  Append bytes at the exact current end position.
   --  @param Item Memory store to mutate.
   --  @param Start Current_LSN, or a new base for an empty store.
   --  @param Data WAL bytes to append.
   --  @exception Store_Error A nonempty append is not contiguous.
   overriding procedure Retain_From
     (Item : in out Store; Oldest : LSN);
   --  Discard the WAL prefix before Oldest.
   --  @param Item Memory store to mutate.
   --  @param Oldest New inclusive first retained LSN.
   --  @exception Store_Error Oldest exceeds Current_LSN.

   overriding function Current_Timeline (Item : Store) return UInt32;
   --  Read the current in-memory timeline.
   --  @param Item Memory store to query.
   --  @return Current timeline, initially one.
   overriding function History
     (Item : Store; Timeline : UInt32) return Byte_Array;
   --  Copy a stored timeline history file.
   --  @param Item Memory store to query.
   --  @param Timeline Timeline identifier.
   --  @return Exact history bytes, or an empty array when absent.
   overriding procedure Promote
     (Item         : in out Store;
      Parent       : UInt32;
      Fork_LSN     : LSN;
      New_Timeline : out UInt32);
   --  Persist a PostgreSQL-format history line and advance the timeline.
   --  @param Item Memory store to mutate.
   --  @param Parent Timeline that must still be current.
   --  @param Fork_LSN Nonzero fork position.
   --  @param New_Timeline Newly current timeline.
   --  @exception Store_Error Parent, fork, or capacity is invalid.

   overriding procedure Put
     (Item        : in out Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Prepared_Transaction);
   --  Insert or replace prepared state by slot and GID.
   --  @param Item Memory store to mutate.
   --  @param Slot_Name Nonempty logical slot name.
   --  @param GID Nonempty prepared-transaction identifier.
   --  @param Transaction Complete prepared state.
   --  @exception Store_Error Input is invalid or capacity is exhausted.
   overriding function Load
     (Item      : Store;
      Slot_Name : String;
      GID       : String) return Prepared_Transaction;
   --  Load prepared state by slot and GID.
   --  @param Item Memory store to query.
   --  @param Slot_Name Logical slot name.
   --  @param GID Prepared-transaction identifier.
   --  @return Stored state, or No_Prepared_Transaction.
   overriding procedure Mark_Target_Applied
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean);
   --  Atomically change Prepared state to Target_Applied.
   --  @param Item Memory store to mutate.
   --  @param Slot_Name Logical slot name.
   --  @param GID Prepared-transaction identifier.
   --  @param Changed Whether this call performed the transition.
   overriding procedure Remove
     (Item      : in out Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean);
   --  Remove prepared state by slot and GID.
   --  @param Item Memory store to mutate.
   --  @param Slot_Name Logical slot name.
   --  @param GID Prepared-transaction identifier.
   --  @param Removed Whether stored state was removed.

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
