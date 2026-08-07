with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Framing is

   function Read_Initial
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration) return Protocol.Initial_Request;

   function Read_Message
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Protocol.Message;
   --  Read one typed message under a single deadline.
   --  @param Channel Transport to read.
   --  @param Timeout Maximum time allowed for the whole message.
   --  @param On_Wait Observer notified while the message is still arriving,
   --     letting a protocol answer its peer before the message completes.

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
