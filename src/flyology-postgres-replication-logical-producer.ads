package Flyology.Postgres.Replication.Logical.Producer is

   type Transaction_State is
     (Idle, Regular_Transaction, Stream_Segment, Stream_Paused,
      Preparing_Transaction);

   type Encoder is private;

   procedure Configure
     (Item      : out Encoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled);

   --  Validate the server-side transaction sequence and encode one pgoutput
   --  message. WAL_Start and WAL_End describe the XLogData envelope in which
   --  the returned bytes will be sent; positions never move backwards.
   function Emit
     (Item      : in out Encoder;
      Message   : Logical.Message;
      WAL_Start : LSN;
      WAL_End   : LSN) return Byte_Array;

   procedure Reset (Item : in out Encoder);
   function State (Item : Encoder) return Transaction_State;
   function Transaction (Item : Encoder) return Transaction_Id;
   function Last_WAL_End (Item : Encoder) return LSN;

private
   type Encoder is record
      Version      : Protocol_Version := 1;
      Mode         : Streaming_Mode := Disabled;
      Current      : Transaction_State := Idle;
      XID          : Transaction_Id := 0;
      Last_End     : LSN := 0;
      Is_Configured : Boolean := False;
   end record;

end Flyology.Postgres.Replication.Logical.Producer;
