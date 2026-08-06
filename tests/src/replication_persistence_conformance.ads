with Flyology.Postgres.Replication.Persistence;

generic
   with procedure Check (Condition : Boolean; Reason : String);
package Replication_Persistence_Conformance is

   package Persistence renames
     Flyology.Postgres.Replication.Persistence;

   procedure Run
     (Slots    : in out Persistence.Slot_Store'Class;
      WAL      : in out Persistence.WAL_Store'Class;
      Timelines : in out Persistence.Timeline_Store'Class;
      Prepared : in out Persistence.Prepared_Store'Class);
   --  Exercise the complete persistence-interface contract against a fresh
   --  backend. The same object may implement and be passed for all interfaces.

end Replication_Persistence_Conformance;
