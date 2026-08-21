with Ada.Streams;
with Flyology.IO.TLS;
with Flyology.Operations;

package Flyology.Postgres.Transports is
   --  Abstract byte transports used by the PostgreSQL client and server.
   --  Implementations must transfer the complete requested buffer or raise an
   --  exception; partial transfers are not exposed to protocol code.

   type Transport is limited interface;
   --  Bidirectional, blocking byte channel for PostgreSQL wire messages.

   type Wait_Observer is limited interface;
   --  Notified while a transfer waits for its peer.  A protocol that owes the
   --  peer periodic traffic -- replication feedback, most of all -- would
   --  otherwise stay silent for as long as one message takes to arrive, and a
   --  message can be large: a primary packs pending WAL into a single
   --  XLogData of up to 128 kB.  Observing the wait keeps that obligation
   --  answerable without letting a partial buffer escape.

   procedure On_Wait (Item : in out Wait_Observer) is abstract;
   --  Report that the transfer is waiting for more bytes.  Called on the
   --  receiving task between transport reads, never concurrently with one, so
   --  an implementation may send on the same channel.  It must return
   --  promptly; time spent here counts against the transfer's deadline.
   --  @param Item Observer deciding whether it owes the peer anything.

   procedure Receive_Exactly
     (Item    : in out Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null) is abstract;
   --  Fill Data with exactly Data'Length bytes received from Item.
   --  @param Item Channel from which bytes are read.
   --  @param Data Buffer filled before the operation returns.
   --  @param Timeout Maximum time allowed for the complete transfer.
   --  @param On_Wait Observer notified while the transfer waits.  Best
   --     effort: a transport that cannot read incrementally, or that never
   --     waits, may never call it.
   --  @exception Flyology.IO.Timeout_Error The deadline expires first.

   procedure Send_All
     (Item    : in out Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is abstract;
   --  Send every byte of Data in array order.
   --  @param Item Channel to which bytes are written.
   --  @param Data Complete buffer to transmit.
   --  @param Timeout Maximum time allowed for the complete transfer.
   --  @exception Flyology.IO.Timeout_Error The deadline expires first.

   type Operation_Transport is limited interface;
   --  Set-independent immediate-step capability used by one outer PostgreSQL
   --  operation.  Implementations retain their private connection or TLS
   --  capability in the concrete transport object; the PostgreSQL operation
   --  owns the only Flyology completion-set slot.

   type Acquisition_Result is (Acquired, Need_Acquire_Readiness);
   --  Result of one immediate attempt to acquire the transport capability.

   type Step_Result is
     (Made_Progress, Need_Read, Need_Write, Peer_Closed);
   --  Result of one bounded receive or send step.

   procedure Start_Operation
     (Item      : in out Operation_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Result    : out Acquisition_Result;
      Timeout   : Duration) is abstract;
   --  Begin one transport operation, attempt acquisition once, and arm its
   --  shared deadline on Operation.

   procedure Poll_Acquisition
     (Item   : in out Operation_Transport;
      Result : out Acquisition_Result) is abstract;
   --  Retry acquisition after the previously armed source becomes ready.

   procedure Arm_Acquisition
     (Item      : in out Operation_Transport;
      Operation : in out Flyology.Operations.Operation'Class) is abstract;
   --  Arm lease and lifecycle readiness on Operation.

   procedure Receive_Step
     (Item   : in out Operation_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result) is abstract;
   --  Attempt at most one immediate receive step.

   procedure Send_Step
     (Item   : in out Operation_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result) is abstract;
   --  Attempt at most one immediate send step.

   procedure Arm_Transport
     (Item      : in out Operation_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result) is abstract;
   --  Arm the read or write readiness requested by the last step, plus the
   --  shared deadline and lifecycle sources.

   procedure Release_Operation
     (Item : in out Operation_Transport) is abstract;
   --  Release every transport borrow before the outer operation terminalizes.

   procedure Cancel_Operation
     (Item : in out Operation_Transport) is abstract;
   --  Cancel and release every transport borrow before outer cancellation.

   type TLS_Upgradable_Transport is limited interface and Transport;
   --  Plain transport that can transfer its underlying channel into TLS.

   procedure Upgrade_TLS
     (Item        : in out TLS_Upgradable_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is abstract;
   --  Replace Item's plaintext channel with an authenticated TLS connection.
   --  @param Item Transport to upgrade in place.
   --  @param Backend TLS implementation and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param Timeout Maximum time allowed for the TLS handshake.
   --  @exception Flyology.IO.TLS.TLS_Error The handshake or verification
   --     fails.

end Flyology.Postgres.Transports;
