with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Client is

   Database_Error : exception;
   Unsupported_Authentication : exception;

   type Session
     (Channel : not null access Transports.Transport'Class) is limited private;

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0);

   procedure Send_Command
     (Item    : in out Session;
      Command : Protocol.Message;
      Timeout : Duration := 30.0);
   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0);
   function Receive_Message
     (Item : in out Session; Timeout : Duration := 30.0)
      return Protocol.Message;

   function Is_Ready (Item : Session) return Boolean;
   function Backend_Process_Id (Item : Session) return Protocol.UInt32;
   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array;

   function Error_Message (Value : Protocol.Message) return String;
   function SQL_State (Value : Protocol.Message) return String;

private
   type Session
     (Channel : not null access Transports.Transport'Class) is limited record
      Started : Boolean := False;
      Ready   : Boolean := False;
      Pid     : Protocol.UInt32 := 0;
      Secret  : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.Postgres.Client;
