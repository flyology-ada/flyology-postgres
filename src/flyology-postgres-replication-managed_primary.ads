with Ada.Strings.Unbounded;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Server_Sessions;

--  Replication-command handler composed from application-owned slot, WAL,
--  timeline, and logical-change state. Each START_REPLICATION call streams the
--  currently exposed range, persists acknowledged progress, and closes COPY
--  BOTH in PostgreSQL protocol order.
--
--  Next_Logical is called repeatedly with the last emitted position. It
--  returns Available = False only between transactions. When available,
--  WAL_Start must be at or after After_LSN, WAL_End must be greater than
--  WAL_Start, and Message must continue a valid pgoutput sequence.
--
--  @formal Logical_Context Application state from which logical changes are
--     read.
--  @formal Next_Logical Supplies the next typed logical message and WAL
--     envelope for a named slot.
generic
   type Logical_Context (<>) is limited private;
   with procedure Next_Logical
     (Context    : in out Logical_Context;
      Slot_Name : String;
      After_LSN  : LSN;
      Available  : out Boolean;
      WAL_Start  : out LSN;
      WAL_End    : out LSN;
      Message    : out Logical.Message);
package Flyology.Postgres.Replication.Managed_Primary is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Stores renames Flyology.Postgres.Replication.Persistence;

   type Primary
     (Slots          : not null access Stores.Slot_Store'Class;
      WAL            : not null access Stores.WAL_Store'Class;
      Timelines      : not null access Stores.Timeline_Store'Class;
      Logical_Source : not null access Logical_Context) is limited private;
   --  Managed primary bound to application-owned replication state.
   --  @field Slots Durable physical and logical slot catalog.
   --  @field WAL Contiguous retained WAL source.
   --  @field Timelines Durable current timeline and history source.
   --  @field Logical_Source Application pgoutput change source.

   procedure Initialize
     (Item      : in out Primary;
      System_Id : UInt64;
      Database  : String := "";
      Timeout   : Duration := 30.0);
   --  Configure the identity and operation deadline used by Handle.
   --  @param Item Primary to initialize.
   --  @param System_Id Stable nonzero PostgreSQL system identifier.
   --  @param Database Database reported by IDENTIFY_SYSTEM, or an empty string
   --     for a physical-only connection.
   --  @param Timeout Positive timeout for each protocol operation.
   --  @exception Constraint_Error System_Id is zero or Timeout is not
   --     positive.

   procedure Handle
     (Item    : in out Primary;
      Client  : in out Sessions.Session;
      Command : Replication.Command);
   --  Handle one decoded replication command. START_REPLICATION acquires the
   --  requested slot, streams application data, waits for sufficient standby
   --  feedback, persists progress, releases the lease, applies WAL retention,
   --  and performs graceful COPY BOTH completion.
   --  @param Item Initialized managed primary.
   --  @param Client Authenticated replication-mode server session.
   --  @param Command Decoded IDENTIFY_SYSTEM, SHOW, TIMELINE_HISTORY, or
   --     START_REPLICATION command.
   --  @exception Protocol_Error Configuration, source ordering,
   --     feedback, slot state, or protocol completion is invalid.

private
   type Primary
     (Slots          : not null access Stores.Slot_Store'Class;
      WAL            : not null access Stores.WAL_Store'Class;
      Timelines      : not null access Stores.Timeline_Store'Class;
      Logical_Source : not null access Logical_Context)
   is limited record
      Identifier : UInt64 := 0;
      Database_Name : Ada.Strings.Unbounded.Unbounded_String;
      Operation_Timeout : Duration := 30.0;
      Initialized : Boolean := False;
   end record;

end Flyology.Postgres.Replication.Managed_Primary;
