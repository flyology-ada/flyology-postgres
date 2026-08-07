with Ada.Unchecked_Deallocation;
with Flyology.Postgres.Wire;

package body Flyology.Postgres.Framing is

   type Byte_Array_Access is access Protocol.Byte_Array;

   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Protocol.Byte_Array,
      Name   => Byte_Array_Access);

   function Read_Length
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Protocol.UInt32 is
      Header : Protocol.Byte_Array (1 .. 4);
      Cursor : Protocol.Byte_Offset := Header'First;
   begin
      Channel.Receive_Exactly (Header, Timeout, On_Wait);
      return Protocol.Read_U32 (Header, Cursor);
   end Read_Length;

   function Read_Contents
     (Channel : in out Transports.Transport'Class;
      Count   : Natural;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Protocol.Byte_Array is
      Buffer : Byte_Array_Access :=
        new Protocol.Byte_Array (1 .. Protocol.Byte_Offset (Count));
   begin
      if Count > 0 then
         Channel.Receive_Exactly (Buffer.all, Timeout, On_Wait);
      end if;
      declare
         Result : constant Protocol.Byte_Array := Buffer.all;
      begin
         Free (Buffer);
         return Result;
      end;
   exception
      when others =>
         Free (Buffer);
         raise;
   end Read_Contents;

   function Read_Initial
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration) return Protocol.Initial_Request is
      Length : constant Protocol.UInt32 := Read_Length (Channel, Timeout);
   begin
      if not Wire.Valid_Initial_Length (Length) then
         raise Protocol.Protocol_Error with
           "invalid initial Postgres packet length";
      end if;
      return Protocol.Decode_Initial
        (Read_Contents
           (Channel, Natural (Wire.Content_Length (Length)), Timeout));
   end Read_Initial;

   function Read_Message
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Protocol.Message is
      Tag    : Protocol.Byte_Array (1 .. 1);
      Length : Protocol.UInt32;
   begin
      Channel.Receive_Exactly (Tag, Timeout, On_Wait);
      Length := Read_Length (Channel, Timeout, On_Wait);
      if not Wire.Valid_Typed_Length (Length) then
         raise Protocol.Protocol_Error with
           "invalid typed Postgres message length";
      end if;
      return Protocol.Make_Message
        (Character'Val (Tag (Tag'First)),
         Read_Contents
           (Channel, Natural (Wire.Content_Length (Length)), Timeout,
            On_Wait));
   end Read_Message;

   procedure Write_Message
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Message;
      Timeout : Duration) is
   begin
      Channel.Send_All (Protocol.Encode (Value), Timeout);
   end Write_Message;

   procedure Write_Packet
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Byte_Array;
      Timeout : Duration) is
   begin
      Channel.Send_All (Value, Timeout);
   end Write_Packet;

   procedure Write_Byte
     (Channel : in out Transports.Transport'Class;
      Value   : Protocol.Byte;
      Timeout : Duration) is
      Data : constant Protocol.Byte_Array (1 .. 1) := (1 => Value);
   begin
      Channel.Send_All (Data, Timeout);
   end Write_Byte;

end Flyology.Postgres.Framing;
