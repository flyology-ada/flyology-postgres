with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Framing is

   function Read_Initial
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration) return Protocol.Initial_Request;

   function Read_Message
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration) return Protocol.Message;

   procedure Write_Message
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Message;
      Timeout : Duration);

   procedure Write_Packet
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Byte_Array;
      Timeout : Duration);

   procedure Write_Byte
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Byte;
      Timeout : Duration);

end Flyology.Postgres.Framing;
