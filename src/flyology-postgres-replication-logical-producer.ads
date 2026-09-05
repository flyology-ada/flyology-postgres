private with Ada.Containers.Vectors;

package Flyology.Postgres.Replication.Logical.Producer is
   --  Stateful server-side pgoutput encoder. It validates transaction
   --  ordering before delegating wire encoding to Logical.Encode and restores
   --  its prior state if validation or encoding fails.

   type Transaction_State is
     (Idle, Regular_Transaction, Stream_Segment, Stream_Paused,
      Preparing_Transaction);
   --  Current pgoutput transaction context.
   --  @enum Idle No transaction is open.
   --  @enum Regular_Transaction Begin was emitted without streaming.
   --  @enum Stream_Segment A streamed transaction segment is open.
   --  @enum Stream_Paused One or more streamed transactions are between
   --     segments, with no transaction currently emitting.
   --  @enum Preparing_Transaction BeginPrepare was emitted.

   type Encoder is private;
   --  Configured pgoutput producer state for one replication stream.

   procedure Configure
     (Item      : out Encoder;
      Version   : Protocol_Version;
      Streaming : Streaming_Mode := Disabled);
   --  Initialize an idle producer for a negotiated pgoutput configuration.
   --  @param Item Producer to initialize.
   --  @param Version Negotiated pgoutput protocol version.
   --  @param Streaming Negotiated streaming mode.
   --  @exception Protocol_Error Version and Streaming are
   --     incompatible.

   function Emit
     (Item      : in out Encoder;
      Message   : Logical.Message;
      WAL_Start : LSN;
      WAL_End   : LSN) return Byte_Array;
   --  Validate and encode one message without partially advancing Item on
   --  failure. WAL_Start and WAL_End describe its XLogData envelope and may
   --  not move backwards relative to earlier successful calls.
   --  @param Item Configured producer to advance.
   --  @param Message Typed pgoutput message to encode.
   --  @param WAL_Start Envelope start LSN.
   --  @param WAL_End Envelope end LSN and new monotonic producer position.
   --  @return Encoded pgoutput bytes.
   --  @exception Protocol_Error The transaction sequence, envelope,
   --     or negotiated protocol configuration is invalid.

   procedure Reset (Item : in out Encoder);
   --  Forget transaction and WAL progress while retaining configuration.
   --  @param Item Configured producer to return to Idle at LSN zero.
   function State (Item : Encoder) return Transaction_State;
   --  Inspect the current transaction state.
   --  @param Item Producer to inspect.
   --  @return Current transaction state.
   function Transaction (Item : Encoder) return Transaction_Id;
   --  Inspect the active transaction identifier, or the most recently paused
   --  streamed transaction when no transaction is currently emitting.
   --  @param Item Producer to inspect.
   --  @return Current XID, or zero while Idle.
   function Last_WAL_End (Item : Encoder) return LSN;
   --  Inspect the last successfully encoded WAL envelope end.
   --  @param Item Producer to inspect.
   --  @return Monotonic end LSN, or zero after configuration or Reset.

private
   package Transaction_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Transaction_Id);

   type Encoder is record
      Version       : Protocol_Version := 1;
      Mode          : Streaming_Mode := Disabled;
      Current       : Transaction_State := Idle;
      XID           : Transaction_Id := 0;
      Paused_XIDs   : Transaction_Vectors.Vector;
      Last_End      : LSN := 0;
      Is_Configured : Boolean := False;
   end record;

end Flyology.Postgres.Replication.Logical.Producer;
