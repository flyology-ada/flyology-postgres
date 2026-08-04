with Ada.Streams;

package Flyology.Postgres.Transports is

   type Transport is limited interface;

   procedure Receive_Exactly
     (Item    : in out Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is abstract;

   procedure Send_All
     (Item    : in out Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is abstract;

end Flyology.Postgres.Transports;
