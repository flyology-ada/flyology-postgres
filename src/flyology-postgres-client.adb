with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Postgres.Framing;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with System;

package body Flyology.Postgres.Client is

   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;
   use type System.Address;

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

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0) is
      type SASL_Phase is
        (No_SASL, Awaiting_Continue, Awaiting_Final, Final_Verified);
      Phase : SASL_Phase := No_SASL;
      Nonce : Unbounded_String;
      Bare_Client_First : Unbounded_String;
      Expected_Server_Signature : Flyology.Postgres.SCRAM.Digest :=
        (others => 0);
      Authentication_Ok : Boolean := False;
   begin
      if Item.Started then
         raise Program_Error with "Postgres session is already started";
      end if;

      Framing.Write_Packet
        (Item.Channel.all,
         Protocol.Encode_Startup
           (User             => User,
            Database         => Database,
            Application_Name => Application_Name,
            Protocol_Minor   => 2),
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
                  Item.Started := True;
                  Item.Ready := True;
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
   end Startup;

   procedure Send_Command
     (Item    : in out Session;
      Command : Protocol.Message;
      Timeout : Duration := 30.0) is
   begin
      if not Item.Started then
         raise Program_Error with "Postgres session is not started";
      end if;
      Framing.Write_Message (Item.Channel.all, Command, Timeout);
      Item.Ready := False;
      if Protocol.Kind (Command) = Protocol.Query then
         Item.Query_Active := True;
         Item.Has_Row_Description := False;
         Item.Described_Columns := 0;
      end if;
      if Protocol.Kind (Command) = Protocol.Terminate_Command then
         Item.Started := False;
         Item.Query_Active := False;
      end if;
   end Send_Command;

   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if not Item.Ready then
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
      if not Item.Started or else Secret'Length not in 4 .. 256 then
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
      if Protocol.Code (Response) = 'Z' then
         Item.Ready := True;
         Item.Query_Active := False;
         Item.Has_Row_Description := False;
         Item.Described_Columns := 0;
      end if;
      return Response;
   end Receive_Message;

   function Receive_Query_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Simple_Query_Event is
      Response : Protocol.Backend_Message;
   begin
      if not Item.Query_Active then
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
            Item.Ready := True;
            Item.Query_Active := False;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;

         when Protocol.Notice_Response |
              Protocol.Parameter_Status_Response |
              Protocol.Unknown_Response =>
            null;
      end case;
      return Response;
   end Receive_Query_Event;

   function Is_Ready (Item : Session) return Boolean is (Item.Ready);

   function Backend_Process_Id (Item : Session) return Protocol.UInt32 is
     (Item.Pid);

   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));

end Flyology.Postgres.Client;
