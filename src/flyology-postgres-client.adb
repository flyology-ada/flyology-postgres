with Flyology.Postgres.Framing;

package body Flyology.Postgres.Client is

   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;

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

   procedure Startup
     (Item             : in out Session;
      User             : String;
      Database         : String := "";
      Password         : String := "";
      Application_Name : String := "flyology_postgres";
      Timeout          : Duration := 30.0) is
   begin
      if Item.Started then
         raise Program_Error with "Postgres session is already started";
      end if;

      Framing.Write_Packet
        (Item.Channel.all,
         Protocol.Encode_Startup
           (User             => User,
            Database         => Database,
            Application_Name => Application_Name),
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
                           null;
                        when 3 =>
                           Send_Password (Item, Password, Timeout);
                        when others =>
                           raise Unsupported_Authentication with
                             "server requested unsupported authentication"
                             & Method'Image;
                     end case;
                  end;
               when 'K' =>
                  declare
                     Cursor : Protocol.Byte_Offset := Contents'First;
                  begin
                     Item.Pid := Protocol.Read_U32 (Contents, Cursor);
                     Item.Secret := Flyology.Bytes.To_Unbounded_Bytes
                       (Contents (Cursor .. Contents'Last));
                  end;
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
               when 'Z' =>
                  declare
                     Ignored : constant Protocol.Backend_Message :=
                       Protocol.Decode_Backend (Response);
                  begin
                     null;
                  end;
                  Item.Started := True;
                  Item.Ready := True;
                  return;
               when others =>
                  null;
            end case;
         end;
      end loop;
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
