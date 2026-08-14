with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Postgres.Framing;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with System;

package body Flyology.Postgres.Client is

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;
   use type System.Address;
   use type Protocol.Backend_Message_Kind;

   procedure Reset_Copy (Item : in out Session) is
   begin
      Item.Current_Copy_Origin := No_Copy;
      Item.Copy_Send_Open := False;
      Item.Copy_Receive_Open := False;
      Item.Copy_Bidirectional := False;
      Item.Copy_Sync_Pending := False;
   end Reset_Copy;

   procedure Enter_Copy
     (Item         : in out Session;
      Response     : Protocol.Backend_Message_Kind;
      Origin       : Copy_Origin;
      Sync_Pending : Boolean := False) is
   begin
      Item.Current_Copy_Origin := Origin;
      Item.Copy_Sync_Pending := Sync_Pending;
      case Response is
         when Protocol.Copy_In_Response =>
            Item.Current_State := Copy_In_Active;
            Item.Copy_Send_Open := True;
            Item.Copy_Receive_Open := False;
            Item.Copy_Bidirectional := False;
         when Protocol.Copy_Out_Response =>
            Item.Current_State := Copy_Out_Active;
            Item.Copy_Send_Open := False;
            Item.Copy_Receive_Open := True;
            Item.Copy_Bidirectional := False;
         when Protocol.Copy_Both_Response =>
            Item.Current_State := Copy_Both_Active;
            Item.Copy_Send_Open := True;
            Item.Copy_Receive_Open := True;
            Item.Copy_Bidirectional := True;
         when others =>
            raise Program_Error with "response does not start COPY";
      end case;
   end Enter_Copy;

   function Error_Message (Value : Protocol.Message) return String is
     (Protocol.Diagnostic_Message
        (Protocol.Diagnostic_Data (Protocol.Decode_Backend (Value))));

   function SQL_State (Value : Protocol.Message) return String is
     (Protocol.Diagnostic_SQL_State
        (Protocol.Diagnostic_Data (Protocol.Decode_Backend (Value))));

   procedure Send_Password
     (Item : in out Session; Password : String; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Password);
      Framing.Write_Message
        (Item.Channel.all,
         Protocol.Make_Message
           ('p', Flyology.Bytes.To_Array (Contents)),
         Timeout);
   end Send_Password;

   function Payload_Text
     (Contents : Protocol.Byte_Array;
      First    : Protocol.Byte_Offset) return String is
      Result : String (1 .. Natural (Contents'Last - First + 1));
      Cursor : Protocol.Byte_Offset := First;
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Contents (Cursor));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end Payload_Text;

   procedure Send_SASL_Initial
     (Item     : in out Session;
      User     : String;
      Nonce    : String;
      Timeout  : Duration) is
      Response : constant String :=
        Flyology.Postgres.SCRAM.Client_First_Message (User, Nonce);
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String
        (Contents, Flyology.Postgres.SCRAM.Mechanism);
      Protocol.Append_U32 (Contents, Protocol.UInt32 (Response'Length));
      Flyology.Bytes.Append_Byte_String (Contents, Response);
      Framing.Write_Message
        (Item.Channel.all,
         Protocol.Make_Message
           ('p', Flyology.Bytes.To_Array (Contents)),
         Timeout);
   end Send_SASL_Initial;

   procedure Send_SASL_Response
     (Item : in out Session; Response : String; Timeout : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Flyology.Bytes.Append_Byte_String (Contents, Response);
      Framing.Write_Message
        (Item.Channel.all,
         Protocol.Make_Message
           ('p', Flyology.Bytes.To_Array (Contents)),
         Timeout);
   end Send_SASL_Response;

   procedure Complete_Startup
     (Item             : in out Session;
      User             : String;
      Database         : String;
      Password         : String;
      Application_Name : String;
      Timeout          : Duration;
      Replication_Mode : Protocol.Replication_Connection_Mode) is
      type SASL_Phase is
        (No_SASL, Awaiting_Continue, Awaiting_Final, Final_Verified);
      Phase : SASL_Phase := No_SASL;
      Nonce : Unbounded_String;
      Bare_Client_First : Unbounded_String;
      Expected_Server_Signature : Flyology.Postgres.SCRAM.Digest :=
        (others => 0);
      Authentication_Ok : Boolean := False;
   begin
      if Item.Current_State /= Not_Started then
         raise Program_Error with "Postgres session is already started";
      end if;

      Framing.Write_Packet
        (Item.Channel.all,
         Protocol.Encode_Startup
           (User             => User,
            Database         => Database,
            Application_Name => Application_Name,
            Protocol_Minor   => 2,
            Replication_Mode => Replication_Mode),
         Timeout);

      loop
         declare
            Response : constant Protocol.Message :=
              Framing.Read_Message (Item.Channel.all, Timeout);
            Contents : constant Protocol.Byte_Array :=
              Protocol.Payload (Response);
         begin
            case Protocol.Code (Response) is
               when 'R' =>
                  declare
                     Cursor : Protocol.Byte_Offset := Contents'First;
                     Method : constant Protocol.UInt32 :=
                       Protocol.Read_U32 (Contents, Cursor);
                  begin
                     case Method is
                        when 0 =>
                           if Phase in Awaiting_Continue | Awaiting_Final then
                              raise Protocol.Protocol_Error with
                                "AuthenticationOk arrived before SCRAM "
                                & "completed";
                           end if;
                           Authentication_Ok := True;
                        when 3 =>
                           if Phase /= No_SASL then
                              raise Protocol.Protocol_Error with
                                "unexpected cleartext authentication request";
                           end if;
                           Send_Password (Item, Password, Timeout);
                        when 10 =>
                           if Phase /= No_SASL then
                              raise Protocol.Protocol_Error with
                                "duplicate SASL authentication request";
                           end if;
                           declare
                              Offered : Boolean := False;
                              Terminated : Boolean := False;
                           begin
                              while Cursor <= Contents'Last loop
                                 declare
                                    Name : constant String :=
                                      Protocol.Read_C_String
                                        (Contents, Cursor);
                                 begin
                                    if Name'Length = 0 then
                                       Terminated := True;
                                       exit;
                                    elsif Name =
                                      Flyology.Postgres.SCRAM.Mechanism
                                    then
                                       Offered := True;
                                    end if;
                                 end;
                              end loop;
                              if not Terminated
                                or else Cursor <= Contents'Last
                              then
                                 raise Protocol.Protocol_Error with
                                   "malformed AuthenticationSASL "
                                   & "mechanism list";
                              elsif not Offered then
                                 raise Unsupported_Authentication with
                                   "server did not offer SCRAM-SHA-256";
                              end if;
                           end;
                           Nonce := To_Unbounded_String
                             (Flyology.Postgres.SCRAM.Random_Nonce);
                           Bare_Client_First := To_Unbounded_String
                             (Flyology.Postgres.SCRAM.Client_First_Bare
                                (User, To_String (Nonce)));
                           Send_SASL_Initial
                             (Item, User, To_String (Nonce), Timeout);
                           Phase := Awaiting_Continue;
                        when 11 =>
                           if Phase /= Awaiting_Continue then
                              raise Protocol.Protocol_Error with
                                "unexpected AuthenticationSASLContinue";
                           end if;
                           declare
                              Server_First : constant String :=
                                Payload_Text (Contents, Cursor);
                              Client_Final : constant String :=
                                Flyology.Postgres.SCRAM.Client_Final_Message
                                  (Password,
                                   To_String (Bare_Client_First),
                                   Server_First,
                                   To_String (Nonce),
                                   Expected_Server_Signature);
                           begin
                              Send_SASL_Response
                                (Item, Client_Final, Timeout);
                              Phase := Awaiting_Final;
                           end;
                        when 12 =>
                           if Phase /= Awaiting_Final then
                              raise Protocol.Protocol_Error with
                                "unexpected AuthenticationSASLFinal";
                           end if;
                           Flyology.Postgres.SCRAM.Verify_Server_Final
                             (Payload_Text (Contents, Cursor),
                              Expected_Server_Signature);
                           Flyology.Postgres.SCRAM_Core.Wipe
                             (Expected_Server_Signature);
                           Phase := Final_Verified;
                        when others =>
                           raise Unsupported_Authentication with
                             "server requested unsupported authentication"
                             & Method'Image;
                     end case;
                  end;
               when 'K' =>
                  if Contents'Length not in 8 .. 260 then
                     raise Protocol.Protocol_Error with
                       "invalid BackendKeyData secret length";
                  end if;
                  declare
                     Cursor : Protocol.Byte_Offset := Contents'First;
                  begin
                     Item.Pid := Protocol.Read_U32 (Contents, Cursor);
                     Item.Secret := Flyology.Bytes.To_Unbounded_Bytes
                       (Contents (Cursor .. Contents'Last));
                  end;
               when 'E' =>
                  Flyology.Postgres.SCRAM_Core.Wipe
                    (Expected_Server_Signature);
                  raise Database_Error with
                    SQL_State (Response) & ": " & Error_Message (Response);
               when 'N' | 'S' =>
                  declare
                     Ignored : constant Protocol.Backend_Message :=
                       Protocol.Decode_Backend (Response);
                  begin
                     null;
                  end;
               when 'Z' =>
                  declare
                     Ignored : constant Protocol.Backend_Message :=
                       Protocol.Decode_Backend (Response);
                  begin
                     null;
                  end;
                  if not Authentication_Ok then
                     raise Protocol.Protocol_Error with
                       "ReadyForQuery arrived before AuthenticationOk";
                  end if;
                  Item.Current_State := Ready;
                  return;
               when others =>
                  null;
            end case;
         end;
      end loop;
   exception
      when Error : Flyology.Postgres.SCRAM.SCRAM_Error =>
         Flyology.Postgres.SCRAM_Core.Wipe
           (Expected_Server_Signature);
         raise Protocol.Protocol_Error with
           Ada.Exceptions.Exception_Message (Error);
      when others =>
         Flyology.Postgres.SCRAM_Core.Wipe
           (Expected_Server_Signature);
         raise;
   end Complete_Startup;

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection) is
   begin
      Complete_Startup
        (Item,
         User,
         Database,
         Password,
         Application_Name,
         Timeout,
         Replication_Mode);
   end Startup;

   procedure Startup_TLS
     (Item             : in out Session;
      Backend          : in out Flyology.IO.TLS.Provider'Class;
      Server_Name      : String;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection) is
      Response : Protocol.Byte_Array (1 .. 1);
   begin
      if Item.Current_State /= Not_Started then
         raise Program_Error with "Postgres session is already started";
      elsif Server_Name'Length = 0 then
         raise Program_Error with "Postgres TLS requires a server name";
      elsif Item.Channel.all not in
        Transports.TLS_Upgradable_Transport'Class
      then
         raise Program_Error with
           "Postgres transport does not support TLS upgrade";
      end if;

      begin
         Framing.Write_Packet
           (Item.Channel.all, Protocol.Encode_SSL_Request, Timeout);
         Item.Channel.Receive_Exactly (Response, Timeout);
         if Response (Response'First) /=
           Protocol.Byte (Character'Pos ('S'))
         then
            raise TLS_Not_Available with "Postgres server refused TLS";
         end if;

         Transports.Upgrade_TLS
           (Transports.TLS_Upgradable_Transport'Class (Item.Channel.all),
            Backend,
            Server_Name,
            Timeout);
         Complete_Startup
           (Item,
            User,
            Database,
            Password,
            Application_Name,
            Timeout,
            Replication_Mode);
      exception
         when others =>
            Item.Current_State := Closed;
            raise;
      end;
   end Startup_TLS;

   procedure Send_Command
     (Item    : in out Session;
      Command : Protocol.Message;
      Timeout : Duration := 30.0) is
   begin
      if Item.Current_State in Not_Started | Closed then
         raise Program_Error with "Postgres session is not started";
      end if;
      if Item.Current_State = Recovery_Required
        and then Protocol.Kind (Command) /= Protocol.Sync
        and then Protocol.Kind (Command) /= Protocol.Terminate_Command
      then
         raise Program_Error with
           "Postgres extended-query recovery requires Sync";
      end if;
      if Item.Current_State = Awaiting_Ready
        and then Protocol.Kind (Command) /= Protocol.Terminate_Command
      then
         raise Program_Error with
           "Postgres session is awaiting ReadyForQuery";
      end if;
      if Protocol.Kind (Command) in Protocol.Copy_Data |
         Protocol.Copy_Done | Protocol.Copy_Fail
        and then (Item.Current_State not in
                    Copy_In_Active | Copy_Both_Active
                  or else not Item.Copy_Send_Open)
      then
         raise Program_Error with "no writable Postgres COPY stream is active";
      end if;
      Framing.Write_Message (Item.Channel.all, Command, Timeout);
      case Protocol.Kind (Command) is
         when Protocol.Query =>
            Item.Current_State := Simple_Query_Active;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
         when Protocol.Parse |
              Protocol.Bind |
              Protocol.Describe |
              Protocol.Execute |
              Protocol.Close |
              Protocol.Flush =>
            if Item.Current_State = Ready then
               Item.Current_State := Extended_Query_Active;
               Item.Bound_In_Cycle := False;
               Item.Portal_Is_Suspended := False;
            end if;
         when Protocol.Sync =>
            Item.Current_State := Awaiting_Ready;
            if Item.Current_Copy_Origin = Extended_Copy then
               Item.Copy_Sync_Pending := True;
            end if;
         when Protocol.Copy_Data =>
            null;
         when Protocol.Copy_Done | Protocol.Copy_Fail =>
            Item.Copy_Send_Open := False;
            if Item.Current_State /= Copy_Both_Active
              or else not Item.Copy_Receive_Open
            then
               Item.Current_State := Copy_Completion_Active;
            end if;
         when Protocol.Terminate_Command =>
            Item.Current_State := Closed;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
            Reset_Copy (Item);
         when others =>
            null;
      end case;
   end Send_Command;

   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Item.Current_State /= Ready then
         raise Program_Error with "Postgres session is not ready for a query";
      end if;
      if SQL'Length > Protocol.Maximum_Message_Size - 5 then
         raise Protocol.Protocol_Error with
           "Query message exceeds the configured limit";
      end if;
      Protocol.Append_C_String (Contents, SQL);
      Send_Command
        (Item,
         Protocol.Make_Message
           ('Q', Flyology.Bytes.To_Array (Contents)),
         Timeout);
   end Send_Query;

   procedure Send_Cancel_Request
     (Item                 : Session;
      Cancellation_Channel : in out Transports.Transport'Class;
      Timeout              : Duration := 30.0) is
      Secret : constant Protocol.Byte_Array :=
        Flyology.Bytes.To_Array (Item.Secret);
   begin
      if Item.Current_State in Not_Started | Closed
        or else Secret'Length not in 4 .. 256
      then
         raise Program_Error with
           "Postgres session has no backend cancellation key";
      end if;
      if Cancellation_Channel'Address = Item.Channel.all'Address then
         raise Program_Error with
           "CancelRequest requires a distinct Postgres transport";
      end if;
      Framing.Write_Packet
        (Cancellation_Channel,
         Protocol.Encode_Cancel_Request (Item.Pid, Secret),
         Timeout);
   end Send_Cancel_Request;

   function Receive_Message
     (Item : in out Session; Timeout : Duration := 30.0)
      return Protocol.Message is
      Response : constant Protocol.Message :=
        Framing.Read_Message (Item.Channel.all, Timeout);
   begin
      case Protocol.Code (Response) is
         when 'G' | 'H' | 'W' =>
            declare
               Decoded : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               if Item.Current_State = Simple_Query_Active then
                  Enter_Copy
                    (Item,
                     Protocol.Response_Kind (Decoded),
                     Origin => Simple_Copy);
               elsif Item.Current_State in
                 Extended_Query_Active | Awaiting_Ready
               then
                  Enter_Copy
                    (Item,
                     Protocol.Response_Kind (Decoded),
                     Origin       => Extended_Copy,
                     Sync_Pending => Item.Current_State = Awaiting_Ready);
               end if;
            end;
         when 'c' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            if Item.Current_Copy_Origin /= No_Copy
              and then Item.Copy_Receive_Open
            then
               Item.Copy_Receive_Open := False;
               if not Item.Copy_Send_Open then
                  Item.Current_State := Copy_Completion_Active;
               end if;
            end if;
         when 'C' =>
            if Item.Current_Copy_Origin /= No_Copy then
               declare
                  Ignored : constant Protocol.Backend_Message :=
                    Protocol.Decode_Backend (Response);
               begin
                  null;
               end;
               if Item.Current_Copy_Origin = Simple_Copy then
                  Item.Current_State := Simple_Query_Active;
                  Reset_Copy (Item);
               elsif Item.Copy_Sync_Pending then
                  Item.Current_State := Awaiting_Ready;
               else
                  Item.Current_State := Extended_Query_Active;
                  Reset_Copy (Item);
               end if;
            end if;
         when 'E' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            if Item.Current_Copy_Origin = Simple_Copy then
               Item.Copy_Send_Open := False;
               Item.Copy_Receive_Open := False;
               Item.Current_State := Copy_Completion_Active;
            elsif Item.Current_Copy_Origin = Extended_Copy then
               if Item.Copy_Sync_Pending then
                  Item.Current_State := Awaiting_Ready;
               else
                  Item.Current_State := Recovery_Required;
                  Reset_Copy (Item);
               end if;
            elsif Item.Current_State = Extended_Query_Active then
               Item.Current_State := Recovery_Required;
            end if;
         when 'Z' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            Item.Current_State := Ready;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
            Reset_Copy (Item);
         when others =>
            null;
      end case;
      return Response;
   end Receive_Message;

   function Receive_Query_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Simple_Query_Event is
      Response : Protocol.Backend_Message;
   begin
      if Item.Current_State /= Simple_Query_Active then
         raise Program_Error with "no simple query is active";
      end if;

      Response := Protocol.Decode_Backend
        (Framing.Read_Message (Item.Channel.all, Timeout));
      case Protocol.Response_Kind (Response) is
         when Protocol.Row_Description_Response =>
            if Item.Has_Row_Description then
               raise Protocol.Protocol_Error with
                 "received RowDescription before the prior result completed";
            end if;
            Item.Described_Columns := Protocol.Field_Count
              (Protocol.Description (Response));
            Item.Has_Row_Description := True;

         when Protocol.Data_Row_Response =>
            if not Item.Has_Row_Description then
               raise Protocol.Protocol_Error with
                 "received DataRow without a RowDescription";
            end if;
            if Protocol.Column_Count (Protocol.Row_Data (Response)) /=
              Item.Described_Columns
            then
               raise Protocol.Protocol_Error with
                 "DataRow column count does not match RowDescription";
            end if;

         when Protocol.Command_Complete_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;

         when Protocol.Empty_Query_Response | Protocol.Error_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;

         when Protocol.Ready_For_Query_Response =>
            Item.Current_State := Ready;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;

         when Protocol.Copy_In_Response |
              Protocol.Copy_Out_Response |
              Protocol.Copy_Both_Response =>
            Enter_Copy
              (Item,
               Protocol.Response_Kind (Response),
               Origin => Simple_Copy);

         when Protocol.Copy_Data_Response |
              Protocol.Copy_Done_Response =>
            raise Protocol.Protocol_Error with
              "received COPY stream data before a COPY response";

         when Protocol.Notice_Response |
              Protocol.Parameter_Status_Response |
              Protocol.Parse_Complete_Response |
              Protocol.Bind_Complete_Response |
              Protocol.Close_Complete_Response |
              Protocol.Parameter_Description_Response |
              Protocol.No_Data_Response |
              Protocol.Portal_Suspended_Response |
              Protocol.Unknown_Response =>
            null;
      end case;
      return Response;
   end Receive_Query_Event;

   procedure Require_Extended_Send (Item : Session; Operation : String) is
   begin
      if Item.Current_State not in Ready | Extended_Query_Active then
         raise Program_Error with
           "cannot " & Operation & " while Postgres session state is "
           & Item.Current_State'Image;
      end if;
   end Require_Extended_Send;

   procedure Prepare_Statement
     (Item            : in out Session;
      Statement_Name  : String;
      SQL             : String;
      Parameter_Types : Protocol.Oid_Array := Protocol.No_Oids;
      Timeout         : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "prepare a statement");
      Send_Command
        (Item,
         Protocol.Make_Parse_Message
           (Statement_Name, SQL, Parameter_Types),
         Timeout);
   end Prepare_Statement;

   procedure Bind_Portal
     (Item           : in out Session;
      Portal_Name    : String;
      Statement_Name : String;
      Parameters     : Protocol.Bind_Parameter_Array :=
        Protocol.No_Parameters;
      Result_Formats : Protocol.Field_Format_Array := Protocol.No_Formats;
      Timeout        : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "bind a portal");
      Send_Command
        (Item,
         Protocol.Make_Bind_Message
           (Portal_Name, Statement_Name, Parameters, Result_Formats),
         Timeout);
      Item.Bound_In_Cycle := True;
      Item.Portal_Is_Suspended := False;
   end Bind_Portal;

   procedure Describe_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "describe a statement");
      Send_Command
        (Item,
         Protocol.Make_Describe_Message
           (Protocol.Statement_Object, Statement_Name),
         Timeout);
   end Describe_Statement;

   procedure Describe_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "describe a portal");
      Send_Command
        (Item,
         Protocol.Make_Describe_Message
           (Protocol.Portal_Object, Portal_Name),
         Timeout);
   end Describe_Portal;

   procedure Execute_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "execute a portal");
      if not Item.Bound_In_Cycle then
         raise Program_Error with
           "cannot execute a portal before binding it in this query cycle";
      end if;
      if Item.Portal_Is_Suspended then
         raise Program_Error with
           "use Resume_Portal for a suspended portal";
      end if;
      Send_Command
        (Item,
         Protocol.Make_Execute_Message (Portal_Name, Maximum_Rows),
         Timeout);
   end Execute_Portal;

   procedure Resume_Portal
      (Item         : in out Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0) is
   begin
      if Item.Current_State /= Extended_Query_Active
        or else not Item.Portal_Is_Suspended
      then
         raise Program_Error with
           "no suspended Postgres portal can be resumed";
      end if;
      Item.Portal_Is_Suspended := False;
      Send_Command
        (Item,
         Protocol.Make_Execute_Message (Portal_Name, Maximum_Rows),
         Timeout);
   end Resume_Portal;

   procedure Close_Statement
     (Item           : in out Session;
      Statement_Name : String;
      Timeout        : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "close a statement");
      Send_Command
        (Item,
         Protocol.Make_Close_Message
           (Protocol.Statement_Object, Statement_Name),
         Timeout);
   end Close_Statement;

   procedure Close_Portal
     (Item        : in out Session;
      Portal_Name : String;
      Timeout     : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "close a portal");
      Send_Command
        (Item,
         Protocol.Make_Close_Message (Protocol.Portal_Object, Portal_Name),
         Timeout);
   end Close_Portal;

   procedure Flush
     (Item : in out Session; Timeout : Duration := 30.0) is
   begin
      Require_Extended_Send (Item, "flush extended-query output");
      Send_Command (Item, Protocol.Make_Flush_Message, Timeout);
   end Flush;

   procedure Synchronize
     (Item : in out Session; Timeout : Duration := 30.0) is
   begin
      if Item.Current_State not in Ready |
         Extended_Query_Active |
         Copy_Out_Active |
         Copy_Completion_Active |
         Recovery_Required
      then
         raise Program_Error with
           "cannot synchronize while Postgres session state is "
           & Item.Current_State'Image;
      end if;
      if Item.Current_State in Copy_Out_Active | Copy_Completion_Active
        and then Item.Current_Copy_Origin /= Extended_Copy
      then
         raise Program_Error with
           "simple-query COPY does not use an explicit Sync";
      end if;
      Send_Command (Item, Protocol.Make_Sync_Message, Timeout);
   end Synchronize;

   function Receive_Extended_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Extended_Query_Event is
      Response     : Protocol.Backend_Message;
      Sync_Pending : constant Boolean :=
        Item.Current_State = Awaiting_Ready;
   begin
      if Item.Current_State = Recovery_Required then
         raise Program_Error with
           "Postgres extended-query recovery requires Sync before receiving";
      end if;
      if Item.Current_State not in Extended_Query_Active | Awaiting_Ready then
         raise Program_Error with "no extended query is active";
      end if;

      Response := Protocol.Decode_Backend
        (Framing.Read_Message (Item.Channel.all, Timeout));
      case Protocol.Response_Kind (Response) is
         when Protocol.Row_Description_Response =>
            Item.Described_Columns := Protocol.Field_Count
              (Protocol.Description (Response));
            Item.Has_Row_Description := True;
         when Protocol.Data_Row_Response =>
            if not Item.Has_Row_Description then
               raise Protocol.Protocol_Error with
                 "received DataRow without a RowDescription";
            end if;
            if Protocol.Column_Count (Protocol.Row_Data (Response)) /=
              Item.Described_Columns
            then
               raise Protocol.Protocol_Error with
                 "DataRow column count does not match RowDescription";
            end if;
         when Protocol.Command_Complete_Response |
              Protocol.Empty_Query_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Portal_Is_Suspended := False;
         when Protocol.No_Data_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
         when Protocol.Portal_Suspended_Response =>
            Item.Portal_Is_Suspended := True;
         when Protocol.Error_Response =>
            if not Sync_Pending then
               Item.Current_State := Recovery_Required;
            end if;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
         when Protocol.Ready_For_Query_Response =>
            if Item.Current_State /= Awaiting_Ready then
               raise Protocol.Protocol_Error with
                 "received ReadyForQuery without a preceding Sync";
            end if;
            Item.Current_State := Ready;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
            Reset_Copy (Item);
         when Protocol.Copy_In_Response |
              Protocol.Copy_Out_Response |
              Protocol.Copy_Both_Response =>
            Enter_Copy
              (Item,
               Protocol.Response_Kind (Response),
               Origin       => Extended_Copy,
               Sync_Pending => Sync_Pending);
         when Protocol.Copy_Data_Response |
              Protocol.Copy_Done_Response =>
            raise Protocol.Protocol_Error with
              "received COPY stream data before a COPY response";
         when Protocol.Parse_Complete_Response |
              Protocol.Bind_Complete_Response |
              Protocol.Close_Complete_Response |
              Protocol.Parameter_Description_Response |
              Protocol.Notice_Response |
              Protocol.Parameter_Status_Response |
              Protocol.Unknown_Response =>
            null;
      end case;
      return Response;
   end Receive_Extended_Event;

   procedure Send_Copy_Data
     (Item    : in out Session;
      Data    : Protocol.Byte_Array;
      Timeout : Duration := 30.0) is
   begin
      Send_Command
        (Item, Protocol.Make_Copy_Data_Message (Data), Timeout);
   end Send_Copy_Data;

   procedure Finish_Copy
     (Item : in out Session; Timeout : Duration := 30.0) is
   begin
      Send_Command (Item, Protocol.Make_Copy_Done_Message, Timeout);
   end Finish_Copy;

   procedure Abort_Copy
     (Item    : in out Session;
      Reason  : String;
      Timeout : Duration := 30.0) is
   begin
      Send_Command
        (Item, Protocol.Make_Copy_Fail_Message (Reason), Timeout);
   end Abort_Copy;

   function Receive_Copy_Event
     (Item    : in out Session;
      Timeout : Duration := 30.0;
      On_Wait : access Transports.Wait_Observer'Class := null)
      return Copy_Event is
      Response : Protocol.Backend_Message;
   begin
      if Item.Current_Copy_Origin = No_Copy
        or else Item.Current_State not in
          Copy_In_Active | Copy_Out_Active | Copy_Both_Active |
          Copy_Completion_Active | Awaiting_Ready
      then
         raise Program_Error with "no Postgres COPY operation is active";
      end if;

      --  Give the observer the gap between messages as well as the gaps
      --  inside one.  A stream of small messages never waits mid-message, so
      --  the transport would otherwise never offer it a turn, and a burst of
      --  them keeps a peer's keepalive queued behind the data for as long as
      --  the burst lasts.  The observer runs before any state below is read
      --  or written, so it may send on this session's channel without racing
      --  this call.
      if On_Wait /= null then
         On_Wait.On_Wait;
      end if;
      Response := Protocol.Decode_Backend
        (Framing.Read_Message (Item.Channel.all, Timeout, On_Wait));
      case Protocol.Response_Kind (Response) is
         when Protocol.Copy_Data_Response =>
            if not Item.Copy_Receive_Open
              and then not
                (Item.Copy_Bidirectional
                 and then not Item.Copy_Send_Open
                 and then Item.Current_State = Copy_Completion_Active)
            then
               raise Protocol.Protocol_Error with
                 "received CopyData on a non-readable COPY stream";
            end if;

         when Protocol.Copy_Done_Response =>
            if not Item.Copy_Receive_Open then
               raise Protocol.Protocol_Error with
                 "received duplicate or unexpected CopyDone";
            end if;
            Item.Copy_Receive_Open := False;
            if not Item.Copy_Send_Open then
               Item.Current_State := Copy_Completion_Active;
            end if;

         when Protocol.Command_Complete_Response =>
            if Item.Copy_Send_Open or else Item.Copy_Receive_Open then
               raise Protocol.Protocol_Error with
                 "COPY completed while a stream direction remained open";
            end if;
            if Item.Current_Copy_Origin = Simple_Copy then
               Item.Current_State := Simple_Query_Active;
               Reset_Copy (Item);
            elsif Item.Copy_Sync_Pending then
               Item.Current_State := Awaiting_Ready;
            else
               Item.Current_State := Extended_Query_Active;
               Reset_Copy (Item);
            end if;

         when Protocol.Error_Response =>
            Item.Copy_Send_Open := False;
            Item.Copy_Receive_Open := False;
            if Item.Current_Copy_Origin = Simple_Copy then
               Item.Current_State := Copy_Completion_Active;
            elsif Item.Copy_Sync_Pending then
               Item.Current_State := Awaiting_Ready;
            else
               Item.Current_State := Recovery_Required;
               Reset_Copy (Item);
            end if;

         when Protocol.Ready_For_Query_Response =>
            if Item.Current_Copy_Origin = Extended_Copy
              and then not Item.Copy_Sync_Pending
            then
               raise Protocol.Protocol_Error with
                 "received ReadyForQuery before extended COPY Sync";
            end if;
            Item.Current_State := Ready;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
            Reset_Copy (Item);

         when Protocol.Copy_Out_Response =>
            if Item.Current_Copy_Origin /= Simple_Copy
              or else Item.Current_State /= Copy_Completion_Active
              or else Item.Copy_Send_Open
              or else Item.Copy_Receive_Open
            then
               raise Protocol.Protocol_Error with
                 "unexpected CopyOutResponse during COPY";
            end if;
            --  PostgreSQL 14 BASE_BACKUP returns one COPY OUT result per
            --  tablespace (and optionally one for the manifest), with no
            --  CommandComplete between those results.
            Enter_Copy
              (Item, Protocol.Copy_Out_Response, Origin => Simple_Copy);

         when Protocol.Row_Description_Response =>
            if Item.Current_Copy_Origin /= Simple_Copy
              or else Item.Current_State /= Copy_Completion_Active
              or else Item.Copy_Send_Open
              or else Item.Copy_Receive_Open
            then
               raise Protocol.Protocol_Error with
                 "unexpected RowDescription during COPY";
            end if;
            --  BASE_BACKUP follows its final COPY result directly with the
            --  stop-LSN result set.  Preserve this already-read response for
            --  the copy-event consumer while restoring simple-query state.
            Item.Current_State := Simple_Query_Active;
            Item.Described_Columns := Protocol.Field_Count
              (Protocol.Description (Response));
            Item.Has_Row_Description := True;
            Reset_Copy (Item);

         when Protocol.Notice_Response |
              Protocol.Parameter_Status_Response =>
            null;

         when Protocol.Copy_In_Response |
              Protocol.Copy_Both_Response |
              Protocol.Data_Row_Response |
              Protocol.Empty_Query_Response |
              Protocol.Parse_Complete_Response |
              Protocol.Bind_Complete_Response |
              Protocol.Close_Complete_Response |
              Protocol.Parameter_Description_Response |
              Protocol.No_Data_Response |
              Protocol.Portal_Suspended_Response |
              Protocol.Unknown_Response =>
            raise Protocol.Protocol_Error with
              "unexpected backend message during COPY";
      end case;
      return Response;
   end Receive_Copy_Event;

   function Is_Ready (Item : Session) return Boolean is
     (Item.Current_State = Ready);

   function State (Item : Session) return Operation_State is
     (Item.Current_State);

   function Backend_Process_Id (Item : Session) return Protocol.UInt32 is
     (Item.Pid);

   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));

end Flyology.Postgres.Client;
