with Flyology.Postgres.Protocol;

package body Flyology.Postgres.Replication.Prepared_Consumer is

   use type Stores.Prepared_Phase;
   use type Transaction_Id;

   procedure Prepare
     (Item        : in out Consumer;
      Slot_Name   : String;
      GID         : String;
      XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Stores.Byte_Array) is
      Proposed : constant Stores.Prepared_Transaction :=
        Stores.Make_Prepared (XID, Prepare_LSN, Payload);
      Existing : constant Stores.Prepared_Transaction :=
        Stores.Load (Item.Store.all, Slot_Name, GID);
   begin
      if Stores.Exists (Existing)
        and then Stores.Phase (Existing) = Stores.Target_Applied
      then
         if Stores.XID (Existing) /= Stores.XID (Proposed) then
            raise Flyology.Postgres.Protocol.Protocol_Error with
              "prepared GID is awaiting acknowledgement";
         end if;
         return;
      end if;
      Stores.Put
        (Item.Store.all,
         Slot_Name,
         GID,
         Proposed);
   end Prepare;

   procedure Commit
     (Item        : in out Consumer;
      Slot_Name   : String;
      GID         : String;
      Applied_Now : out Boolean) is
      Transaction : constant Stores.Prepared_Transaction :=
        Stores.Load (Item.Store.all, Slot_Name, GID);
      Changed : Boolean;
   begin
      if not Stores.Exists (Transaction) then
         raise Flyology.Postgres.Protocol.Protocol_Error with
           "CommitPrepared has no durable prepared transaction";
      end if;
      Applied_Now := Stores.Phase (Transaction) = Stores.Prepared;
      if Applied_Now then
         Apply_Target
           (Item.Target.all,
            Slot_Name,
            GID,
            Stores.XID (Transaction),
            Stores.Payload (Transaction));
         Stores.Mark_Target_Applied
           (Item.Store.all, Slot_Name, GID, Changed);
         if not Changed then
            raise Stores.Store_Error with
              "prepared target marker changed concurrently";
         end if;
      end if;
   end Commit;

   procedure Acknowledge_Commit
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String) is
      Transaction : constant Stores.Prepared_Transaction :=
        Stores.Load (Item.Store.all, Slot_Name, GID);
      Removed : Boolean;
   begin
      if not Stores.Exists (Transaction)
        or else Stores.Phase (Transaction) /= Stores.Target_Applied
      then
         raise Flyology.Postgres.Protocol.Protocol_Error with
           "prepared commit acknowledgement precedes target application";
      end if;
      Stores.Remove (Item.Store.all, Slot_Name, GID, Removed);
      if not Removed then
         raise Stores.Store_Error with
           "prepared transaction disappeared before acknowledgement";
      end if;
   end Acknowledge_Commit;

   procedure Rollback
     (Item      : in out Consumer;
      Slot_Name : String;
      GID       : String) is
      Transaction : constant Stores.Prepared_Transaction :=
        Stores.Load (Item.Store.all, Slot_Name, GID);
      Removed : Boolean;
   begin
      if not Stores.Exists (Transaction) then
         raise Flyology.Postgres.Protocol.Protocol_Error with
           "RollbackPrepared has no durable prepared transaction";
      elsif Stores.Phase (Transaction) = Stores.Target_Applied then
         raise Flyology.Postgres.Protocol.Protocol_Error with
           "cannot roll back an applied prepared transaction";
      end if;
      Stores.Remove (Item.Store.all, Slot_Name, GID, Removed);
      if not Removed then
         raise Stores.Store_Error with
           "prepared transaction disappeared during rollback";
      end if;
   end Rollback;

end Flyology.Postgres.Replication.Prepared_Consumer;
