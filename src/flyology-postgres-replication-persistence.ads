with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;
private with Flyology.Bytes;

package Flyology.Postgres.Replication.Persistence is

   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype UInt64 is Interfaces.Unsigned_64;

   Store_Error : exception;

   type Slot_Kind is (Physical_Slot, Logical_Slot);
   type Slot_State is private;
   No_Slot : constant Slot_State;

   function Make_Slot
     (Kind          : Slot_Kind;
      Restart_LSN   : LSN;
      Confirmed_LSN : LSN := 0;
      Plugin        : String := "") return Slot_State;
   function Exists (Item : Slot_State) return Boolean;
   function Kind (Item : Slot_State) return Slot_Kind;
   function Restart_LSN (Item : Slot_State) return LSN;
   function Confirmed_LSN (Item : Slot_State) return LSN;
   function Plugin (Item : Slot_State) return String;
   function Is_Active (Item : Slot_State) return Boolean;
   function Is_Invalidated (Item : Slot_State) return Boolean;
   function Generation (Item : Slot_State) return UInt64;

   type Create_Result is (Created, Already_Exists);
   type Acquire_Result is
     (Acquired, Missing, Kind_Mismatch, Already_Active, Invalidated);

   type Slot_Store is limited interface;

   procedure Create
     (Item   : in out Slot_Store;
      Name   : String;
      State  : Slot_State;
      Result : out Create_Result) is abstract;

   function Load
     (Item : Slot_Store; Name : String) return Slot_State is abstract;

   procedure Drop
     (Item    : in out Slot_Store;
      Name    : String;
      Dropped : out Boolean) is abstract;

   --  Acquire must atomically reject an already-active slot and return a
   --  nonzero lease generation. All later mutations are conditional on that
   --  lease, preventing a stale replication session from advancing state.
   procedure Acquire
     (Item       : in out Slot_Store;
      Name       : String;
      Expected   : Slot_Kind;
      Result     : out Acquire_Result;
      Lease      : out UInt64;
      State      : out Slot_State) is abstract;

   --  Advance must be atomic and monotonic. A successful return means the new
   --  positions satisfy the durability contract of the supplied store.
   procedure Advance
     (Item          : in out Slot_Store;
      Name          : String;
      Lease         : UInt64;
      Restart       : LSN;
      Confirmed     : LSN;
      Advanced      : out Boolean) is abstract;

   procedure Invalidate
     (Item        : in out Slot_Store;
      Name        : String;
      Invalidated : out Boolean) is abstract;

   procedure Release
     (Item     : in out Slot_Store;
      Name     : String;
      Lease    : UInt64;
      Released : out Boolean) is abstract;

   --  Zero means no slot currently retains WAL.
   function Oldest_Restart_LSN (Item : Slot_Store) return LSN is abstract;

   type WAL_Store is limited interface;
   function First_LSN (Item : WAL_Store) return LSN is abstract;
   function Current_LSN (Item : WAL_Store) return LSN is abstract;
   function Read
     (Item    : WAL_Store;
      Start   : LSN;
      Maximum : Positive) return Byte_Array is abstract;
   procedure Append
     (Item  : in out WAL_Store;
      Start : LSN;
      Data  : Byte_Array) is abstract;
   procedure Retain_From
     (Item : in out WAL_Store; Oldest : LSN) is abstract;

   type Timeline_Store is limited interface;
   function Current_Timeline (Item : Timeline_Store) return UInt32 is abstract;
   function History
     (Item : Timeline_Store; Timeline : UInt32) return Byte_Array is abstract;
   --  Promotion must atomically allocate and persist a new timeline whose
   --  history records Parent and Fork_LSN before it becomes current.
   procedure Promote
     (Item         : in out Timeline_Store;
      Parent       : UInt32;
      Fork_LSN     : LSN;
      New_Timeline : out UInt32) is abstract;

   type Prepared_Phase is (Prepared, Target_Applied);
   type Prepared_Transaction is private;
   No_Prepared_Transaction : constant Prepared_Transaction;

   function Make_Prepared
     (XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Byte_Array;
      Phase       : Prepared_Phase := Prepared) return Prepared_Transaction;
   function Exists (Item : Prepared_Transaction) return Boolean;
   function XID (Item : Prepared_Transaction) return Transaction_Id;
   function Prepare_LSN (Item : Prepared_Transaction) return LSN;
   function Payload (Item : Prepared_Transaction) return Byte_Array;
   function Phase (Item : Prepared_Transaction) return Prepared_Phase;

   type Prepared_Store is limited interface;
   procedure Put
     (Item        : in out Prepared_Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Prepared_Transaction) is abstract;
   function Load
     (Item      : Prepared_Store;
      Slot_Name : String;
      GID       : String) return Prepared_Transaction is abstract;
   procedure Mark_Target_Applied
     (Item      : in out Prepared_Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean) is abstract;
   procedure Remove
     (Item      : in out Prepared_Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean) is abstract;

private
   type Slot_State is record
      Present       : Boolean := False;
      Slot_Type     : Slot_Kind := Physical_Slot;
      Restart       : LSN := 0;
      Confirmed     : LSN := 0;
      Plugin_Name   : Ada.Strings.Unbounded.Unbounded_String;
      Active        : Boolean := False;
      Invalid       : Boolean := False;
      Lease         : UInt64 := 0;
   end record;

   No_Slot : constant Slot_State := (others => <>);

   type Prepared_Transaction is record
      Present     : Boolean := False;
      Transaction : Transaction_Id := 0;
      Position    : LSN := 0;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      State       : Prepared_Phase := Prepared;
   end record;

   No_Prepared_Transaction : constant Prepared_Transaction :=
     (others => <>);

end Flyology.Postgres.Replication.Persistence;
