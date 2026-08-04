with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;

procedure Postgres_Test_Server is

   package Protocol renames Flyology.Postgres.Protocol;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;

   use type Protocol.Frontend_Kind;
   use type Protocol.Frontend_Copy_Kind;

   type Context is limited record
      Verifier : Unbounded_String := To_Unbounded_String
        (Flyology.Postgres.SCRAM.Make_Verifier_Raw
           ("flyology-secret",
            Flyology.Postgres.SCRAM.To_Bytes ("Flyology test salt")));
   end record;

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (State, Startup);
   begin
      return Password = "flyology-secret";
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String is
   begin
      return
        (if To_String (Startup.User) = "flyology"
         then To_String (State.Verifier)
         else "");
   end Lookup_SCRAM_Verifier;

   function Is_Select (SQL : String) return Boolean is
      Trimmed : constant String := Ada.Strings.Fixed.Trim
        (SQL, Ada.Strings.Both);
      Lower   : constant String := Ada.Characters.Handling.To_Lower (Trimmed);
   begin
      return Lower'Length >= 6
        and then Lower (Lower'First .. Lower'First + 5) = "select";
   end Is_Select;

   function Is_Copy (SQL : String; Direction : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower
        (Ada.Strings.Fixed.Trim (SQL, Ada.Strings.Both));
   begin
      return Lower'Length >= 4
        and then Lower (Lower'First .. Lower'First + 3) = "copy"
        and then Ada.Strings.Fixed.Index (Lower, Direction) /= 0;
   end Is_Copy;

   function Bytes (Value : String) return Protocol.Byte_Array is
     (Flyology.Bytes.To_Array (Flyology.Bytes.From_Byte_String (Value)));

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Command : Protocol.Message) is
      pragma Unreferenced (State);
      Timeout : constant Duration := 5.0;
   begin
      if Protocol.Kind (Command) in Protocol.Parse |
         Protocol.Bind |
         Protocol.Describe |
         Protocol.Execute |
         Protocol.Close |
         Protocol.Flush |
         Protocol.Sync
      then
         Ada.Text_IO.Put_Line
           ("frontend " & Protocol.Kind (Command)'Image);
         Ada.Text_IO.Flush;
      end if;
      case Protocol.Kind (Command) is
         when Protocol.Query =>
            declare
               SQL : constant String := Sessions.Query_Text (Command);
               Trimmed : constant String :=
                 Ada.Strings.Fixed.Trim (SQL, Ada.Strings.Both);
            begin
               if Trimmed'Length = 0 then
                  Sessions.Send_Empty_Query_Response (Client, Timeout);
               elsif Ada.Characters.Handling.To_Lower (Trimmed) =
                 "select pg_sleep(30)"
               then
                  for Attempt in 1 .. 3_000 loop
                     pragma Unreferenced (Attempt);
                     if Sessions.Cancellation_Requested (Client) then
                        Sessions.Send_Error
                          (Client,
                           Message   =>
                             "canceling statement due to user request",
                           SQL_State => "57014",
                           Timeout   => Timeout);
                        Sessions.Send_Ready (Client, Timeout => Timeout);
                        return;
                     end if;
                     delay 0.01;
                  end loop;
                  Sessions.Send_Command_Complete
                    (Client, "SELECT 1", Timeout);
               elsif Is_Copy (SQL, "to stdout") then
                  Sessions.Send_Copy_Out_Response
                    (Client,
                     Overall_Format => Protocol.Text_Format,
                     Column_Formats =>
                       (Protocol.Text_Format, Protocol.Text_Format),
                     Timeout => Timeout);
                  Sessions.Send_Copy_Data
                    (Client, Bytes ("one" & ASCII.HT & ASCII.LF), Timeout);
                  Sessions.Send_Copy_Data
                    (Client,
                     Bytes ("\N" & ASCII.HT & "two" & ASCII.LF),
                     Timeout);
                  Sessions.Send_Copy_Done (Client, Timeout);
                  Sessions.Send_Command_Complete
                    (Client, "COPY 2", Timeout);
               elsif Is_Copy (SQL, "from stdin") then
                  Sessions.Send_Copy_In_Response
                    (Client,
                     Overall_Format => Protocol.Text_Format,
                     Column_Formats =>
                       (Protocol.Text_Format, Protocol.Text_Format),
                     Timeout => Timeout);
                  declare
                     Chunks : Natural := 0;
                     Done   : Boolean := False;
                     Failed : Boolean := False;
                  begin
                     while not Done loop
                        declare
                           Copy_Command : constant
                             Protocol.Frontend_Copy_Message :=
                               Sessions.Read_Copy_Command (Client, Timeout);
                        begin
                           case Protocol.Copy_Kind (Copy_Command) is
                              when Protocol.Frontend_Copy_Data =>
                                 Chunks := Chunks + 1;
                              when Protocol.Frontend_Copy_Done =>
                                 Done := True;
                              when Protocol.Frontend_Copy_Fail =>
                                 Done := True;
                                 Failed := True;
                           end case;
                        end;
                     end loop;
                     Ada.Text_IO.Put_Line
                       ("frontend COPY chunks" & Chunks'Image);
                     Ada.Text_IO.Flush;
                     if Failed then
                        Sessions.Send_Error
                          (Client,
                           "client aborted COPY",
                           SQL_State => "57014",
                           Timeout => Timeout);
                     else
                        Sessions.Send_Command_Complete
                          (Client, "COPY 2", Timeout);
                     end if;
                  end;
               elsif Is_Select (SQL) then
                  Sessions.Send_Row_Description
                    (Client,
                     Columns =>
                       (1 => Protocol.Make_Field_Description
                          (Name      => "id",
                           Type_Oid  => 23,
                           Type_Size => 4),
                        2 => Protocol.Make_Field_Description ("label"),
                        3 => Protocol.Make_Field_Description ("optional")),
                     Timeout => Timeout);
                  Sessions.Send_Data_Row
                    (Client,
                     Values =>
                       (Protocol.Text_Column ("1"),
                        Protocol.Text_Column ("alpha"),
                        Protocol.Null_Column),
                     Timeout => Timeout);
                  Sessions.Send_Data_Row
                    (Client,
                     Values =>
                       (Protocol.Text_Column ("2"),
                        Protocol.Text_Column (""),
                        Protocol.Text_Column ("omega")),
                     Timeout => Timeout);
                  Sessions.Send_Command_Complete
                    (Client, "SELECT 2", Timeout);
               else
                  Sessions.Send_Command_Complete (Client, "OK", Timeout);
               end if;
               Sessions.Send_Ready (Client, Timeout => Timeout);
            end;

         when Protocol.Parse =>
            Sessions.Send_Parse_Complete (Client, Timeout);

         when Protocol.Bind =>
            Sessions.Send_Bind_Complete (Client, Timeout);

         when Protocol.Describe =>
            Sessions.Send_No_Data (Client, Timeout);

         when Protocol.Execute =>
            Sessions.Send_Command_Complete (Client, "SELECT 0", Timeout);

         when Protocol.Close =>
            Sessions.Send_Close_Complete (Client, Timeout);

         when Protocol.Sync =>
            Sessions.Send_Ready (Client, Timeout => Timeout);

         when Protocol.Flush | Protocol.Terminate_Command =>
            null;

         when others =>
            Sessions.Send_Error
              (Client,
               Message   => "unsupported command in test server",
               SQL_State => "0A000",
               Timeout   => Timeout);
            Sessions.Send_Ready (Client, Timeout => Timeout);
      end case;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context => Context,
      Authenticate    => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle          => Handle,
      Authentication  => Flyology.Postgres.SCRAM_SHA_256,
      Handler_Model   => Flyology.Lightweight_Task);

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_TEST_PORT", "55432"));
   end Port;

   Listener : Sockets.Socket_Type;
   State    : aliased Context;
   Server   : aliased Test_Server.Server (Capacity => 8);
begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener,
      (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 16);
   Ada.Text_IO.Put_Line ("ready");
   Ada.Text_IO.Flush;
   Test_Server.Serve
     (Server, Listener, State, Drain_Timeout => 1.0);
end Postgres_Test_Server;
