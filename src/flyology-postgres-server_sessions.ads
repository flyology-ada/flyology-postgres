with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Server_Sessions is

   type Session
     (Channel : not null access Transports.Transport'Class) is limited private;

   function Read_Initial
     (Item : in out Session;
      Timeout : Duration) return Protocol.Initial_Request;
   function Read_Command
     (Item : in out Session; Timeout : Duration) return Protocol.Message;

   procedure Send
     (Item    : in out Session;
      Value   : Protocol.Message;
      Timeout : Duration);
   procedure Refuse_TLS
     (Item : in out Session; Timeout : Duration);
   procedure Refuse_GSS
     (Item : in out Session; Timeout : Duration);

   procedure Send_Authentication_Ok
     (Item : in out Session; Timeout : Duration);
   procedure Send_Authentication_Cleartext_Password
     (Item : in out Session; Timeout : Duration);
   procedure Send_Negotiate_Protocol
     (Item         : in out Session;
      Latest_Minor : Protocol.UInt32;
      Timeout      : Duration);
   procedure Send_Parameter_Status
     (Item    : in out Session;
      Name    : String;
      Value   : String;
      Timeout : Duration);
   procedure Send_Backend_Key_Data
     (Item       : in out Session;
      Process_Id : Protocol.UInt32;
      Secret_Key : Protocol.Byte_Array;
      Timeout    : Duration);
   procedure Send_Ready
     (Item               : in out Session;
      Transaction_Status : Character := 'I';
      Timeout            : Duration);
   procedure Send_Error
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "XX000";
      Severity  : String := "ERROR";
      Timeout   : Duration);
   procedure Send_Notice
     (Item      : in out Session;
      Message   : String;
      SQL_State : String := "00000";
      Severity  : String := "NOTICE";
      Timeout   : Duration);
   procedure Send_Command_Complete
     (Item : in out Session; Tag : String; Timeout : Duration);
   procedure Send_Empty_Query_Response
     (Item : in out Session; Timeout : Duration);
   procedure Send_Parse_Complete
     (Item : in out Session; Timeout : Duration);
   procedure Send_Bind_Complete
     (Item : in out Session; Timeout : Duration);
   procedure Send_Close_Complete
     (Item : in out Session; Timeout : Duration);
   procedure Send_No_Data
     (Item : in out Session; Timeout : Duration);
   procedure Send_Row_Description
     (Item    : in out Session;
      Columns : Protocol.Field_Description_Array;
      Timeout : Duration);
   procedure Send_Row_Description
     (Item      : in out Session;
      Name      : String;
      Type_Oid  : Protocol.UInt32 := 25;
      Type_Size : Protocol.UInt16 := 16#FFFF#;
      Timeout   : Duration);
   procedure Send_Data_Row
     (Item    : in out Session;
      Values  : Protocol.Column_Value_Array;
      Timeout : Duration);
   procedure Send_Data_Row
     (Item : in out Session; Value : String; Timeout : Duration);
   procedure Send_Null_Data_Row
     (Item : in out Session; Timeout : Duration);

   function Query_Text (Command : Protocol.Message) return String;
   function Password_Text (Command : Protocol.Message) return String;

private
   type Session
     (Channel : not null access Transports.Transport'Class) is limited
   null record;

end Flyology.Postgres.Server_Sessions;
