with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;
with Flyology.Bytes;
private with Ada.Containers.Vectors;

package Flyology.Postgres.Protocol is

   use type Interfaces.Integer_16;
   use type Interfaces.Integer_32;

   subtype Byte is Ada.Streams.Stream_Element;
   subtype Byte_Array is Ada.Streams.Stream_Element_Array;
   subtype Byte_Offset is Ada.Streams.Stream_Element_Offset;
   subtype UInt16 is Interfaces.Unsigned_16;
   subtype UInt32 is Interfaces.Unsigned_32;
   subtype Int16 is Interfaces.Integer_16;
   subtype Int32 is Interfaces.Integer_32;

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

   type Backend_Message_Kind is
     (Row_Description_Response,
      Data_Row_Response,
      Command_Complete_Response,
      Empty_Query_Response,
      Error_Response,
      Notice_Response,
      Parameter_Status_Response,
      Ready_For_Query_Response,
      Unknown_Response);

   type Field_Format is (Text_Format, Binary_Format);

   type Field_Description is private;
   type Field_Description_Array is
     array (Positive range <>) of Field_Description;

   function Make_Field_Description
     (Name                    : String;
      Table_Oid               : UInt32 := 0;
      Column_Attribute_Number : Int16 := 0;
      Type_Oid                : UInt32 := 25;
      Type_Size               : Int16 := -1;
      Type_Modifier           : Int32 := -1;
      Format                  : Field_Format := Text_Format)
      return Field_Description;
   function Field_Name (Item : Field_Description) return String;
   function Table_Oid (Item : Field_Description) return UInt32;
   function Column_Attribute_Number
     (Item : Field_Description) return Int16;
   function Type_Oid (Item : Field_Description) return UInt32;
   function Type_Size (Item : Field_Description) return Int16;
   function Type_Modifier (Item : Field_Description) return Int32;
   function Format (Item : Field_Description) return Field_Format;

   type Row_Description is private;
   function Field_Count (Item : Row_Description) return Natural;
   function Field_At
     (Item : Row_Description; Index : Positive) return Field_Description;

   type Column_Value is private;
   type Column_Value_Array is array (Positive range <>) of Column_Value;

   Null_Column : constant Column_Value;
   function Text_Column (Value : String) return Column_Value;
   function Binary_Column (Value : Byte_Array) return Column_Value;
   function Is_Null (Item : Column_Value) return Boolean;
   function Column_Bytes (Item : Column_Value) return Byte_Array;
   function Column_Text (Item : Column_Value) return String;

   type Data_Row is private;
   function Column_Count (Item : Data_Row) return Natural;
   function Column_At
     (Item : Data_Row; Index : Positive) return Column_Value;

   type Diagnostic is private;
   function Field_Text
     (Item : Diagnostic; Code : Character) return String;
   function Severity (Item : Diagnostic) return String;
   function Nonlocalized_Severity (Item : Diagnostic) return String;
   function Diagnostic_SQL_State (Item : Diagnostic) return String;
   function Diagnostic_Message (Item : Diagnostic) return String;

   type Parameter_Status is private;
   function Parameter_Name (Item : Parameter_Status) return String;
   function Parameter_Value (Item : Parameter_Status) return String;

   type Transaction_Status is
     (Idle, In_Transaction, Failed_Transaction);

   type Backend_Message (Response : Backend_Message_Kind := Unknown_Response)
     is private;
   --  Decode supported backend payloads strictly while retaining Item for raw
   --  access through Original_Message. Unknown tags remain Unknown_Response.
   function Decode_Backend (Item : Message) return Backend_Message;
   function Response_Kind (Item : Backend_Message) return Backend_Message_Kind;
   function Description (Item : Backend_Message) return Row_Description;
   function Row_Data (Item : Backend_Message) return Data_Row;
   function Completion_Tag (Item : Backend_Message) return String;
   function Diagnostic_Data (Item : Backend_Message) return Diagnostic;
   function Parameter_Data (Item : Backend_Message) return Parameter_Status;
   function Transaction_State
     (Item : Backend_Message) return Transaction_Status;
   function Original_Message (Item : Backend_Message) return Message;

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

   type Field_Description is record
      Name_Value                    : Ada.Strings.Unbounded.Unbounded_String;
      Table_Oid_Value               : UInt32 := 0;
      Column_Attribute_Number_Value : Int16 := 0;
      Type_Oid_Value                : UInt32 := 25;
      Type_Size_Value               : Int16 := -1;
      Type_Modifier_Value           : Int32 := -1;
      Format_Value                  : Field_Format := Text_Format;
   end record;

   package Field_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field_Description);

   type Row_Description is record
      Fields : Field_Vectors.Vector;
   end record;

   type Column_Value is record
      Null_Value : Boolean := True;
      Bytes      : Flyology.Bytes.Unbounded_Bytes;
   end record;

   Null_Column : constant Column_Value :=
     (Null_Value => True, Bytes => Flyology.Bytes.Empty);

   package Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column_Value);

   type Data_Row is record
      Columns : Column_Vectors.Vector;
   end record;

   type Diagnostic_Field_Value is record
      Code : Character := Character'Val (0);
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Diagnostic_Field_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Diagnostic_Field_Value);

   type Diagnostic is record
      Fields : Diagnostic_Field_Vectors.Vector;
   end record;

   type Parameter_Status is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Backend_Message (Response : Backend_Message_Kind := Unknown_Response)
   is record
      Raw : Message;
      case Response is
         when Row_Description_Response =>
            Row_Description_Value : Row_Description;
         when Data_Row_Response =>
            Data_Row_Value : Data_Row;
         when Command_Complete_Response =>
            Command_Tag_Value : Ada.Strings.Unbounded.Unbounded_String;
         when Error_Response | Notice_Response =>
            Diagnostic_Value : Diagnostic;
         when Parameter_Status_Response =>
            Parameter_Status_Value : Parameter_Status;
         when Ready_For_Query_Response =>
            Transaction_Status_Value : Transaction_Status := Idle;
         when Empty_Query_Response | Unknown_Response =>
            null;
      end case;
   end record;

   type Initial_Request is record
      Request_Kind : Initial_Kind := Unknown_Initial;
      Startup      : Startup_Information;
      Backend_Pid  : UInt32 := 0;
      Secret       : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Protocol;
