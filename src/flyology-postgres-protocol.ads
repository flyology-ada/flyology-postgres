with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;
with Flyology.Bytes;

package Flyology.Postgres.Protocol is

   subtype Byte is Ada.Streams.Stream_Element;
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype Byte_Offset is Ada.Streams.Stream_Element_Offset;
   subtype UInt16 is Interfaces.Unsigned_16;
   subtype UInt32 is Interfaces.Unsigned_32;

   Protocol_Error : exception;

   Maximum_Message_Size : constant := Flyology.Postgres.Maximum_Message_Size;

   type Frontend_Kind is
     (Bind,
      Close,
      Copy_Data,
      Copy_Done,
      Copy_Fail,
      Describe,
      Execute,
      Flush,
      Function_Call,
      Password_Or_SASL_Response,
      Parse,
      Query,
      Sync,
      Terminate_Command,
      Unknown);

   type Message is private;

   function Make_Message
     (Code : Character; Payload : Byte_Array) return Message;
   function Make_Empty_Message (Code : Character) return Message;
   function Code (Item : Message) return Character;
   function Kind (Item : Message) return Frontend_Kind;
   function Payload (Item : Message) return Byte_Array;
   function Payload_Length (Item : Message) return Natural;
   function Encode (Item : Message) return Byte_Array;

   type Initial_Kind is
     (Startup, SSL_Request, GSS_Request, Cancel_Request, Unknown_Initial);

   type Startup_Information is record
      Protocol_Major  : UInt16 := 3;
      Protocol_Minor  : UInt16 := 0;
      User            : Ada.Strings.Unbounded.Unbounded_String;
      Database        : Ada.Strings.Unbounded.Unbounded_String;
      Application_Name : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Initial_Request is private;

   function Decode_Initial (Contents : Byte_Array) return Initial_Request;
   function Kind (Item : Initial_Request) return Initial_Kind;
   function Startup_Data
     (Item : Initial_Request) return Startup_Information;
   function Process_Id (Item : Initial_Request) return UInt32;
   function Secret_Key (Item : Initial_Request) return Byte_Array;

   function Encode_Startup
     (User             : String;
      Database         : String := "";
      Application_Name : String := "flyology_postgres";
      Protocol_Major   : UInt16 := 3;
      Protocol_Minor   : UInt16 := 0) return Byte_Array;
   function Encode_SSL_Request return Byte_Array;

   procedure Append_U16
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt16);
   procedure Append_U32
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : UInt32);
   procedure Append_Byte
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte);
   procedure Append_Bytes
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Byte_Array);
   procedure Append_C_String
     (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : String);

   function Read_U16
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt16;
   function Read_U32
     (Source : Byte_Array; Cursor : in out Byte_Offset) return UInt32;
   function Read_C_String
     (Source : Byte_Array; Cursor : in out Byte_Offset) return String;

private
   type Message is record
      Tag  : Character := Character'Val (0);
      Data : Flyology.Bytes.Unbounded_Bytes;
   end record;

   type Initial_Request is record
      Request_Kind : Initial_Kind := Unknown_Initial;
      Startup      : Startup_Information;
      Backend_Pid  : UInt32 := 0;
      Secret       : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Protocol;
