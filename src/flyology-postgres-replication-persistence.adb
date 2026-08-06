with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Bytes;

package body Flyology.Postgres.Replication.Persistence is

   use type LSN;
   use type Transaction_Id;

   function Make_Slot
     (Kind          : Slot_Kind;
      Restart_LSN   : LSN;
      Confirmed_LSN : LSN := 0;
      Plugin        : String := "") return Slot_State is
   begin
      if Kind = Physical_Slot and then Plugin'Length > 0 then
         raise Constraint_Error with "physical replication slot has plugin";
      elsif Kind = Logical_Slot and then Plugin'Length = 0 then
         raise Constraint_Error with "logical replication slot needs plugin";
      elsif Confirmed_LSN > 0 and then Confirmed_LSN < Restart_LSN then
         raise Constraint_Error with
           "confirmed LSN precedes slot restart LSN";
      end if;
      return
        (Present     => True,
         Slot_Type   => Kind,
         Restart     => Restart_LSN,
         Confirmed   => Confirmed_LSN,
         Plugin_Name => To_Unbounded_String (Plugin),
         Active      => False,
         Invalid     => False,
         Lease       => 0);
   end Make_Slot;

   function Exists (Item : Slot_State) return Boolean is (Item.Present);
   function Kind (Item : Slot_State) return Slot_Kind is (Item.Slot_Type);
   function Restart_LSN (Item : Slot_State) return LSN is (Item.Restart);
   function Confirmed_LSN (Item : Slot_State) return LSN is (Item.Confirmed);
   function Plugin (Item : Slot_State) return String is
     (To_String (Item.Plugin_Name));
   function Is_Active (Item : Slot_State) return Boolean is (Item.Active);
   function Is_Invalidated (Item : Slot_State) return Boolean is
     (Item.Invalid);
   function Generation (Item : Slot_State) return UInt64 is (Item.Lease);

   function Make_Prepared
     (XID         : Transaction_Id;
      Prepare_LSN : LSN;
      Payload     : Byte_Array;
      Phase       : Prepared_Phase := Prepared) return Prepared_Transaction is
   begin
      if XID = 0 or else Prepare_LSN = 0 then
         raise Constraint_Error with
           "prepared transaction needs nonzero XID and LSN";
      end if;
      return
        (Present     => True,
         Transaction => XID,
         Position    => Prepare_LSN,
         Data        => Flyology.Bytes.To_Unbounded_Bytes (Payload),
         State       => Phase);
   end Make_Prepared;

   function Exists (Item : Prepared_Transaction) return Boolean is
     (Item.Present);
   function XID (Item : Prepared_Transaction) return Transaction_Id is
     (Item.Transaction);
   function Prepare_LSN (Item : Prepared_Transaction) return LSN is
     (Item.Position);
   function Payload (Item : Prepared_Transaction) return Byte_Array is
     (Flyology.Bytes.To_Array (Item.Data));
   function Phase (Item : Prepared_Transaction) return Prepared_Phase is
     (Item.State);

end Flyology.Postgres.Replication.Persistence;
