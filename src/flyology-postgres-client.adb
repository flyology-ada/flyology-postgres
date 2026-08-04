with Flyology.Postgres.Framing;

package body Flyology.Postgres.Client is

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;
   use type Protocol.Frontend_Kind;

   function Error_Field
     (Value : Protocol.Message; Wanted : Character) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Value);
      Cursor   : Protocol.Byte_Offset := Contents'First;
   begin
      while Cursor <= Contents'Last and then Contents (Cursor) /= 0 loop
         declare
            Code : constant Character := Character'Val (Contents (Cursor));
         begin
            Cursor := Cursor + 1;
            declare
               Text : constant String :=
                 Protocol.Read_C_String (Contents, Cursor);
            begin
               if Code = Wanted then
                  return Text;
               end if;
            end;
         end;
      end loop;
      return "";
   end Error_Field;

   function Error_Message (Value : Protocol.Message) return String is
     (Error_Field (Value, 'M'));

   function SQL_State (Value : Protocol.Message) return String is
     (Error_Field (Value, 'C'));

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
               when 'Z' =>
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
      if Protocol.Kind (Command) = Protocol.Terminate_Command then
         Item.Started := False;
      end if;
   end Send_Command;

   procedure Send_Query
     (Item : in out Session; SQL : String; Timeout : Duration := 30.0) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
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
      end if;
      return Response;
   end Receive_Message;

   function Is_Ready (Item : Session) return Boolean is (Item.Ready);

   function Backend_Process_Id (Item : Session) return Protocol.UInt32 is
     (Item.Pid);

   function Backend_Secret_Key (Item : Session) return Protocol.Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));

end Flyology.Postgres.Client;
