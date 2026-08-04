with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with Flyology.Postgres.Server_Sessions.Control;
with Flyology.Postgres.Transports.Connections;
with Interfaces;
with System_Random;

package body Flyology.Postgres.Server is

   use type Protocol.Frontend_Kind;
   use type Protocol.Initial_Kind;
   use type Protocol.UInt16;
   use type Protocol.Byte_Offset;
   use type Protocol.Byte;
   use type Protocol.UInt32;

   package Session_Control renames Server_Sessions.Control;

   package OS_Random is new System_Random
     (Element       => Protocol.Byte,
      Index         => Protocol.Byte_Offset,
      Element_Array => Protocol.Byte_Array);

   function Same_Credentials
     (Left : Credentials; Right : Credentials) return Boolean is
      Difference : Protocol.Byte := 0;
   begin
      for Index in Left.Secret'Range loop
         Difference := Difference xor
           (Left.Secret (Index) xor Right.Secret (Index));
      end loop;
      return Left.Process_Id = Right.Process_Id
        and then Left.Length = Right.Length
        and then Difference = 0;
   end Same_Credentials;

   function Matches
     (Item       : Credentials;
      Process_Id : Protocol.UInt32;
      Secret     : Protocol.Byte_Array) return Boolean is
      Difference : Protocol.Byte := 0;
   begin
      for Offset in Natural range 0 .. Maximum_Secret_Length - 1 loop
         declare
            Actual : constant Protocol.Byte :=
              (if Offset < Secret'Length
               then Secret
                 (Secret'First + Protocol.Byte_Offset (Offset))
               else 0);
         begin
            Difference := Difference xor
              (Item.Secret (Item.Secret'First + Protocol.Byte_Offset (Offset))
               xor Actual);
         end;
      end loop;
      return Item.Process_Id = Process_Id
        and then Secret'Length = Item.Length
        and then Difference = 0;
   end Matches;

   procedure Generate
     (Item : out Credentials; Length : Secret_Length) is
      Data : aliased Protocol.Byte_Array :=
        (1 .. Protocol.Byte_Offset (Maximum_Secret_Length + 4) => 0);
   begin
      loop
         OS_Random.Random (Data);
         Item.Process_Id :=
           (Interfaces.Shift_Left (Protocol.UInt32 (Data (1)), 24)
            or Interfaces.Shift_Left (Protocol.UInt32 (Data (2)), 16)
            or Interfaces.Shift_Left (Protocol.UInt32 (Data (3)), 8)
            or Protocol.UInt32 (Data (4)))
           and 16#7FFF_FFFF#;
         exit when Item.Process_Id /= 0;
      end loop;
      for Offset in Natural range 0 .. Maximum_Secret_Length - 1 loop
         Item.Secret
           (Item.Secret'First + Protocol.Byte_Offset (Offset)) :=
             (if Offset < Length
              then Protocol.Byte
                (Data (Protocol.Byte_Offset (Offset + 5)))
              else 0);
      end loop;
      Item.Length := Length;
   end Generate;

   protected body Registry is
      procedure Try_Register
        (Item : Credentials; Status : out Registration_Status) is
         Free : Natural := 0;
      begin
         Status := Full;
         for Index in Entries'Range loop
            if Entries (Index).Occupied
              and then Same_Credentials (Entries (Index).Key, Item)
            then
               Status := Collision;
               return;
            elsif not Entries (Index).Occupied and then Free = 0 then
               Free := Index;
            end if;
         end loop;
         if Free /= 0 then
            Entries (Free) :=
              (Occupied      => True,
               Key           => Item,
               Current_Token => null);
            Status := Registered;
         end if;
      end Try_Register;

      procedure Begin_Operation
        (Item       : Credentials;
         Token      : Token_Access;
         Registered : out Boolean) is
      begin
         Registered := False;
         for Slot of Entries loop
            if Slot.Occupied and then Same_Credentials (Slot.Key, Item) then
               Slot.Current_Token := Token;
               Registered := True;
               return;
            end if;
         end loop;
      end Begin_Operation;

      procedure End_Operation (Item : Credentials) is
      begin
         for Slot of Entries loop
            if Slot.Occupied and then Same_Credentials (Slot.Key, Item) then
               Slot.Current_Token := null;
               return;
            end if;
         end loop;
      end End_Operation;

      procedure Remove (Item : Credentials) is
      begin
         for Slot of Entries loop
            if Slot.Occupied and then Same_Credentials (Slot.Key, Item) then
               Slot := (others => <>);
               return;
            end if;
         end loop;
      end Remove;

      procedure Route
        (Process_Id : Protocol.UInt32;
         Secret     : Protocol.Byte_Array) is
         Target : Token_Access := null;
      begin
         --  Scan every slot and every generated key byte. The protocol always
         --  closes silently, and routing reveals no match result to callers.
         for Slot of Entries loop
            if Matches (Slot.Key, Process_Id, Secret)
              and then Slot.Occupied
            then
               Target := Slot.Current_Token;
            end if;
         end loop;
         if Target /= null then
            Target.Request;
         end if;
      end Route;
   end Registry;

   protected body Inner_Holder is
      procedure Install
        (Value : Structured_Access; Stop_Already_Requested : out Boolean) is
      begin
         if Serve_Started then
            raise Program_Error with "Postgres server is one-shot";
         end if;
         Serve_Started := True;
         Current := Value;
         Stop_Already_Requested := Stop_Requested;
      end Install;

      procedure Request_Stop is
      begin
         Stop_Requested := True;
         if Current /= null then
            Structured.Request_Shutdown (Current.all);
         end if;
      end Request_Stop;

      procedure Clear (Value : Structured_Access) is
      begin
         if Current /= Value then
            raise Program_Error with "Postgres server lifecycle mismatch";
         end if;
         Current := null;
      end Clear;
   end Inner_Holder;

   function Worker_Capacity (Session_Count : Positive) return Positive is
   begin
      if Session_Count = Positive'Last then
         raise Program_Error with
           "Postgres server capacity leaves no cancellation worker";
      end if;
      return Session_Count + 1;
   end Worker_Capacity;

   procedure Send_Startup_Complete
     (Client  : in out Server_Sessions.Session;
      Startup : Protocol.Startup_Information;
      Key     : Credentials) is
   begin
      Server_Sessions.Send_Authentication_Ok
        (Client, Timeout => Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "server_version", "18.4", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "server_encoding", "UTF8", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "client_encoding", "UTF8", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "DateStyle", "ISO, MDY", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "integer_datetimes", "on", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "standard_conforming_strings", "on", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "TimeZone", "UTC", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client,
         "session_authorization",
         To_String (Startup.User),
         Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "is_superuser", "off", Write_Timeout);
      Server_Sessions.Send_Backend_Key_Data
        (Client,
         Process_Id => Key.Process_Id,
         Secret_Key => Key.Secret
           (Key.Secret'First ..
              Key.Secret'First
                + Protocol.Byte_Offset (Key.Length) - 1),
         Timeout    => Write_Timeout);
      Server_Sessions.Send_Ready (Client, Timeout => Write_Timeout);
   end Send_Startup_Complete;

   function Admit
     (Context : in out Handler_Context;
      Client  : in out Server_Sessions.Session;
      Startup : Protocol.Startup_Information) return Boolean is
   begin
      case Authentication is
         when Trust =>
            return Authenticate (Context, Startup, "");

         when Cleartext_Password =>
            Server_Sessions.Send_Authentication_Cleartext_Password
              (Client, Timeout => Write_Timeout);
            declare
               Password_Message : constant Protocol.Message :=
                 Server_Sessions.Read_Command
                   (Client, Timeout => Startup_Timeout);
            begin
               if Protocol.Kind (Password_Message) /=
                 Protocol.Password_Or_SASL_Response
               then
                  raise Protocol.Protocol_Error with
                    "expected a password response";
               end if;
               return Authenticate
                 (Context,
                  Startup,
                  Server_Sessions.Password_Text (Password_Message));
            end;

         when SCRAM_SHA_256 =>
            declare
               Supplied : constant String :=
                 Lookup_SCRAM_Verifier (Context, Startup);
               Has_Credential : constant Boolean := Supplied'Length > 0;
               --  A derived dummy credential keeps unknown users on the same
               --  challenge path without retaining a plaintext user password.
               Dummy : constant String :=
                 Flyology.Postgres.SCRAM.Make_Verifier_Raw
                   ("Flyology invalid SCRAM credential",
                    Flyology.Postgres.SCRAM.To_Bytes
                      ("fixed dummy salt"));
               Credential : constant Flyology.Postgres.SCRAM.Verifier :=
                 Flyology.Postgres.SCRAM.Parse_Verifier
                   ((if Has_Credential then Supplied else Dummy));
            begin
               Server_Sessions.Send_Authentication_SASL
                 (Client, Timeout => Write_Timeout);
               declare
                  Initial_Response : constant Protocol.Message :=
                    Server_Sessions.Read_Command
                      (Client, Timeout => Startup_Timeout);
                  Client_First : constant String :=
                    Server_Sessions.SASL_Initial_Response
                      (Initial_Response);
                  Bare : constant String :=
                    Flyology.Postgres.SCRAM.Bare_From_Client_First
                      (Client_First);
                  Client_Nonce : constant String :=
                    Flyology.Postgres.SCRAM.Nonce_From_Client_First
                      (Client_First);
                  Combined_Nonce : constant String :=
                    Client_Nonce & Flyology.Postgres.SCRAM.Random_Nonce;
                  Server_First : constant String :=
                    Flyology.Postgres.SCRAM.Server_First_Message
                      (Credential, Combined_Nonce);
               begin
                  Server_Sessions.Send_Authentication_SASL_Continue
                    (Client, Server_First, Write_Timeout);
                  declare
                     Final_Response : constant Protocol.Message :=
                       Server_Sessions.Read_Command
                         (Client, Timeout => Startup_Timeout);
                     Client_Final : constant String :=
                       Server_Sessions.SASL_Response (Final_Response);
                     Signature : Flyology.Postgres.SCRAM.Digest :=
                       (others => 0);
                     Proof_Valid : Boolean;
                  begin
                     Flyology.Postgres.SCRAM.Verify_Client_Final
                       (Credential,
                        Bare,
                        Server_First,
                        Combined_Nonce,
                        Client_Final,
                        Signature,
                        Proof_Valid);
                     if not Proof_Valid or else not Has_Credential then
                        Flyology.Postgres.SCRAM_Core.Wipe (Signature);
                        return False;
                     end if;
                     declare
                        Server_Final : constant String :=
                          "v=" & Flyology.Postgres.SCRAM.Base64_Encode
                            (Flyology.Postgres.SCRAM.Byte_Array (Signature));
                     begin
                        Flyology.Postgres.SCRAM_Core.Wipe (Signature);
                        Server_Sessions.Send_Authentication_SASL_Final
                          (Client, Server_Final, Write_Timeout);
                        return True;
                     end;
                  end;
               end;
            exception
               when Error : Flyology.Postgres.SCRAM.SCRAM_Error =>
                  raise Protocol.Protocol_Error with
                    Ada.Exceptions.Exception_Message (Error);
            end;
      end case;
   end Admit;

   procedure Run_Session
     (Context : in out Internal_Context;
      Client  : in out Server_Sessions.Session) is
      Initial : Protocol.Initial_Request :=
        Server_Sessions.Read_Initial (Client, Startup_Timeout);
   begin
      for Attempt in 1 .. 2 loop
         pragma Unreferenced (Attempt);
         case Protocol.Kind (Initial) is
            when Protocol.SSL_Request =>
               Server_Sessions.Refuse_TLS (Client, Write_Timeout);
            when Protocol.GSS_Request =>
               Server_Sessions.Refuse_GSS (Client, Write_Timeout);
            when others =>
               exit;
         end case;
         Initial := Server_Sessions.Read_Initial (Client, Startup_Timeout);
      end loop;

      if Protocol.Kind (Initial) = Protocol.Cancel_Request then
         Context.Router.Route
           (Protocol.Process_Id (Initial), Protocol.Secret_Key (Initial));
         return;
      elsif Protocol.Kind (Initial) /= Protocol.Startup then
         Server_Sessions.Send_Error
           (Client,
            Message   => "unsupported initial Postgres request",
            SQL_State => "08P01",
            Severity  => "FATAL",
            Timeout   => Write_Timeout);
         return;
      end if;

      declare
         Startup : constant Protocol.Startup_Information :=
           Protocol.Startup_Data (Initial);
      begin
         if Startup.Protocol_Major /= 3 then
            Server_Sessions.Send_Error
              (Client,
               Message   => "unsupported Postgres protocol version",
               SQL_State => "0A000",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
            return;
         end if;

         if Startup.Protocol_Minor > 2 then
            Server_Sessions.Send_Negotiate_Protocol
              (Client, Latest_Minor => 2, Timeout => Write_Timeout);
         end if;

         if not Admit (Context.Application.all, Client, Startup) then
            Server_Sessions.Send_Error
              (Client,
               Message   => "password authentication failed",
               SQL_State => "28P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
            return;
         end if;

         declare
            Key_Length : constant Secret_Length :=
              (if Startup.Protocol_Minor >= 2 then 32 else 4);
            Key        : Credentials;
            Status     : Registration_Status;
         begin
            loop
               Generate (Key, Key_Length);
               Context.Router.Try_Register (Key, Status);
               exit when Status = Registered;
               if Status = Full then
                  Server_Sessions.Send_Error
                    (Client,
                     Message   => "too many Postgres sessions",
                     SQL_State => "53300",
                     Severity  => "FATAL",
                     Timeout   => Write_Timeout);
                  return;
               end if;
            end loop;

            begin
               Send_Startup_Complete (Client, Startup, Key);

               loop
                  declare
                     Command : constant Protocol.Message :=
                       Server_Sessions.Read_Command
                         (Client, Command_Timeout);
                     Operation_Stop : aliased Flyology.Cancellation.Token;
                     Registered : Boolean;
                  begin
                     Context.Router.Begin_Operation
                       (Key,
                        Operation_Stop'Unchecked_Access,
                        Registered);
                     if not Registered then
                        raise Program_Error with
                          "Postgres cancellation registration disappeared";
                     end if;
                     Session_Control.Set_Operation_Cancellation
                       (Client, Operation_Stop'Unchecked_Access);
                     begin
                        Handle (Context.Application.all, Client, Command);
                     exception
                        when others =>
                           Session_Control.Clear_Operation_Cancellation
                             (Client);
                           Context.Router.End_Operation (Key);
                           raise;
                     end;
                     Session_Control.Clear_Operation_Cancellation (Client);
                     Context.Router.End_Operation (Key);
                     exit when Protocol.Kind (Command) =
                       Protocol.Terminate_Command;
                  end;
               end loop;
            exception
               when others =>
                  Context.Router.Remove (Key);
                  raise;
            end;
            Context.Router.Remove (Key);
         end;
      end;
   exception
      when Error : Protocol.Protocol_Error =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "08P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
         exception
            when others =>
               null;
         end;
      when Error : others =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "XX000",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
         exception
            when others =>
               null;
         end;
   end Run_Session;

   procedure Process_Connection
     (Context      : in out Internal_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Cancellation : not null access Flyology.Cancellation.Token) is
      pragma Unreferenced (Peer);
      Channel : aliased Transports.Connections.Connection_Transport
        (Connection'Unchecked_Access, Cancellation);
      Client : Server_Sessions.Session (Channel'Access);
   begin
      Session_Control.Set_Shutdown_Cancellation (Client, Cancellation);
      Run_Session (Context, Client);
   end Process_Connection;

   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out Flyology.IO.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Flyology.IO.Infinite) is
      Wrapped : aliased Internal_Context :=
        (Application => Context'Unchecked_Access,
         Router      => Item.Router'Unchecked_Access);
      Inner : Structured_Access :=
        new Structured.Server
          (Capacity => Worker_Capacity (Item.Capacity));
      Stop_Already_Requested : Boolean;
      Installed : Boolean := False;
      procedure Free is new Ada.Unchecked_Deallocation
        (Structured.Server, Structured_Access);
   begin
      Item.Inner.Install (Inner, Stop_Already_Requested);
      Installed := True;
      if Stop_Already_Requested then
         Structured.Request_Shutdown (Inner.all);
      end if;
      Structured.Serve
        (Inner.all, Listener, Wrapped, Drain_Timeout => Drain_Timeout);
      Item.Inner.Clear (Inner);
      Installed := False;
      Free (Inner);
   exception
      when others =>
         if Installed then
            Item.Inner.Clear (Inner);
         end if;
         Free (Inner);
         raise;
   end Serve;

   procedure Request_Shutdown (Item : in out Server) is
   begin
      Item.Inner.Request_Stop;
   end Request_Shutdown;

end Flyology.Postgres.Server;
