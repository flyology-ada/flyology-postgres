with Ada.Command_Line;
with Ada.Text_IO;
with Flyology.Operations.Drivers;

package body Repro_Support is

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;

   package Operation_Drivers renames Flyology.Operations.Drivers;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Description : String) is
   begin
      if Condition then
         Ada.Text_IO.Put_Line ("  ok: " & Description);
      else
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("  FAILED: " & Description);
      end if;
   end Check;

   procedure Note (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("  -- " & Text);
   end Note;

   procedure Finish is
   begin
      if Failures = 0 then
         Ada.Text_IO.Put_Line ("PASS");
         Ada.Command_Line.Set_Exit_Status (0);
      else
         Ada.Text_IO.Put_Line
           ("BUG REPRODUCED:" & Failures'Image & " failed expectation(s)");
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Finish;

   overriding procedure Receive_Exactly
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null) is
      pragma Unreferenced (Timeout);
      pragma Unreferenced (On_Wait);
      Available : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Input);
   begin
      if Item.Next > Available'Length + 1
        or else Data'Length > Available'Length - Item.Next + 1
      then
         raise Program_Error with "memory transport input is exhausted";
      end if;
      for Index in Data'Range loop
         Data (Index) := Available (Protocol.Byte_Offset (Item.Next));
         Item.Next := Item.Next + 1;
      end loop;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
      pragma Unreferenced (Timeout);
   begin
      Flyology.Bytes.Append (Item.Output, Data);
   end Send_All;

   overriding procedure Upgrade_TLS
     (Item        : in out Memory_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
      pragma Unreferenced (Item, Backend, Server_Name, Timeout);
   begin
      raise Program_Error with "unexpected memory transport TLS upgrade";
   end Upgrade_TLS;

   overriding procedure Start_Operation
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Result    : out Transports.Acquisition_Result;
      Timeout   : Duration) is
   begin
      if Item.Engaged then
         raise Program_Error with "memory transport is already engaged";
      end if;
      Item.Engaged := True;
      if Timeout >= 0.0 then
         Operation_Drivers.Arm_Deadline (Operation, Timeout);
      end if;
      Result := Transports.Acquired;
   end Start_Operation;

   overriding procedure Poll_Acquisition
     (Item   : in out Memory_Transport;
      Result : out Transports.Acquisition_Result) is
      pragma Unreferenced (Item);
   begin
      Result := Transports.Acquired;
   end Poll_Acquisition;

   overriding procedure Arm_Acquisition
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class) is
      pragma Unreferenced (Item);
   begin
      Operation_Drivers.Reschedule (Operation);
   end Arm_Acquisition;

   overriding procedure Receive_Step
     (Item   : in out Memory_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result) is
      Available : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Input);
      Count : Natural;
   begin
      Last := Data'First - 1;
      if Item.Fail_Receive then
         raise Program_Error with "synthetic provider receive failure";
      elsif Item.Blocked then
         Result := Transports.Need_Read;
         return;
      elsif Item.Next > Available'Length then
         Result := Transports.Peer_Closed;
         return;
      end if;
      Count := Natural'Min
        (Item.Chunk,
         Natural'Min
           (Data'Length, Available'Length - Item.Next + 1));
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Available (Protocol.Byte_Offset (Item.Next + Offset));
      end loop;
      Item.Next := Item.Next + Count;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
      Result := Transports.Made_Progress;
   end Receive_Step;

   overriding procedure Send_Step
     (Item   : in out Memory_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result) is
      Count : constant Natural := Natural'Min (Item.Chunk, Data'Length);
      Final : constant Ada.Streams.Stream_Element_Offset :=
        Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
   begin
      Flyology.Bytes.Append (Item.Output, Data (Data'First .. Final));
      Last := Final;
      Result := Transports.Made_Progress;
   end Send_Step;

   overriding procedure Arm_Transport
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Required  : Transports.Step_Result) is
      pragma Unreferenced (Item, Operation, Required);
   begin
      null;
   end Arm_Transport;

   overriding procedure Release_Operation (Item : in out Memory_Transport) is
   begin
      Item.Engaged := False;
   end Release_Operation;

   overriding procedure Cancel_Operation (Item : in out Memory_Transport) is
   begin
      Item.Engaged := False;
   end Cancel_Operation;

   procedure Queue
     (Item : in out Memory_Transport; Message : Protocol.Message) is
   begin
      Flyology.Bytes.Append (Item.Input, Protocol.Encode (Message));
   end Queue;

   procedure Queue_Bytes
     (Item : in out Memory_Transport; Data : Protocol.Byte_Array) is
   begin
      Flyology.Bytes.Append (Item.Input, Data);
   end Queue_Bytes;

   function Sent (Item : Memory_Transport) return Protocol.Byte_Array is
   begin
      return Flyology.Bytes.To_Array (Item.Output);
   end Sent;

   procedure Clear_Sent (Item : in out Memory_Transport) is
   begin
      Item.Output := Flyology.Bytes.Empty;
   end Clear_Sent;

   function Bytes_Remaining (Item : Memory_Transport) return Natural is
      Available : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Input);
   begin
      return Available'Length - Item.Next + 1;
   end Bytes_Remaining;

   function Hex (Data : Protocol.Byte_Array) return String is
      Digits_Map : constant String := "0123456789abcdef";
      Result : String (1 .. Data'Length * 3);
      Position : Natural := 0;
   begin
      for Value of Data loop
         Result (Position + 1) := Digits_Map (Natural (Value) / 16 + 1);
         Result (Position + 2) := Digits_Map (Natural (Value) mod 16 + 1);
         Result (Position + 3) := ' ';
         Position := Position + 3;
      end loop;
      return Result;
   end Hex;

   function S (Data : Protocol.Byte_Array) return String is
      Result : String (1 .. Data'Length);
      Position : Natural := 0;
   begin
      for Value of Data loop
         Position := Position + 1;
         Result (Position) := Character'Val (Value);
      end loop;
      return Result;
   end S;

   function B (Text : String) return Protocol.Byte_Array is
      Result : Protocol.Byte_Array (1 .. Text'Length);
      Position : Protocol.Byte_Offset := 0;
   begin
      for C of Text loop
         Position := Position + 1;
         Result (Position) := Protocol.Byte (Character'Pos (C));
      end loop;
      return Result;
   end B;

end Repro_Support;
