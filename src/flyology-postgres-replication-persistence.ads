with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;
private with Flyology.Bytes;

package Flyology.Postgres.Replication.Persistence is
   --  Application-owned state contracts for replication slots, retained WAL,
   --  timeline history, and prepared logical transactions. Implementations
   --  choose their durability technology while preserving the atomicity and
   --  monotonicity requirements declared by each operation.

   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   --  Contiguous protocol or WAL bytes exchanged with a persistence backend.
   subtype UInt64 is Interfaces.Unsigned_64;
   --  Unsigned generation counter used to fence stale slot owners.

   Store_Error : exception;
   --  Raised when a store cannot satisfy its persistence contract.

   type Slot_Kind is (Physical_Slot, Logical_Slot);
   --  Replication slot category.
   --  @enum Physical_Slot Retains WAL for a physical standby.
   --  @enum Logical_Slot Retains WAL and confirmed output for a plugin.
   type Slot_State is private;
   --  Immutable snapshot of one stored replication slot.
   No_Slot : constant Slot_State;
   --  Sentinel returned by Load when the named slot does not exist.

   function Make_Slot
     (Kind          : Slot_Kind;
      Restart_LSN   : LSN;
      Confirmed_LSN : LSN := 0;
      Plugin        : String := "") return Slot_State;
   --  Construct an inactive, valid slot snapshot.
   --  @param Kind Physical or logical slot category.
   --  @param Restart_LSN Oldest WAL position retained for the slot.
   --  @param Confirmed_LSN Logical position durably acknowledged by a
   --     consumer; use zero when confirmation is not applicable.
   --  @param Plugin Logical output plugin name; required for logical slots and
   --     forbidden for physical slots.
   --  @return The initialized slot snapshot.
   --  @exception Constraint_Error The kind, plugin, or LSN combination is
   --     inconsistent.
   function Exists (Item : Slot_State) return Boolean;
   --  Test whether a slot snapshot represents a stored slot.
   --  @param Item Slot snapshot to inspect.
   --  @return True when Item is not No_Slot.
   function Kind (Item : Slot_State) return Slot_Kind;
   --  Read the category of a slot snapshot.
   --  @param Item Existing slot snapshot.
   --  @return Physical_Slot or Logical_Slot.
   function Restart_LSN (Item : Slot_State) return LSN;
   --  Read the oldest WAL position retained by a slot.
   --  @param Item Existing slot snapshot.
   --  @return Stored restart LSN.
   function Confirmed_LSN (Item : Slot_State) return LSN;
   --  Read a slot's durable logical acknowledgement.
   --  @param Item Existing slot snapshot.
   --  @return Confirmed LSN, or zero when not applicable.
   function Plugin (Item : Slot_State) return String;
   --  Read a slot's logical output plugin.
   --  @param Item Existing slot snapshot.
   --  @return Plugin name, or an empty string for a physical slot.
   function Is_Active (Item : Slot_State) return Boolean;
   --  Test whether the snapshot was acquired by a replication session.
   --  @param Item Slot snapshot to inspect.
   --  @return True when the slot has an active lease.
   function Is_Invalidated (Item : Slot_State) return Boolean;
   --  Test whether a slot can no longer be acquired.
   --  @param Item Slot snapshot to inspect.
   --  @return True when the slot has been invalidated.
   function Generation (Item : Slot_State) return UInt64;
   --  Read the lease generation captured by a slot snapshot.
   --  @param Item Slot snapshot to inspect.
   --  @return Nonzero generation for an acquired slot, otherwise zero.

   type Create_Result is (Created, Already_Exists);
   --  Outcome of idempotent slot creation.
   --  @enum Created A new slot was stored.
   --  @enum Already_Exists The name was already present and was not changed.
   type Acquire_Result is
     (Acquired, Missing, Kind_Mismatch, Already_Active, Invalidated);
   --  Outcome of atomic slot acquisition.
   --  @enum Acquired A new exclusive lease was issued.
   --  @enum Missing No slot has the requested name.
   --  @enum Kind_Mismatch The stored slot has a different category.
   --  @enum Already_Active Another owner holds the slot lease.
   --  @enum Invalidated The slot is no longer usable.

   type Slot_Store is limited interface;
   --  Atomic persistence interface for physical and logical slot state.

   procedure Create
     (Item   : in out Slot_Store;
      Name   : String;
      State  : Slot_State;
      Result : out Create_Result) is abstract;
   --  Create a named slot without replacing an existing slot.
   --  @param Item Store to mutate.
   --  @param Name Nonempty stable slot name.
   --  @param State Initial state created by Make_Slot.
   --  @param Result Whether the slot was created or already existed.

   function Load
     (Item : Slot_Store; Name : String) return Slot_State is abstract;
   --  Load a consistent snapshot of a named slot.
   --  @param Item Store to query.
   --  @param Name Slot name.
   --  @return Stored state, or No_Slot when absent.

   procedure Drop
     (Item    : in out Slot_Store;
      Name    : String;
      Dropped : out Boolean) is abstract;
   --  Drop an inactive slot without affecting an active owner.
   --  @param Item Store to mutate.
   --  @param Name Slot name.
   --  @param Dropped True only when an inactive stored slot was removed.

   procedure Acquire
     (Item       : in out Slot_Store;
      Name       : String;
      Expected   : Slot_Kind;
      Result     : out Acquire_Result;
      Lease      : out UInt64;
      State      : out Slot_State) is abstract;
   --  Atomically reject an already-active slot or issue a nonzero generation
   --  lease. Later mutations are conditional on the lease, preventing a stale
   --  replication session from advancing state.
   --  @param Item Store to mutate.
   --  @param Name Slot name.
   --  @param Expected Required physical or logical category.
   --  @param Result Acquisition outcome.
   --  @param Lease New nonzero generation on success, otherwise zero.
   --  @param State Consistent slot snapshot associated with the outcome.

   procedure Advance
     (Item          : in out Slot_Store;
      Name          : String;
      Lease         : UInt64;
      Restart       : LSN;
      Confirmed     : LSN;
      Advanced      : out Boolean) is abstract;
   --  Atomically and durably advance a slot without moving either LSN
   --  backwards. A stale or inactive lease must be rejected without mutation.
   --  @param Item Store to mutate.
   --  @param Name Slot name.
   --  @param Lease Generation returned by Acquire.
   --  @param Restart New WAL retention position.
   --  @param Confirmed New logical acknowledgement; use zero when not
   --     applicable.
   --  @param Advanced True only after the new state satisfies the backend's
   --     durability contract.

   procedure Invalidate
     (Item        : in out Slot_Store;
      Name        : String;
      Invalidated : out Boolean) is abstract;
   --  Mark a stored slot unusable for future acquisitions.
   --  @param Item Store to mutate.
   --  @param Name Slot name.
   --  @param Invalidated True when the named slot exists and is invalidated.

   procedure Release
     (Item     : in out Slot_Store;
      Name     : String;
      Lease    : UInt64;
      Released : out Boolean) is abstract;
   --  Release an active slot only when the generation still matches.
   --  @param Item Store to mutate.
   --  @param Name Slot name.
   --  @param Lease Generation returned by Acquire.
   --  @param Released True only when this owner released the active lease.

   function Oldest_Restart_LSN (Item : Slot_Store) return LSN is abstract;
   --  Compute the retention floor across all non-invalidated slots.
   --  @param Item Store to query.
   --  @return Oldest restart LSN, or zero when no slot retains WAL.

   type WAL_Store is limited interface;
   --  Contiguous retained-WAL persistence interface.
   function First_LSN (Item : WAL_Store) return LSN is abstract;
   --  Read the first retained WAL position.
   --  @param Item Store to query.
   --  @return Inclusive first retained LSN.
   function Current_LSN (Item : WAL_Store) return LSN is abstract;
   --  Read the position immediately after available WAL.
   --  @param Item Store to query.
   --  @return Exclusive end LSN.
   function Read
     (Item    : WAL_Store;
      Start   : LSN;
      Maximum : Positive) return Byte_Array is abstract;
   --  Read a bounded contiguous WAL range beginning at Start.
   --  @param Item Store to query.
   --  @param Start Inclusive retained LSN.
   --  @param Maximum Maximum number of bytes to return.
   --  @return Up to Maximum bytes, empty only when Start equals Current_LSN.
   procedure Append
     (Item  : in out WAL_Store;
      Start : LSN;
      Data  : Byte_Array) is abstract;
   --  Durably append a contiguous WAL range.
   --  @param Item Store to mutate.
   --  @param Start Current_LSN, or the base position of an empty store.
   --  @param Data Bytes to append in WAL order.
   procedure Retain_From
     (Item : in out WAL_Store; Oldest : LSN) is abstract;
   --  Discard bytes before Oldest while preserving the retained suffix.
   --  @param Item Store to mutate.
   --  @param Oldest New inclusive first retained LSN.

   type Timeline_Store is limited interface;
   --  Persistence interface for current timeline and history files.
   function Current_Timeline (Item : Timeline_Store) return UInt32 is abstract;
   --  Read the current PostgreSQL timeline identifier.
   --  @param Item Store to query.
   --  @return Nonzero current timeline.
   function History
     (Item : Timeline_Store; Timeline : UInt32) return Byte_Array is abstract;
   --  Read a timeline history file exactly as sent to a standby.
   --  @param Item Store to query.
   --  @param Timeline Timeline whose history is requested.
   --  @return History contents, or an empty array when unavailable.
   procedure Promote
     (Item         : in out Timeline_Store;
      Parent       : UInt32;
      Fork_LSN     : LSN;
      New_Timeline : out UInt32) is abstract;
   --  Atomically allocate and persist a timeline whose history records Parent
   --  and Fork_LSN before it becomes current.
   --  @param Item Store to mutate.
   --  @param Parent Timeline being promoted from; it must still be current.
   --  @param Fork_LSN Nonzero WAL fork position.
   --  @param New_Timeline Newly persisted current timeline.

   type Prepared_Phase is (Prepared, Target_Applied);
   --  Durable consumer phase for a two-phase logical transaction.
   --  @enum Prepared Payload is durable but not marked applied at the target.
   --  @enum Target_Applied Target application is durably recorded.
   type Prepared_Transaction is private;
   --  Durable prepared-transaction snapshot and replay payload.
   No_Prepared_Transaction : constant Prepared_Transaction;
   --  Sentinel returned by Load when no prepared transaction exists.

   function Make_Prepared
     (XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Byte_Array;
      Phase       : Prepared_Phase := Prepared) return Prepared_Transaction;
   --  Construct durable consumer state for a prepared transaction.
   --  @param XID Nonzero source transaction identifier.
   --  @param Prepare_LSN Nonzero source prepare position.
   --  @param Payload Deterministic data needed to apply the transaction.
   --  @param Phase Initial recovery phase.
   --  @return Initialized prepared-transaction snapshot.
   --  @exception Constraint_Error XID or Prepare_LSN is zero.
   function Exists (Item : Prepared_Transaction) return Boolean;
   --  Test whether a snapshot represents stored prepared state.
   --  @param Item Snapshot to inspect.
   --  @return True when Item is not No_Prepared_Transaction.
   function XID (Item : Prepared_Transaction) return Transaction_Id;
   --  Read the source transaction identifier.
   --  @param Item Existing prepared snapshot.
   --  @return Stored XID.
   function Prepare_LSN (Item : Prepared_Transaction) return LSN;
   --  Read the source prepare position.
   --  @param Item Existing prepared snapshot.
   --  @return Stored prepare LSN.
   function Payload (Item : Prepared_Transaction) return Byte_Array;
   --  Copy the deterministic target-application payload.
   --  @param Item Existing prepared snapshot.
   --  @return Stored payload bytes.
   function Phase (Item : Prepared_Transaction) return Prepared_Phase;
   --  Read the durable recovery phase.
   --  @param Item Existing prepared snapshot.
   --  @return Prepared or Target_Applied.

   type Prepared_Store is limited interface;
   --  Durable state interface for prepared logical-consumer recovery.
   procedure Put
     (Item        : in out Prepared_Store;
      Slot_Name   : String;
      GID         : String;
      Transaction : Prepared_Transaction) is abstract;
   --  Durably insert or replace prepared state identified by slot and GID.
   --  @param Item Store to mutate.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @param Transaction Complete state to persist before source
   --     acknowledgement.
   function Load
     (Item      : Prepared_Store;
      Slot_Name : String;
      GID       : String) return Prepared_Transaction is abstract;
   --  Load a consistent prepared-transaction snapshot.
   --  @param Item Store to query.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @return Stored state, or No_Prepared_Transaction when absent.
   procedure Mark_Target_Applied
     (Item      : in out Prepared_Store;
      Slot_Name : String;
      GID       : String;
      Changed   : out Boolean) is abstract;
   --  Atomically and durably move existing state from Prepared to
   --  Target_Applied without regressing an already-applied marker.
   --  @param Item Store to mutate.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @param Changed True only when this call performed the transition.
   procedure Remove
     (Item      : in out Prepared_Store;
      Slot_Name : String;
      GID       : String;
      Removed   : out Boolean) is abstract;
   --  Remove prepared state after the source commit is durably acknowledged.
   --  @param Item Store to mutate.
   --  @param Slot_Name Logical slot name.
   --  @param GID PostgreSQL prepared-transaction identifier.
   --  @param Removed True only when stored state was removed.

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
