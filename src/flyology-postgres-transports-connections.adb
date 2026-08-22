with Flyology.IO.Connections.TLS;

package body Flyology.Postgres.Transports.Connections is

   package Drivers renames Flyology.IO.Connections.Drivers;

   procedure Map
     (Value  : Drivers.Acquisition_Result;
      Result : out Acquisition_Result) is
   begin
      case Value is
         when Drivers.Acquired =>
            Result := Acquired;
         when Drivers.Need_Acquire_Readiness =>
            Result := Need_Acquire_Readiness;
      end case;
   end Map;

   procedure Map
     (Value  : Drivers.Step_Result;
      Result : out Step_Result) is
   begin
      case Value is
         when Drivers.Made_Progress =>
            Result := Made_Progress;
         when Drivers.Need_Read =>
            Result := Need_Read;
         when Drivers.Need_Write =>
            Result := Need_Write;
         when Drivers.Peer_Closed =>
            Result := Peer_Closed;
      end case;
   end Map;

   overriding procedure Receive_Exactly
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null) is
      pragma Unreferenced (On_Wait);
      --  The adapted connection fills the buffer in one call, so there is no
      --  point between reads at which an observer could run.
   begin
      Item.Channel.Receive_Exactly
        (Data, Timeout => Timeout, Token => Item.Token);
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      Item.Channel.Send_All
        (Data, Timeout => Timeout, Token => Item.Token);
   end Send_All;

   overriding procedure Upgrade_TLS
     (Item        : in out Connection_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
   begin
      Flyology.IO.Connections.TLS.Upgrade
        (Item.Channel.all,
         Backend,
         Flyology.IO.TLS.Client,
         Server_Name,
         Timeout => Timeout,
         Token   => Item.Token);
   end Upgrade_TLS;

   overriding procedure Start_Operation
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Result    : out Acquisition_Result;
      Timeout   : Duration) is
      Acquired_State : Drivers.Acquisition_Result;
   begin
      Drivers.Start
        (Item.IO,
         Item.Channel,
         Acquired_State,
         Timeout => Timeout,
         Token   => Item.Token);
      Drivers.Arm_Deadline (Item.IO, Operation);
      Map (Acquired_State, Result);
   end Start_Operation;

   overriding procedure Poll_Acquisition
     (Item   : in out Connection_Transport;
      Result : out Acquisition_Result) is
      Acquired_State : Drivers.Acquisition_Result;
   begin
      Drivers.Poll_Acquisition (Item.IO, Acquired_State);
      Map (Acquired_State, Result);
   end Poll_Acquisition;

   overriding procedure Arm_Acquisition
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class) is
   begin
      Drivers.Arm_Acquisition (Item.IO, Operation);
   end Arm_Acquisition;

   overriding procedure Receive_Step
     (Item   : in out Connection_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result) is
      State : Drivers.Step_Result;
   begin
      Drivers.Receive (Item.IO, Data, Last, State);
      Map (State, Result);
   end Receive_Step;

   overriding procedure Send_Step
     (Item   : in out Connection_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result) is
      State : Drivers.Step_Result;
   begin
      Drivers.Send (Item.IO, Data, Last, State);
      Map (State, Result);
   end Send_Step;

   overriding procedure Arm_Transport
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result) is
      State : Drivers.Step_Result;
   begin
      case Required is
         when Need_Read =>
            State := Drivers.Need_Read;
         when Need_Write =>
            State := Drivers.Need_Write;
         when Made_Progress | Peer_Closed =>
            raise Program_Error with
              "Postgres transport cannot arm a completed step";
      end case;
      Drivers.Arm_Deadline (Item.IO, Operation);
      Drivers.Arm_Transport (Item.IO, Operation, State);
   end Arm_Transport;

   overriding procedure Release_Operation
     (Item : in out Connection_Transport) is
   begin
      Drivers.Release (Item.IO);
   end Release_Operation;

   overriding procedure Cancel_Operation
     (Item : in out Connection_Transport) is
   begin
      Drivers.Cancel (Item.IO);
   end Cancel_Operation;

end Flyology.Postgres.Transports.Connections;
