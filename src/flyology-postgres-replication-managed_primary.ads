with Ada.Strings.Unbounded;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Server_Sessions;

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

   procedure Initialize
     (Item      : in out Primary;
      System_Id : UInt64;
      Database  : String := "";
      Timeout   : Duration := 30.0);

   --  Handle one decoded replication command using application-owned state.
   --  START_REPLICATION streams the data currently exposed by the supplied
   --  WAL or logical source and then performs graceful COPY BOTH completion.
   procedure Handle
     (Item    : in out Primary;
      Client  : in out Sessions.Session;
      Command : Replication.Command);

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
