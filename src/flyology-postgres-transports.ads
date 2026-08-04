with Ada.Streams;
with Flyology.IO.TLS;

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

   type TLS_Upgradable_Transport is limited interface and Transport;

   procedure Upgrade_TLS
     (Item        : in out TLS_Upgradable_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is abstract;

end Flyology.Postgres.Transports;
