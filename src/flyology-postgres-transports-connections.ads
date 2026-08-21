with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.TLS;
with Flyology.Operations;

package Flyology.Postgres.Transports.Connections is
   --  PostgreSQL transport adapter for a cancellable Flyology connection.

   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection;
      --  Borrowed connection channel.
      Token   : access Flyology.Cancellation.Token)
      --  Optional cooperative cancellation token.
   is limited new TLS_Upgradable_Transport and Operation_Transport
     with private;
   --  Non-owning view of Channel with optional cooperative cancellation.

   overriding procedure Receive_Exactly
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null);
   --  Fill Data from the adapted connection.
   --  @param Item Connection adapter to read.
   --  @param Data Buffer filled with exactly Data'Length bytes.
   --  @param Timeout Maximum time allowed for the complete read.

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);
   --  Write every byte of Data to the adapted connection.
   --  @param Item Connection adapter to write.
   --  @param Data Complete buffer to transmit.
   --  @param Timeout Maximum time allowed for the complete write.

   overriding procedure Upgrade_TLS
     (Item        : in out Connection_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration);
   --  Upgrade Channel to a verified TLS connection in place.
   --  @param Item Connection adapter to upgrade.
   --  @param Backend TLS provider and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param Timeout Maximum time allowed for the handshake.

   overriding procedure Start_Operation
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Result    : out Acquisition_Result;
      Timeout   : Duration);

   overriding procedure Poll_Acquisition
     (Item   : in out Connection_Transport;
      Result : out Acquisition_Result);

   overriding procedure Arm_Acquisition
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class);

   overriding procedure Receive_Step
     (Item   : in out Connection_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   overriding procedure Send_Step
     (Item   : in out Connection_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   overriding procedure Arm_Transport
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result);

   overriding procedure Release_Operation
     (Item : in out Connection_Transport);

   overriding procedure Cancel_Operation
     (Item : in out Connection_Transport);

private
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection;
      Token   : access Flyology.Cancellation.Token)
   is limited new TLS_Upgradable_Transport and Operation_Transport with record
      IO : Flyology.IO.Connections.Drivers.Capability;
   end record;

end Flyology.Postgres.Transports.Connections;
