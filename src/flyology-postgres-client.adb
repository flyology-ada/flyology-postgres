with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Flyology.IO;
with Flyology.Operations.Drivers;
with Flyology.Postgres.Framing;
with Flyology.Postgres.SCRAM_Core;
with Flyology.Postgres.Wire;
with System;

package body Flyology.Postgres.Client is

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;
   use type System.Address;
   use type Protocol.Backend_Message_Kind;
   use type Transports.Acquisition_Result;

   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Protocol.Byte_Array,
      Name   => Byte_Array_Access);

   overriding procedure Finalize (Item : in out Buffer_Owner) is
   begin
      Free (Item.Value);
   end Finalize;

   procedure Clear (Item : in out Buffer_Owner) is
   begin
      Free (Item.Value);
   end Clear;

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

   procedure Require_No_Pipelined_Copy (Item : in out Session) is
      --  COPY takes the connection over until it completes, and its own
      --  state machine tracks a single Sync. Neither fact survives several
      --  outstanding batches, so pipeline mode refuses to start COPY.
      --  The response is already consumed and the server is already
      --  streaming, so the connection cannot be resynchronized. Close the
      --  session state rather than let a caller that traps the error keep
      --  reading into a cascade of unexplained COPY frames.
   begin
      if Item.Pipelined then
         Item.Current_State := Closed;
         Item.Pipelined := False;
         Item.Pending_Syncs := 0;
         Item.Batch_Open := False;
         Item.Has_Row_Description := False;
         Item.Described_Columns := 0;
         Item.Bound_In_Cycle := False;
         Item.Portal_Is_Suspended := False;
         Reset_Copy (Item);
         raise Protocol.Protocol_Error with
           "COPY cannot start in Postgres pipeline mode; the session is "
           & "closed and its transport must be discarded";
      end if;
   end Require_No_Pipelined_Copy;

   function Has_Pending_Synchronization (Item : Session) return Boolean is
     (Item.Pending_Syncs > 0);

   procedure Complete_Synchronization
     (Item : in out Session; Strict : Boolean) is
      --  Retire the oldest outstanding Sync when its ReadyForQuery arrives.
      --  In pipeline mode a later batch can already be open, and that batch
      --  owns the local ordering state, so only a session with no open batch
      --  returns to Ready or waits for the next outstanding batch.
      --  @param Item Session whose oldest outstanding batch is complete.
      --  @param Strict Reject a ReadyForQuery that no Sync asked for. The
      --     raw receive path stays lenient and treats one as an idle reset.
   begin
      if Item.Pending_Syncs = 0 then
         if Strict then
            raise Protocol.Protocol_Error with
              "received ReadyForQuery without a preceding Sync";
         end if;
         Item.Batch_Open := False;
      else
         Item.Pending_Syncs := Item.Pending_Syncs - 1;
      end if;
      Item.Has_Row_Description := False;
      Item.Described_Columns := 0;
      Reset_Copy (Item);
      if not Item.Batch_Open then
         Item.Bound_In_Cycle := False;
         Item.Portal_Is_Suspended := False;
         Item.Current_State :=
           (if Item.Pending_Syncs > 0 then Awaiting_Ready else Ready);
      end if;
   end Complete_Synchronization;

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
      if Item.Current_State not in Not_Started | TLS_Negotiated then
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
      Tag : constant Protocol.Frontend_Kind := Protocol.Kind (Command);
   begin
      if Item.Current_State in Not_Started | TLS_Negotiated | Closed then
         raise Program_Error with "Postgres session is not started";
      end if;
      if Item.Pipelined and then Tag = Protocol.Query then
         raise Program_Error with
           "simple queries are not allowed in Postgres pipeline mode";
      end if;
      if Item.Current_State = Recovery_Required
        and then Tag /= Protocol.Sync
        and then Tag /= Protocol.Terminate_Command
      then
         raise Program_Error with
           "Postgres extended-query recovery requires Sync";
      end if;
      if Item.Current_State = Awaiting_Ready
        and then Tag /= Protocol.Terminate_Command
        and then not (Item.Pipelined
                      and then Tag in
                        Protocol.Parse | Protocol.Bind | Protocol.Describe |
                        Protocol.Execute | Protocol.Close | Protocol.Flush |
                        Protocol.Sync)
      then
         raise Program_Error with
           "Postgres session is awaiting ReadyForQuery";
      end if;
      if Tag in Protocol.Copy_Data |
         Protocol.Copy_Done | Protocol.Copy_Fail
        and then (Item.Current_State not in
                    Copy_In_Active | Copy_Both_Active
                  or else not Item.Copy_Send_Open)
      then
         raise Program_Error with "no writable Postgres COPY stream is active";
      end if;
      Framing.Write_Message (Item.Channel.all, Command, Timeout);
      case Tag is
         when Protocol.Query =>
            Item.Current_State := Simple_Query_Active;
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
         when Protocol.Parse |
              Protocol.Bind |
              Protocol.Describe |
              Protocol.Execute |
              Protocol.Close =>
            --  A batch-opening command written after Sync starts the next
            --  pipelined batch, so its local ordering state starts empty.
            if not Item.Batch_Open then
               Item.Batch_Open := True;
               Item.Bound_In_Cycle := False;
               Item.Portal_Is_Suspended := False;
            end if;
            if Item.Current_State in Ready | Awaiting_Ready then
               Item.Current_State := Extended_Query_Active;
            end if;
         when Protocol.Flush =>
            --  Flush only forces pending output; it opens no batch.
            if Item.Current_State = Ready then
               Item.Current_State := Extended_Query_Active;
            end if;
         when Protocol.Sync =>
            Item.Pending_Syncs := Item.Pending_Syncs + 1;
            Item.Current_State := Awaiting_Ready;
            Item.Batch_Open := False;
            Item.Bound_In_Cycle := False;
            Item.Portal_Is_Suspended := False;
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
            Item.Batch_Open := False;
            Item.Pipelined := False;
            Item.Pending_Syncs := 0;
            Reset_Copy (Item);
         when others =>
            null;
      end case;
   end Send_Command;

   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Item.Pipelined then
         raise Program_Error with
           "simple queries are not allowed in Postgres pipeline mode";
      end if;
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
      if Item.Current_State in Not_Started | TLS_Negotiated | Closed
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
                  Require_No_Pipelined_Copy (Item);
                  Enter_Copy
                    (Item,
                     Protocol.Response_Kind (Decoded),
                     Origin       => Extended_Copy,
                     Sync_Pending => Item.Pending_Syncs > 0);
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
            elsif Item.Current_State = Extended_Query_Active
              and then Item.Pending_Syncs = 0
            then
               Item.Current_State := Recovery_Required;
            end if;
         when 'Z' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            Complete_Synchronization (Item, Strict => False);
         when others =>
            null;
      end case;
      return Response;
   end Receive_Message;

   procedure Apply_Query_Event
     (Item     : in out Session;
      Response : Simple_Query_Event) is
   begin
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
            --  Unlike the extended path, a simple query always describes its
            --  result before its rows, so a missing description here is a
            --  protocol violation rather than a skipped Describe.
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
   end Apply_Query_Event;

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
      Apply_Query_Event (Item, Response);
      return Response;
   end Receive_Query_Event;

   procedure Require_Extended_Send (Item : Session; Operation : String) is
   begin
      if Item.Current_State in Ready | Extended_Query_Active then
         return;
      end if;
      --  In pipeline mode a session that has written Sync opens the next
      --  batch instead of waiting for the outstanding ReadyForQuery.
      if Item.Pipelined and then Item.Current_State = Awaiting_Ready then
         return;
      end if;
      raise Program_Error with
        "cannot " & Operation & " while Postgres session state is "
        & Item.Current_State'Image;
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
        and then not (Item.Pipelined
                      and then Item.Current_State = Awaiting_Ready)
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

   procedure Apply_Extended_Event
     (Item         : in out Session;
      Response     : Extended_Query_Event;
      Sync_Pending : Boolean) is
   begin
      case Protocol.Response_Kind (Response) is
         when Protocol.Row_Description_Response =>
            Item.Described_Columns := Protocol.Field_Count
              (Protocol.Description (Response));
            Item.Has_Row_Description := True;
         when Protocol.Data_Row_Response =>
            --  The backend sends RowDescription only in reply to Describe,
            --  so a portal that was executed without one legitimately
            --  returns bare rows. Check the column count against a
            --  description that actually arrived, and take the rest on
            --  trust, because nothing else describes their shape.
            if Item.Has_Row_Description
              and then Protocol.Column_Count (Protocol.Row_Data (Response)) /=
                Item.Described_Columns
            then
               raise Protocol.Protocol_Error with
                 "DataRow column count does not match RowDescription";
            end if;
         when Protocol.Command_Complete_Response |
              Protocol.Empty_Query_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            --  An outstanding Sync means this response belongs to an earlier
            --  batch than the one being written, whose portal state it must
            --  not disturb.
            if not Sync_Pending then
               Item.Portal_Is_Suspended := False;
            end if;
         when Protocol.No_Data_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
         when Protocol.Portal_Suspended_Response =>
            if not Sync_Pending then
               Item.Portal_Is_Suspended := True;
            end if;
         when Protocol.Error_Response =>
            Item.Has_Row_Description := False;
            Item.Described_Columns := 0;
            --  An outstanding Sync already ends the failed batch, and the
            --  server skips to it. Only an unsynchronized failure leaves the
            --  open batch in need of recovery.
            if not Sync_Pending then
               Item.Current_State := Recovery_Required;
               Item.Bound_In_Cycle := False;
               Item.Portal_Is_Suspended := False;
            end if;
         when Protocol.Ready_For_Query_Response =>
            Complete_Synchronization (Item, Strict => True);
         when Protocol.Copy_In_Response |
              Protocol.Copy_Out_Response |
              Protocol.Copy_Both_Response =>
            Require_No_Pipelined_Copy (Item);
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
   end Apply_Extended_Event;

   function Operation_Channel
     (Item : not null Session_Access)
      return access Transports.Operation_Transport'Class is
   begin
      if Item.Channel.all not in Transports.Operation_Transport'Class then
         raise Program_Error with
           "Postgres transport does not support scoped operations";
      end if;
      return Transports.Operation_Transport'Class
        (Item.Channel.all)'Unchecked_Access;
   end Operation_Channel;

   procedure Release_Transport (Item : in out Send_Operation) is
   begin
      if Item.Phase /= Transfer_Idle then
         Operation_Channel (Item.Item).Release_Operation;
         Item.Phase := Transfer_Idle;
      end if;
   end Release_Transport;

   procedure Release_Transport (Item : in out Receive_Operation) is
   begin
      if Item.Phase /= Transfer_Idle then
         Operation_Channel (Item.Item).Release_Operation;
         Item.Phase := Transfer_Idle;
      end if;
   end Release_Transport;

   procedure Fail_Send
     (Item  : in out Send_Operation;
      Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      begin
         Release_Transport (Item);
      exception
         when Cleanup_Error : others =>
            Ada.Exceptions.Save_Occurrence (Item.Failure, Cleanup_Error);
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
            return;
      end;
      Ada.Exceptions.Save_Occurrence (Item.Failure, Error);
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Failed);
   end Fail_Send;

   procedure Fail_Receive
     (Item  : in out Receive_Operation;
      Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      begin
         Release_Transport (Item);
      exception
         when Cleanup_Error : others =>
            Ada.Exceptions.Save_Occurrence (Item.Failure, Cleanup_Error);
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
            return;
      end;
      Ada.Exceptions.Save_Occurrence (Item.Failure, Error);
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Failed);
   end Fail_Receive;

   procedure Complete_Send (Item : in out Send_Operation) is
   begin
      Release_Transport (Item);
      case Item.Kind is
         when Simple_Query_Send =>
            Item.Item.Current_State := Simple_Query_Active;
            Item.Item.Has_Row_Description := False;
            Item.Item.Described_Columns := 0;
         when Portal_Execute_Send =>
            null;
      end case;
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Succeeded);
   end Complete_Send;

   procedure Drive_Send_Step (Item : in out Send_Operation) is
      Last   : Ada.Streams.Stream_Element_Offset;
      Result : Transports.Step_Result;
   begin
      Operation_Channel (Item.Item).Send_Step
        (Item.Buffer.Value.all (Item.Cursor .. Item.Buffer.Value.all'Last),
         Last,
         Result);
      case Result is
         when Transports.Made_Progress =>
            Item.Cursor := Last + 1;
            if Item.Cursor > Item.Buffer.Value.all'Last then
               Complete_Send (Item);
            else
               Flyology.Operations.Drivers.Reschedule (Item);
            end if;
         when Transports.Need_Read | Transports.Need_Write =>
            Operation_Channel (Item.Item).Arm_Transport
              (Item, Result);
         when Transports.Peer_Closed =>
            raise Flyology.IO.Device_Error with
              "Postgres peer closed before the message was sent";
      end case;
   end Drive_Send_Step;

   overriding procedure Drive
     (Item  : in out Send_Operation;
      Event : Flyology.Operations.Driver_Event) is
      Acquisition : Transports.Acquisition_Result;
   begin
      begin
         case Event is
            when Flyology.Operations.Start_Operation =>
               Item.Phase := Acquiring_Transport;
               Operation_Channel (Item.Item).Start_Operation
                 (Item, Acquisition, Item.Timeout);
               if Acquisition = Transports.Acquired then
                  Item.Phase := Transferring_Data;
                  Drive_Send_Step (Item);
               else
                  Operation_Channel (Item.Item).Arm_Acquisition (Item);
               end if;
            when Flyology.Operations.Source_Ready =>
               if Item.Phase = Acquiring_Transport then
                  Operation_Channel (Item.Item).Poll_Acquisition
                    (Acquisition);
                  if Acquisition = Transports.Acquired then
                     Item.Phase := Transferring_Data;
                     Drive_Send_Step (Item);
                  else
                     Operation_Channel (Item.Item).Arm_Acquisition (Item);
                  end if;
               elsif Item.Phase = Transferring_Data then
                  Drive_Send_Step (Item);
               else
                  raise Program_Error with
                    "Postgres send operation has no ready source";
               end if;
            when Flyology.Operations.Continue_Operation =>
               if Item.Phase /= Transferring_Data then
                  raise Program_Error with
                    "Postgres send operation cannot continue";
               end if;
               Drive_Send_Step (Item);
            when Flyology.Operations.Deadline_Reached =>
               raise Flyology.IO.Timeout_Error with
                 "Postgres send operation deadline expired";
            when Flyology.Operations.Dependency_Changed =>
               raise Program_Error with
                 "Postgres send operation has no dependency";
         end case;
      exception
         when Error : others =>
            Fail_Send (Item, Error);
      end;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Send_Operation) is
   begin
      begin
         if Item.Phase /= Transfer_Idle then
            Operation_Channel (Item.Item).Cancel_Operation;
            Item.Phase := Transfer_Idle;
         end if;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Cancelled);
      exception
         when Error : others =>
            Fail_Send (Item, Error);
      end;
   end Request_Cancellation;

   procedure Start_Send
     (Item      : not null access Session;
      Command   : Protocol.Message;
      Kind      : Send_Kind;
      Timeout   : Duration;
      Operation : in out Send_Operation) is
   begin
      Operation.Item := Item.all'Unchecked_Access;
      declare
         Ignored : constant access Transports.Operation_Transport'Class :=
           Operation_Channel (Operation.Item);
      begin
         null;
      end;
      Clear (Operation.Buffer);
      Operation.Buffer.Value :=
        new Protocol.Byte_Array'(Protocol.Encode (Command));
      Operation.Cursor := Operation.Buffer.Value.all'First;
      Operation.Kind := Kind;
      Operation.Phase := Transfer_Idle;
      Operation.Timeout := Timeout;
      Flyology.Operations.Drivers.Start (Operation);
      Operation.Drive (Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            if Operation.Phase /= Transfer_Idle then
               begin
                  Release_Transport (Operation);
               exception
                  when others =>
                     null;
               end;
            end if;
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Send;

   function Send_Query
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Session;
      SQL     : String;
      Timeout : Duration := 30.0) return Send_Operation is
   begin
      return Result : Send_Operation (Set) do
         Send_Query (Item, SQL, Timeout, Result);
      end return;
   end Send_Query;

   procedure Send_Query
     (Item      : not null access Session;
      SQL       : String;
      Timeout   : Duration := 30.0;
      Operation : in out Send_Operation) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Item.Current_State /= Ready then
         raise Program_Error with "Postgres session is not ready for a query";
      elsif SQL'Length > Protocol.Maximum_Message_Size - 5 then
         raise Protocol.Protocol_Error with
           "Query message exceeds the configured limit";
      end if;
      Protocol.Append_C_String (Contents, SQL);
      Start_Send
        (Item,
         Protocol.Make_Message ('Q', Flyology.Bytes.To_Array (Contents)),
         Simple_Query_Send,
         Timeout,
         Operation);
   end Send_Query;

   function Execute_Portal
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0) return Send_Operation is
   begin
      return Result : Send_Operation (Set) do
         Execute_Portal
           (Item, Portal_Name, Maximum_Rows, Timeout, Result);
      end return;
   end Execute_Portal;

   procedure Execute_Portal
     (Item         : not null access Session;
      Portal_Name  : String;
      Maximum_Rows : Protocol.Row_Limit := 0;
      Timeout      : Duration := 30.0;
      Operation    : in out Send_Operation) is
   begin
      Require_Extended_Send (Item.all, "execute a portal");
      if not Item.Bound_In_Cycle then
         raise Program_Error with
           "cannot execute a portal before binding it in this query cycle";
      elsif Item.Portal_Is_Suspended then
         raise Program_Error with
           "use Resume_Portal for a suspended portal";
      end if;
      Start_Send
        (Item,
         Protocol.Make_Execute_Message (Portal_Name, Maximum_Rows),
         Portal_Execute_Send,
         Timeout,
         Operation);
   end Execute_Portal;

   procedure Finish (Operation : in out Send_Operation) is
      Terminal : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      Flyology.Operations.Consume (Operation);
      Clear (Operation.Buffer);
      case Terminal is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            Ada.Exceptions.Reraise_Occurrence (Operation.Failure);
      end case;
   end Finish;

   procedure Complete_Receive (Item : in out Receive_Operation) is
      Raw : constant Protocol.Message :=
        Protocol.Make_Message
          (Character'Val (Item.Tag (Item.Tag'First)),
           Item.Buffer.Value.all);
   begin
      Item.Result := Protocol.Decode_Backend (Raw);
      case Item.Kind is
         when Simple_Query_Receive =>
            Apply_Query_Event (Item.Item.all, Item.Result);
         when Extended_Query_Receive =>
            Apply_Extended_Event
              (Item.Item.all, Item.Result, Item.Sync_Pending);
      end case;
      Release_Transport (Item);
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Succeeded);
   end Complete_Receive;

   procedure Advance_Receive (Item : in out Receive_Operation) is
      Last   : Ada.Streams.Stream_Element_Offset;
      Result : Transports.Step_Result;
   begin
      case Item.Phase is
         when Reading_Tag =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Tag (Item.Cursor .. Item.Tag'Last), Last, Result);
         when Reading_Length =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Length_Data (Item.Cursor .. Item.Length_Data'Last),
               Last,
               Result);
         when Reading_Body =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Buffer.Value.all
                 (Item.Cursor .. Item.Buffer.Value.all'Last),
               Last,
               Result);
         when others =>
            raise Program_Error with
              "Postgres receive operation is not reading";
      end case;

      case Result is
         when Transports.Made_Progress =>
            Item.Cursor := Last + 1;
            case Item.Phase is
               when Reading_Tag =>
                  if Item.Cursor > Item.Tag'Last then
                     Item.Phase := Reading_Length;
                     Item.Cursor := Item.Length_Data'First;
                  end if;
                  Flyology.Operations.Drivers.Reschedule (Item);
               when Reading_Length =>
                  if Item.Cursor > Item.Length_Data'Last then
                     declare
                        Cursor : Protocol.Byte_Offset :=
                          Item.Length_Data'First;
                        Length : constant Protocol.UInt32 :=
                          Protocol.Read_U32 (Item.Length_Data, Cursor);
                     begin
                        if not Flyology.Postgres.Wire.Valid_Typed_Length
                          (Length)
                        then
                           raise Protocol.Protocol_Error with
                             "invalid typed Postgres message length";
                        end if;
                        Clear (Item.Buffer);
                        Item.Buffer.Value := new Protocol.Byte_Array
                          (1 .. Protocol.Byte_Offset
                             (Flyology.Postgres.Wire.Content_Length
                                (Length)));
                        Item.Phase := Reading_Body;
                        Item.Cursor := Item.Buffer.Value.all'First;
                        if Item.Buffer.Value.all'Length = 0 then
                           Complete_Receive (Item);
                        else
                           Flyology.Operations.Drivers.Reschedule (Item);
                        end if;
                     end;
                  else
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
               when Reading_Body =>
                  if Item.Cursor > Item.Buffer.Value.all'Last then
                     Complete_Receive (Item);
                  else
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
               when others =>
                  null;
            end case;
         when Transports.Need_Read | Transports.Need_Write =>
            Operation_Channel (Item.Item).Arm_Transport (Item, Result);
         when Transports.Peer_Closed =>
            raise Flyology.IO.Device_Error with
              "Postgres peer closed before the message was complete";
      end case;
   end Advance_Receive;

   overriding procedure Drive
     (Item  : in out Receive_Operation;
      Event : Flyology.Operations.Driver_Event) is
      Acquisition : Transports.Acquisition_Result;
   begin
      begin
         case Event is
            when Flyology.Operations.Start_Operation =>
               Item.Phase := Acquiring_Transport;
               Operation_Channel (Item.Item).Start_Operation
                 (Item, Acquisition, Item.Timeout);
               if Acquisition = Transports.Acquired then
                  Item.Phase := Reading_Tag;
                  Item.Cursor := Item.Tag'First;
                  Advance_Receive (Item);
               else
                  Operation_Channel (Item.Item).Arm_Acquisition (Item);
               end if;
            when Flyology.Operations.Source_Ready =>
               if Item.Phase = Acquiring_Transport then
                  Operation_Channel (Item.Item).Poll_Acquisition
                    (Acquisition);
                  if Acquisition = Transports.Acquired then
                     Item.Phase := Reading_Tag;
                     Item.Cursor := Item.Tag'First;
                     Advance_Receive (Item);
                  else
                     Operation_Channel (Item.Item).Arm_Acquisition (Item);
                  end if;
               else
                  Advance_Receive (Item);
               end if;
            when Flyology.Operations.Continue_Operation =>
               Advance_Receive (Item);
            when Flyology.Operations.Deadline_Reached =>
               raise Flyology.IO.Timeout_Error with
                 "Postgres receive operation deadline expired";
            when Flyology.Operations.Dependency_Changed =>
               raise Program_Error with
                 "Postgres receive operation has no dependency";
         end case;
      exception
         when Error : others =>
            Fail_Receive (Item, Error);
      end;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Receive_Operation) is
   begin
      begin
         if Item.Phase /= Transfer_Idle then
            Operation_Channel (Item.Item).Cancel_Operation;
            Item.Phase := Transfer_Idle;
         end if;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Cancelled);
      exception
         when Error : others =>
            Fail_Receive (Item, Error);
      end;
   end Request_Cancellation;

   procedure Start_Receive
     (Item      : not null access Session;
      Kind      : Receive_Kind;
      Timeout   : Duration;
      Operation : in out Receive_Operation) is
   begin
      Operation.Item := Item.all'Unchecked_Access;
      declare
         Ignored : constant access Transports.Operation_Transport'Class :=
           Operation_Channel (Operation.Item);
      begin
         null;
      end;
      case Kind is
         when Simple_Query_Receive =>
            if Item.Current_State /= Simple_Query_Active then
               raise Program_Error with "no simple query is active";
            end if;
         when Extended_Query_Receive =>
            if Item.Current_State = Recovery_Required then
               raise Program_Error with
                 "Postgres extended-query recovery requires Sync before"
                 & " receiving";
            elsif Item.Current_State not in
              Extended_Query_Active | Awaiting_Ready
            then
               raise Program_Error with "no extended query is active";
            end if;
      end case;
      Clear (Operation.Buffer);
      Operation.Kind := Kind;
      Operation.Sync_Pending := Has_Pending_Synchronization (Item.all);
      Operation.Phase := Transfer_Idle;
      Operation.Timeout := Timeout;
      Flyology.Operations.Drivers.Start (Operation);
      Operation.Drive (Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            if Operation.Phase /= Transfer_Idle then
               begin
                  Release_Transport (Operation);
               exception
                  when others =>
                     null;
               end;
            end if;
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Receive;

   function Receive_Query_Event
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Session;
      Timeout : Duration := 30.0) return Receive_Operation is
   begin
      return Result : Receive_Operation (Set) do
         Receive_Query_Event (Item, Timeout, Result);
      end return;
   end Receive_Query_Event;

   procedure Receive_Query_Event
     (Item      : not null access Session;
      Timeout   : Duration := 30.0;
      Operation : in out Receive_Operation) is
   begin
      Start_Receive
        (Item, Simple_Query_Receive, Timeout, Operation);
   end Receive_Query_Event;

   function Receive_Extended_Event
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Session;
      Timeout : Duration := 30.0) return Receive_Operation is
   begin
      return Result : Receive_Operation (Set) do
         Receive_Extended_Event (Item, Timeout, Result);
      end return;
   end Receive_Extended_Event;

   procedure Receive_Extended_Event
     (Item      : not null access Session;
      Timeout   : Duration := 30.0;
      Operation : in out Receive_Operation) is
   begin
      Start_Receive
        (Item, Extended_Query_Receive, Timeout, Operation);
   end Receive_Extended_Event;

   procedure Finish
     (Operation : in out Receive_Operation;
      Event     : out Protocol.Backend_Message) is
      Terminal : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      case Terminal is
         when Flyology.Operations.Succeeded =>
            Event := Operation.Result;
            Flyology.Operations.Consume (Operation);
            Clear (Operation.Buffer);
         when Flyology.Operations.Cancelled =>
            Flyology.Operations.Consume (Operation);
            Clear (Operation.Buffer);
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            Flyology.Operations.Consume (Operation);
            Clear (Operation.Buffer);
            Ada.Exceptions.Reraise_Occurrence (Operation.Failure);
      end case;
   end Finish;

   procedure Release_Transport (Item : in out Startup_Operation) is
   begin
      if Item.Phase /= Transfer_Idle then
         Operation_Channel (Item.Item).Release_Operation;
         Item.Phase := Transfer_Idle;
      end if;
   end Release_Transport;

   procedure Wipe_Startup (Item : in out Startup_Operation) is
   begin
      Flyology.Postgres.SCRAM_Core.Wipe
        (Item.Expected_Server_Signature);
      for Index in 1 .. Length (Item.Password) loop
         Replace_Element
           (Item.Password, Index, Character'Val (0));
      end loop;
      Item.Password := Null_Unbounded_String;
      for Index in 1 .. Length (Item.Nonce) loop
         Replace_Element
           (Item.Nonce, Index, Character'Val (0));
      end loop;
      Item.Nonce := Null_Unbounded_String;
      for Index in 1 .. Length (Item.Bare_First) loop
         Replace_Element
           (Item.Bare_First, Index, Character'Val (0));
      end loop;
      Item.Bare_First := Null_Unbounded_String;
   end Wipe_Startup;

   procedure Fail_Startup
     (Item  : in out Startup_Operation;
      Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      begin
         Release_Transport (Item);
      exception
         when Cleanup_Error : others =>
            Ada.Exceptions.Save_Occurrence (Item.Failure, Cleanup_Error);
            Wipe_Startup (Item);
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
            return;
      end;
      if Item.Kind = TLS_Negotiation_Stage then
         Item.Item.Current_State := Closed;
      end if;
      Ada.Exceptions.Save_Occurrence (Item.Failure, Error);
      Wipe_Startup (Item);
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Failed);
   end Fail_Startup;

   procedure Prepare_Startup_Send
     (Item : in out Startup_Operation;
      Data : Protocol.Byte_Array) is
   begin
      Clear (Item.Buffer);
      Item.Buffer.Value := new Protocol.Byte_Array'(Data);
      Item.Cursor := Item.Buffer.Value.all'First;
      Item.Phase := Transferring_Data;
   end Prepare_Startup_Send;

   procedure Read_Next_Startup_Message
     (Item : in out Startup_Operation) is
   begin
      Clear (Item.Buffer);
      Item.Cursor := Item.Tag'First;
      Item.Phase := Reading_Tag;
      Flyology.Operations.Drivers.Reschedule (Item);
   end Read_Next_Startup_Message;

   procedure Complete_Startup_Operation
     (Item : in out Startup_Operation) is
   begin
      Release_Transport (Item);
      Wipe_Startup (Item);
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Succeeded);
   end Complete_Startup_Operation;

   procedure Process_Startup_Message
     (Item : in out Startup_Operation) is
      Response : constant Protocol.Message :=
        Protocol.Make_Message
          (Character'Val (Item.Tag (Item.Tag'First)),
           Item.Buffer.Value.all);
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Response);
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
                     if Item.SASL_Phase in
                       Awaiting_Continue | Awaiting_Final
                     then
                        raise Protocol.Protocol_Error with
                          "AuthenticationOk arrived before SCRAM completed";
                     end if;
                     Item.Authentication_Ok := True;
                     Read_Next_Startup_Message (Item);
                  when 3 =>
                     if Item.SASL_Phase /= No_SASL then
                        raise Protocol.Protocol_Error with
                          "unexpected cleartext authentication request";
                     end if;
                     declare
                        Payload : Flyology.Bytes.Unbounded_Bytes;
                     begin
                        Protocol.Append_C_String
                          (Payload, To_String (Item.Password));
                        Prepare_Startup_Send
                          (Item,
                           Protocol.Encode
                             (Protocol.Make_Message
                                ('p', Flyology.Bytes.To_Array (Payload))));
                        Flyology.Operations.Drivers.Reschedule (Item);
                     end;
                  when 10 =>
                     if Item.SASL_Phase /= No_SASL then
                        raise Protocol.Protocol_Error with
                          "duplicate SASL authentication request";
                     end if;
                     declare
                        Offered    : Boolean := False;
                        Terminated : Boolean := False;
                        Position   : Protocol.Byte_Offset := Cursor;
                     begin
                        while Position <= Contents'Last loop
                           declare
                              Name : constant String :=
                                Protocol.Read_C_String
                                  (Contents, Position);
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
                          or else Position <= Contents'Last
                        then
                           raise Protocol.Protocol_Error with
                             "malformed AuthenticationSASL mechanism list";
                        elsif not Offered then
                           raise Unsupported_Authentication with
                             "server did not offer SCRAM-SHA-256";
                        end if;
                     end;
                     Item.Nonce := To_Unbounded_String
                       (Flyology.Postgres.SCRAM.Random_Nonce);
                     Item.Bare_First := To_Unbounded_String
                       (Flyology.Postgres.SCRAM.Client_First_Bare
                          (To_String (Item.User), To_String (Item.Nonce)));
                     declare
                        Initial : constant String :=
                          Flyology.Postgres.SCRAM.Client_First_Message
                            (To_String (Item.User), To_String (Item.Nonce));
                        Payload : Flyology.Bytes.Unbounded_Bytes;
                     begin
                        Protocol.Append_C_String
                          (Payload, Flyology.Postgres.SCRAM.Mechanism);
                        Protocol.Append_U32
                          (Payload, Protocol.UInt32 (Initial'Length));
                        Flyology.Bytes.Append_Byte_String (Payload, Initial);
                        Prepare_Startup_Send
                          (Item,
                           Protocol.Encode
                             (Protocol.Make_Message
                                ('p', Flyology.Bytes.To_Array (Payload))));
                     end;
                     Item.SASL_Phase := Awaiting_Continue;
                     Flyology.Operations.Drivers.Reschedule (Item);
                  when 11 =>
                     if Item.SASL_Phase /= Awaiting_Continue then
                        raise Protocol.Protocol_Error with
                          "unexpected AuthenticationSASLContinue";
                     end if;
                     declare
                        Server_First : constant String :=
                          Payload_Text (Contents, Cursor);
                        Client_Final : constant String :=
                          Flyology.Postgres.SCRAM.Client_Final_Message
                            (To_String (Item.Password),
                             To_String (Item.Bare_First),
                             Server_First,
                             To_String (Item.Nonce),
                             Item.Expected_Server_Signature);
                        Payload : Flyology.Bytes.Unbounded_Bytes;
                     begin
                        Flyology.Bytes.Append_Byte_String
                          (Payload, Client_Final);
                        Prepare_Startup_Send
                          (Item,
                           Protocol.Encode
                             (Protocol.Make_Message
                                ('p', Flyology.Bytes.To_Array (Payload))));
                     end;
                     Item.SASL_Phase := Awaiting_Final;
                     Flyology.Operations.Drivers.Reschedule (Item);
                  when 12 =>
                     if Item.SASL_Phase /= Awaiting_Final then
                        raise Protocol.Protocol_Error with
                          "unexpected AuthenticationSASLFinal";
                     end if;
                     Flyology.Postgres.SCRAM.Verify_Server_Final
                       (Payload_Text (Contents, Cursor),
                        Item.Expected_Server_Signature);
                     Wipe_Startup (Item);
                     Item.SASL_Phase := Final_Verified;
                     Read_Next_Startup_Message (Item);
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
               Item.Item.Pid := Protocol.Read_U32 (Contents, Cursor);
               Item.Item.Secret := Flyology.Bytes.To_Unbounded_Bytes
                 (Contents (Cursor .. Contents'Last));
            end;
            Read_Next_Startup_Message (Item);
         when 'E' =>
            raise Database_Error with
              SQL_State (Response) & ": " & Error_Message (Response);
         when 'N' | 'S' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            Read_Next_Startup_Message (Item);
         when 'Z' =>
            declare
               Ignored : constant Protocol.Backend_Message :=
                 Protocol.Decode_Backend (Response);
            begin
               null;
            end;
            if not Item.Authentication_Ok then
               raise Protocol.Protocol_Error with
                 "ReadyForQuery arrived before AuthenticationOk";
            end if;
            Item.Item.Current_State := Ready;
            Complete_Startup_Operation (Item);
         when others =>
            Read_Next_Startup_Message (Item);
      end case;
   end Process_Startup_Message;

   procedure Advance_Startup_Send (Item : in out Startup_Operation) is
      Last   : Ada.Streams.Stream_Element_Offset;
      Result : Transports.Step_Result;
   begin
      Operation_Channel (Item.Item).Send_Step
        (Item.Buffer.Value.all (Item.Cursor .. Item.Buffer.Value.all'Last),
         Last,
         Result);
      case Result is
         when Transports.Made_Progress =>
            Item.Cursor := Last + 1;
            if Item.Cursor > Item.Buffer.Value.all'Last then
               Clear (Item.Buffer);
               if Item.Kind = TLS_Negotiation_Stage then
                  Item.Cursor := Item.TLS_Response'First;
                  Item.Phase := Reading_TLS_Response;
               else
                  Item.Cursor := Item.Tag'First;
                  Item.Phase := Reading_Tag;
               end if;
               Flyology.Operations.Drivers.Reschedule (Item);
            else
               Flyology.Operations.Drivers.Reschedule (Item);
            end if;
         when Transports.Need_Read | Transports.Need_Write =>
            Operation_Channel (Item.Item).Arm_Transport (Item, Result);
         when Transports.Peer_Closed =>
            raise Flyology.IO.Device_Error with
              "Postgres peer closed during startup send";
      end case;
   end Advance_Startup_Send;

   procedure Advance_Startup_Receive (Item : in out Startup_Operation) is
      Last   : Ada.Streams.Stream_Element_Offset;
      Result : Transports.Step_Result;
   begin
      case Item.Phase is
         when Reading_TLS_Response =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.TLS_Response
                 (Item.Cursor .. Item.TLS_Response'Last),
               Last,
               Result);
         when Reading_Tag =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Tag (Item.Cursor .. Item.Tag'Last), Last, Result);
         when Reading_Length =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Length_Data (Item.Cursor .. Item.Length_Data'Last),
               Last,
               Result);
         when Reading_Body =>
            Operation_Channel (Item.Item).Receive_Step
              (Item.Buffer.Value.all
                 (Item.Cursor .. Item.Buffer.Value.all'Last),
               Last,
               Result);
         when others =>
            raise Program_Error with "Postgres startup is not receiving";
      end case;

      case Result is
         when Transports.Made_Progress =>
            Item.Cursor := Last + 1;
            case Item.Phase is
               when Reading_TLS_Response =>
                  if Item.Cursor > Item.TLS_Response'Last then
                     if Item.TLS_Response (Item.TLS_Response'First) /=
                       Protocol.Byte (Character'Pos ('S'))
                     then
                        raise TLS_Not_Available with
                          "Postgres server refused TLS";
                     end if;
                     Item.Item.Current_State := TLS_Negotiated;
                     Complete_Startup_Operation (Item);
                  else
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
               when Reading_Tag =>
                  if Item.Cursor > Item.Tag'Last then
                     Item.Cursor := Item.Length_Data'First;
                     Item.Phase := Reading_Length;
                  end if;
                  Flyology.Operations.Drivers.Reschedule (Item);
               when Reading_Length =>
                  if Item.Cursor > Item.Length_Data'Last then
                     declare
                        Cursor : Protocol.Byte_Offset :=
                          Item.Length_Data'First;
                        Length : constant Protocol.UInt32 :=
                          Protocol.Read_U32 (Item.Length_Data, Cursor);
                     begin
                        if not Flyology.Postgres.Wire.Valid_Typed_Length
                          (Length)
                        then
                           raise Protocol.Protocol_Error with
                             "invalid typed Postgres message length";
                        end if;
                        Clear (Item.Buffer);
                        Item.Buffer.Value := new Protocol.Byte_Array
                          (1 .. Protocol.Byte_Offset
                             (Flyology.Postgres.Wire.Content_Length
                                (Length)));
                        Item.Cursor := Item.Buffer.Value.all'First;
                        Item.Phase := Reading_Body;
                        if Item.Buffer.Value.all'Length = 0 then
                           Process_Startup_Message (Item);
                        else
                           Flyology.Operations.Drivers.Reschedule (Item);
                        end if;
                     end;
                  else
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
               when Reading_Body =>
                  if Item.Cursor > Item.Buffer.Value.all'Last then
                     Process_Startup_Message (Item);
                  else
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
               when others =>
                  null;
            end case;
         when Transports.Need_Read | Transports.Need_Write =>
            Operation_Channel (Item.Item).Arm_Transport (Item, Result);
         when Transports.Peer_Closed =>
            raise Flyology.IO.Device_Error with
              "Postgres peer closed during startup receive";
      end case;
   end Advance_Startup_Receive;

   overriding procedure Drive
     (Item  : in out Startup_Operation;
      Event : Flyology.Operations.Driver_Event) is
      Acquisition : Transports.Acquisition_Result;
   begin
      begin
         case Event is
            when Flyology.Operations.Start_Operation =>
               Item.Phase := Acquiring_Transport;
               Operation_Channel (Item.Item).Start_Operation
                 (Item, Acquisition, Item.Timeout);
               if Acquisition = Transports.Acquired then
                  Item.Phase := Transferring_Data;
                  Advance_Startup_Send (Item);
               else
                  Operation_Channel (Item.Item).Arm_Acquisition (Item);
               end if;
            when Flyology.Operations.Source_Ready =>
               if Item.Phase = Acquiring_Transport then
                  Operation_Channel (Item.Item).Poll_Acquisition
                    (Acquisition);
                  if Acquisition = Transports.Acquired then
                     Item.Phase := Transferring_Data;
                     Advance_Startup_Send (Item);
                  else
                     Operation_Channel (Item.Item).Arm_Acquisition (Item);
                  end if;
               elsif Item.Phase = Transferring_Data then
                  Advance_Startup_Send (Item);
               else
                  Advance_Startup_Receive (Item);
               end if;
            when Flyology.Operations.Continue_Operation =>
               if Item.Phase = Transferring_Data then
                  Advance_Startup_Send (Item);
               else
                  Advance_Startup_Receive (Item);
               end if;
            when Flyology.Operations.Deadline_Reached =>
               raise Flyology.IO.Timeout_Error with
                 "Postgres startup operation deadline expired";
            when Flyology.Operations.Dependency_Changed =>
               raise Program_Error with
                 "Postgres startup operation has no dependency";
         end case;
      exception
         when Error : Flyology.Postgres.SCRAM.SCRAM_Error =>
            declare
               Wrapped : Ada.Exceptions.Exception_Occurrence;
            begin
               begin
                  raise Protocol.Protocol_Error with
                    Ada.Exceptions.Exception_Message (Error);
               exception
                  when Converted : others =>
                     Ada.Exceptions.Save_Occurrence (Wrapped, Converted);
               end;
               Fail_Startup (Item, Wrapped);
            end;
         when Error : others =>
            Fail_Startup (Item, Error);
      end;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Startup_Operation) is
   begin
      begin
         if Item.Phase /= Transfer_Idle then
            Operation_Channel (Item.Item).Cancel_Operation;
            Item.Phase := Transfer_Idle;
         end if;
         Wipe_Startup (Item);
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Cancelled);
      exception
         when Error : others =>
            Fail_Startup (Item, Error);
      end;
   end Request_Cancellation;

   procedure Start_Startup_Operation
     (Item      : not null access Session;
      Kind      : Startup_Kind;
      Timeout   : Duration;
      Operation : in out Startup_Operation) is
   begin
      Operation.Item := Item.all'Unchecked_Access;
      declare
         Ignored : constant access Transports.Operation_Transport'Class :=
           Operation_Channel (Operation.Item);
      begin
         null;
      end;
      if Kind = TLS_Negotiation_Stage then
         if Item.Current_State /= Not_Started then
            raise Program_Error with "Postgres session is already started";
         end if;
         Prepare_Startup_Send (Operation, Protocol.Encode_SSL_Request);
      else
         if Item.Current_State not in Not_Started | TLS_Negotiated then
            raise Program_Error with "Postgres session is already started";
         end if;
         Prepare_Startup_Send
           (Operation,
            Protocol.Encode_Startup
              (User             => To_String (Operation.User),
               Database         => To_String (Operation.Database),
               Application_Name => To_String (Operation.Application),
               Protocol_Minor   => 2,
               Replication_Mode => Operation.Replication_Mode));
      end if;
      Operation.Kind := Kind;
      Operation.SASL_Phase := No_SASL;
      Operation.Authentication_Ok := False;
      Operation.Timeout := Timeout;
      Flyology.Operations.Drivers.Start (Operation);
      Operation.Drive (Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            if Operation.Phase /= Transfer_Idle then
               begin
                  Release_Transport (Operation);
               exception
                  when others =>
                     null;
               end;
            end if;
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Startup_Operation;

   function Negotiate_TLS
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Session;
      Timeout : Duration := 30.0) return Startup_Operation is
   begin
      return Result : Startup_Operation (Set) do
         Negotiate_TLS (Item, Timeout, Result);
      end return;
   end Negotiate_TLS;

   procedure Negotiate_TLS
     (Item      : not null access Session;
      Timeout   : Duration := 30.0;
      Operation : in out Startup_Operation) is
   begin
      Start_Startup_Operation
        (Item, TLS_Negotiation_Stage, Timeout, Operation);
   end Negotiate_TLS;

   function Startup
     (Set              : not null access
        Flyology.Operations.Completion_Set'Class;
      Item             : not null access Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection) return Startup_Operation is
   begin
      return Result : Startup_Operation (Set) do
         Startup
           (Item,
            User,
            Database,
            Password,
            Application_Name,
            Timeout,
            Replication_Mode,
            Result);
      end return;
   end Startup;

   procedure Startup
     (Item             : not null access Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection;
      Operation        : in out Startup_Operation) is
   begin
      Operation.User := To_Unbounded_String (User);
      Operation.Database := To_Unbounded_String (Database);
      Operation.Password := To_Unbounded_String (Password);
      Operation.Application := To_Unbounded_String (Application_Name);
      Operation.Replication_Mode := Replication_Mode;
      Start_Startup_Operation
        (Item, Authentication_Stage, Timeout, Operation);
   exception
      when others =>
         Wipe_Startup (Operation);
         raise;
   end Startup;

   procedure Finish (Operation : in out Startup_Operation) is
      Terminal : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      Flyology.Operations.Consume (Operation);
      Clear (Operation.Buffer);
      Wipe_Startup (Operation);
      case Terminal is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            Ada.Exceptions.Reraise_Occurrence (Operation.Failure);
      end case;
   end Finish;

   function Receive_Extended_Event
     (Item : in out Session; Timeout : Duration := 30.0)
      return Extended_Query_Event is
      Response     : Protocol.Backend_Message;
      Sync_Pending : constant Boolean :=
        Has_Pending_Synchronization (Item);
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
      Apply_Extended_Event (Item, Response, Sync_Pending);
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
            --  A simple-query COPY reaches ReadyForQuery without a Sync of
            --  its own, so only an extended COPY has one to retire.
            if Item.Pending_Syncs > 0 then
               Item.Pending_Syncs := Item.Pending_Syncs - 1;
            end if;
            Item.Batch_Open := False;
            Item.Current_State :=
              (if Item.Pending_Syncs > 0 then Awaiting_Ready else Ready);
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

   procedure Enter_Pipeline_Mode (Item : in out Session) is
   begin
      if Item.Pipelined then
         return;
      end if;
      if Item.Current_State /= Ready then
         raise Program_Error with
           "cannot enter Postgres pipeline mode while session state is "
           & Item.Current_State'Image;
      end if;
      Item.Pipelined := True;
   end Enter_Pipeline_Mode;

   procedure Exit_Pipeline_Mode (Item : in out Session) is
   begin
      if not Item.Pipelined then
         return;
      end if;
      if Item.Pending_Syncs > 0 then
         raise Program_Error with
           "cannot end Postgres pipeline mode with"
           & Natural'Image (Item.Pending_Syncs)
           & " batch responses still outstanding";
      end if;
      if Item.Current_State /= Ready then
         raise Program_Error with
           "cannot end Postgres pipeline mode while session state is "
           & Item.Current_State'Image;
      end if;
      Item.Pipelined := False;
   end Exit_Pipeline_Mode;

   function In_Pipeline_Mode (Item : Session) return Boolean is
     (Item.Pipelined);

   function Pending_Synchronizations (Item : Session) return Natural is
     (Item.Pending_Syncs);

   function Is_Ready (Item : Session) return Boolean is
     (Item.Current_State = Ready);

   function State (Item : Session) return Operation_State is
     (Item.Current_State);

   function Backend_Process_Id (Item : Session) return Protocol.UInt32 is
     (Item.Pid);

   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));

end Flyology.Postgres.Client;
