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
         Last_End      => 0,
         Is_Configured => True);
   end Configure;

   function Emit
     (Item      : in out Encoder;
      Message   : Logical.Message;
      WAL_Start : LSN;
      WAL_End   : LSN) return Byte_Array is
      Kind : constant Message_Kind := Logical.Kind (Message);
      Previous_State : constant Transaction_State := Item.Current;
      Previous_XID   : constant Transaction_Id := Item.XID;
      Previous_End   : constant LSN := Item.Last_End;
   begin
      Require (Item.Is_Configured, "pgoutput producer is not configured");
      Require
        (WAL_Start <= WAL_End and then WAL_Start >= Item.Last_End,
         "pgoutput WAL envelope moved backwards");

      case Kind is
         when Begin_Message =>
            Require
              (Item.Current = Idle and then Logical.Transaction (Message) > 0,
               "Begin requires an idle pgoutput producer");
            Item.Current := Regular_Transaction;
            Item.XID := Logical.Transaction (Message);

         when Commit_Message =>
            Require
              (Item.Current = Regular_Transaction,
               "Commit requires a regular transaction");
            Item.Current := Idle;
            Item.XID := 0;

         when Stream_Start_Message =>
            Require
              (Item.Mode /= Disabled
               and then Logical.Transaction (Message) > 0,
               "StreamStart requires streaming configuration and an XID");
            if Logical.Is_First_Stream_Segment (Message) then
               Require
                 (Item.Current = Idle,
                  "first StreamStart requires an idle producer");
               Item.XID := Logical.Transaction (Message);
            else
               Require
                 (Item.Current = Stream_Paused
                  and then Item.XID = Logical.Transaction (Message),
                  "continued StreamStart changed transaction identity");
            end if;
            Item.Current := Stream_Segment;

         when Stream_Stop_Message =>
            Require
              (Item.Current = Stream_Segment,
               "StreamStop requires an open stream segment");
            Item.Current := Stream_Paused;

         when Stream_Commit_Message | Stream_Abort_Message =>
            Require
              (Item.Current = Stream_Paused
               and then Item.XID = Logical.Transaction (Message),
               "stream completion requires the paused transaction");
            Item.Current := Idle;
            Item.XID := 0;

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
               and then Item.XID = Logical.Transaction (Message),
               "StreamPrepare requires the paused transaction");
            Item.Current := Idle;
            Item.XID := 0;

         when Commit_Prepared_Message | Rollback_Prepared_Message =>
            Require
              (Item.Current = Idle,
               "prepared completion requires an idle producer");

         when Origin_Message | Logical_Decoding_Message |
              Relation_Message | Type_Message | Insert_Message |
              Update_Message | Delete_Message | Truncate_Message =>
            Require
              (Item.Current in Regular_Transaction | Stream_Segment |
                 Preparing_Transaction,
               "pgoutput data message is outside a transaction");
            if Logical.Is_Streamed (Message) then
               Require
                 (Item.Current = Stream_Segment
                  and then Logical.Transaction (Message) = Item.XID,
                  "streamed pgoutput message changed transaction identity");
            end if;
      end case;

      Item.Last_End := WAL_End;
      return Logical.Encode (Message, Item.Version, Item.Mode);
   exception
      when others =>
         Item.Current := Previous_State;
         Item.XID := Previous_XID;
         Item.Last_End := Previous_End;
         raise;
   end Emit;

   procedure Reset (Item : in out Encoder) is
   begin
      Item.Current := Idle;
      Item.XID := 0;
      Item.Last_End := 0;
   end Reset;

   function State (Item : Encoder) return Transaction_State is
     (Item.Current);

   function Transaction (Item : Encoder) return Transaction_Id is
     (Item.XID);

   function Last_WAL_End (Item : Encoder) return LSN is
     (Item.Last_End);

end Flyology.Postgres.Replication.Logical.Producer;
