with Flyology.Postgres.Protocol;

package body Flyology.Postgres.Replication.Logical.Producer is

   use type Message_Kind;
   use type Transaction_Id;
   use type LSN;

   procedure Fail (Reason : String) is
   begin
      raise Flyology.Postgres.Protocol.Protocol_Error with Reason;
   end Fail;

   procedure Require (Condition : Boolean; Reason : String) is
   begin
      if not Condition then
         Fail (Reason);
      end if;
   end Require;

   function Is_Paused
     (Item : Encoder; XID : Transaction_Id) return Boolean is
   begin
      for Paused_XID of Item.Paused_XIDs loop
         if Paused_XID = XID then
            return True;
         end if;
      end loop;
      return False;
   end Is_Paused;

   procedure Remove_Paused
     (Item : in out Encoder; XID : Transaction_Id) is
      Position : Transaction_Vectors.Cursor := Item.Paused_XIDs.First;
   begin
      while Transaction_Vectors.Has_Element (Position) loop
         if Transaction_Vectors.Element (Position) = XID then
            Item.Paused_XIDs.Delete (Position);
            return;
         end if;
         Position := Transaction_Vectors.Next (Position);
      end loop;
   end Remove_Paused;

   procedure Touch_Paused
     (Item : in out Encoder; XID : Transaction_Id) is
   begin
      Remove_Paused (Item, XID);
      Item.Paused_XIDs.Append (XID);
   end Touch_Paused;

   procedure Restore_Paused_Context (Item : in out Encoder) is
   begin
      if Item.Paused_XIDs.Is_Empty then
         Item.Current := Idle;
         Item.XID := 0;
      else
         Item.Current := Stream_Paused;
         Item.XID := Item.Paused_XIDs.Last_Element;
      end if;
   end Restore_Paused_Context;

   procedure Configure
     (Item      : out Encoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled) is
   begin
      Require
        (Configuration_Is_Valid (Version, Streaming),
         "invalid pgoutput producer configuration");
      Item :=
        (Version       => Version,
         Mode          => Streaming,
         Current       => Idle,
         XID           => 0,
         Paused_XIDs   => Transaction_Vectors.Empty_Vector,
         Last_End      => 0,
         Is_Configured => True);
   end Configure;

   function Emit
     (Item      : in out Encoder;
      Message   : Logical.Message;
      WAL_Start : LSN;
      WAL_End   : LSN) return Byte_Array is
      Kind : constant Message_Kind := Logical.Kind (Message);
      Previous : constant Encoder := Item;
   begin
      Require (Item.Is_Configured, "pgoutput producer is not configured");
      Require
        (WAL_Start <= WAL_End and then WAL_Start >= Item.Last_End,
         "pgoutput WAL envelope moved backwards");

      case Kind is
         when Begin_Message =>
            Require
              (Item.Current in Idle | Stream_Paused
               and then Logical.Transaction (Message) > 0
               and then not Is_Paused
                 (Item, Logical.Transaction (Message)),
               "Begin requires an inactive pgoutput producer and a new XID");
            Item.Current := Regular_Transaction;
            Item.XID := Logical.Transaction (Message);

         when Commit_Message =>
            Require
              (Item.Current = Regular_Transaction,
               "Commit requires a regular transaction");
            Restore_Paused_Context (Item);

         when Stream_Start_Message =>
            Require
              (Item.Mode /= Disabled
               and then Logical.Transaction (Message) > 0,
               "StreamStart requires streaming configuration and an XID");
            if Logical.Is_First_Stream_Segment (Message) then
               Require
                 (Item.Current in Idle | Stream_Paused
                  and then not Is_Paused
                    (Item, Logical.Transaction (Message)),
                  "first StreamStart requires an inactive producer and a new XID");
            else
               Require
                 (Item.Current = Stream_Paused
                  and then Is_Paused
                    (Item, Logical.Transaction (Message)),
                  "continued StreamStart requires a paused transaction");
               Remove_Paused (Item, Logical.Transaction (Message));
            end if;
            Item.Current := Stream_Segment;
            Item.XID := Logical.Transaction (Message);

         when Stream_Stop_Message =>
            Require
              (Item.Current = Stream_Segment,
               "StreamStop requires an open stream segment");
            Touch_Paused (Item, Item.XID);
            Restore_Paused_Context (Item);

         when Stream_Commit_Message =>
            Require
              (Item.Current = Stream_Paused
               and then Is_Paused
                 (Item, Logical.Transaction (Message)),
               "stream commit requires a paused transaction");
            Remove_Paused (Item, Logical.Transaction (Message));
            Restore_Paused_Context (Item);

         when Stream_Abort_Message =>
            Require
              (Item.Current = Stream_Paused
               and then Is_Paused
                 (Item, Logical.Transaction (Message))
               and then Logical.Subtransaction (Message) > 0,
               "stream abort requires a paused transaction and subtransaction");
            if Logical.Transaction (Message) =
              Logical.Subtransaction (Message)
            then
               Remove_Paused (Item, Logical.Transaction (Message));
               Restore_Paused_Context (Item);
            else
               Touch_Paused (Item, Logical.Transaction (Message));
               Restore_Paused_Context (Item);
            end if;

         when Begin_Prepare_Message =>
            Require
              (Item.Current = Idle and then Logical.Transaction (Message) > 0,
               "BeginPrepare requires an idle producer");
            Item.Current := Preparing_Transaction;
            Item.XID := Logical.Transaction (Message);

         when Prepare_Message =>
            Require
              (Item.Current = Preparing_Transaction
               and then Item.XID = Logical.Transaction (Message),
               "Prepare changed transaction identity");
            Item.Current := Idle;
            Item.XID := 0;

         when Stream_Prepare_Message =>
            Require
              (Item.Current = Stream_Paused
               and then Is_Paused
                 (Item, Logical.Transaction (Message)),
               "StreamPrepare requires the paused transaction");
            Remove_Paused (Item, Logical.Transaction (Message));
            Restore_Paused_Context (Item);

         when Commit_Prepared_Message | Rollback_Prepared_Message =>
            Require
              (Item.Current = Idle,
               "prepared completion requires an idle producer");

         when Logical_Decoding_Message =>
            if Logical.Is_Transactional (Message) then
               Require
                 (Item.Current in Regular_Transaction | Stream_Segment |
                    Preparing_Transaction,
                  "transactional logical message is outside a transaction");
               if Item.Current = Stream_Segment then
                  Require
                    (Logical.Is_Streamed (Message)
                     and then Logical.Transaction (Message) = Item.XID,
                     "streamed logical message changed transaction identity");
               else
                  Require
                    (not Logical.Is_Streamed (Message),
                     "streamed logical message is outside a stream segment");
               end if;
            else
               Require
                 (Item.Current in Idle | Stream_Paused
                  and then not Logical.Is_Streamed (Message),
                  "nontransactional logical message requires an inactive producer");
            end if;

         when Origin_Message =>
            Require
              (Item.Current in Regular_Transaction | Stream_Segment |
                 Preparing_Transaction,
               "pgoutput origin message is outside a transaction");

         when Relation_Message | Type_Message | Insert_Message |
              Update_Message | Delete_Message | Truncate_Message =>
            Require
              (Item.Current in Regular_Transaction | Stream_Segment |
                 Preparing_Transaction,
               "pgoutput data message is outside a transaction");
            if Item.Current = Stream_Segment then
               Require
                 (Logical.Is_Streamed (Message)
                  and then Logical.Transaction (Message) = Item.XID,
                  "streamed pgoutput message changed transaction identity");
            else
               Require
                 (not Logical.Is_Streamed (Message),
                  "streamed pgoutput message is outside a stream segment");
            end if;
      end case;

      Item.Last_End := WAL_End;
      return Logical.Encode (Message, Item.Version, Item.Mode);
   exception
      when others =>
         Item := Previous;
         raise;
   end Emit;

   procedure Reset (Item : in out Encoder) is
   begin
      Item.Current := Idle;
      Item.XID := 0;
      Item.Paused_XIDs.Clear;
      Item.Last_End := 0;
   end Reset;

   function State (Item : Encoder) return Transaction_State is
     (Item.Current);

   function Transaction (Item : Encoder) return Transaction_Id is
     (Item.XID);

   function Last_WAL_End (Item : Encoder) return LSN is
     (Item.Last_End);

end Flyology.Postgres.Replication.Logical.Producer;
