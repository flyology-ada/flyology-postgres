with Ada.Streams;
with Flyology.Bytes;
with Flyology.IO.TLS;
with Flyology.Operations;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Repro_Support is
   --  Shared helpers for bug reproduction programs.  Convention: a program
   --  asserts the CORRECT behavior.  On current sources it prints
   --  "BUG REPRODUCED" and exits with status 1; after a fix it prints "PASS"
   --  and exits 0.

   package Protocol renames Flyology.Postgres.Protocol;
   package Transports renames Flyology.Postgres.Transports;
   package Operations renames Flyology.Operations;

   procedure Check (Condition : Boolean; Description : String);
   --  Record a failed expectation when Condition is False.

   procedure Note (Text : String);
   --  Print an informational line.

   procedure Finish;
   --  Print the verdict and set the process exit status.

   --  In-memory transport mirroring the one used by tests/src/tests.adb.
   --  Bytes appended to Input are consumed by the client/server under test;
   --  everything the code under test sends is appended to Output.
   type Memory_Transport is
     limited new Transports.TLS_Upgradable_Transport
       and Transports.Operation_Transport with record
         Input        : Flyology.Bytes.Unbounded_Bytes;
         Output       : Flyology.Bytes.Unbounded_Bytes;
         Next         : Natural := 1;
         Engaged      : Boolean := False;
         Blocked      : Boolean := False;
         Fail_Receive : Boolean := False;
         Chunk        : Positive := 1;
   end record;

   overriding procedure Receive_Exactly
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Upgrade_TLS
     (Item        : in out Memory_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration);

   overriding procedure Start_Operation
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Result    : out Transports.Acquisition_Result;
      Timeout   : Duration);

   overriding procedure Poll_Acquisition
     (Item   : in out Memory_Transport;
      Result : out Transports.Acquisition_Result);

   overriding procedure Arm_Acquisition
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class);

   overriding procedure Receive_Step
     (Item   : in out Memory_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result);

   overriding procedure Send_Step
     (Item   : in out Memory_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Transports.Step_Result);

   overriding procedure Arm_Transport
     (Item      : in out Memory_Transport;
      Operation : in out Operations.Operation'Class;
      Required  : Transports.Step_Result);

   overriding procedure Release_Operation (Item : in out Memory_Transport);
   overriding procedure Cancel_Operation (Item : in out Memory_Transport);

   procedure Queue
     (Item : in out Memory_Transport; Message : Protocol.Message);
   --  Append one encoded backend/frontend message to Input.

   procedure Queue_Bytes
     (Item : in out Memory_Transport; Data : Protocol.Byte_Array);
   --  Append raw bytes to Input.

   function Sent (Item : Memory_Transport) return Protocol.Byte_Array;
   --  Everything written so far.

   procedure Clear_Sent (Item : in out Memory_Transport);

   function Bytes_Remaining (Item : Memory_Transport) return Natural;
   --  Unconsumed Input bytes.

   function Hex (Data : Protocol.Byte_Array) return String;

   function S (Data : Protocol.Byte_Array) return String;
   --  Bytes as a String (for ASCII payloads).

   function B (Text : String) return Protocol.Byte_Array;
   --  String as bytes.

end Repro_Support;
