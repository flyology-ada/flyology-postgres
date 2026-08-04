with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres.Client;
with Flyology.Postgres.Client_Sockets;
with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.TLS_Sockets;

procedure Postgres_Test_Cancellation is

   package Client renames Flyology.Postgres.Client;
   package Client_Sockets renames Flyology.Postgres.Client_Sockets;
   package Framing renames Flyology.Postgres.Framing;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   use type Protocol.Byte;
   use type Protocol.UInt32;

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_TEST_PORT", "55432"));
   end Port;

   Server : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port);
   Server_Name : constant String :=
     Ada.Environment_Variables.Value
       ("POSTGRES_TLS_SERVER_NAME", "localhost");
   Backend : OpenSSL.OpenSSL_Provider;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Send_Raw_Cancel
     (Process_Id : Protocol.UInt32;
      Secret     : Protocol.Byte_Array) is
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
      Reply   : Protocol.Byte_Array (1 .. 1);
      Closed_Silently : Boolean := False;
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Server, Timeout => 5.0);
      Framing.Write_Packet
        (Channel, Protocol.Encode_SSL_Request, Timeout => 5.0);
      Channel.Receive_Exactly (Reply, Timeout => 5.0);
      Check
        (Reply (Reply'First) = Protocol.Byte (Character'Pos ('S')),
         "cancellation connection TLS was refused");
      Channel.Upgrade_TLS (Backend, Server_Name, Timeout => 5.0);
      Framing.Write_Packet
        (Channel,
         Protocol.Encode_Cancel_Request (Process_Id, Secret),
         Timeout => 5.0);
      begin
         Channel.Receive_Exactly (Reply, Timeout => 1.0);
      exception
         when Flyology.IO.Device_Error | TLS.TLS_Error =>
            Closed_Silently := True;
      end;
      Check (Closed_Silently, "CancelRequest did not close silently");
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Send_Raw_Cancel;

   procedure Expect_Still_Running (Item : in out Client.Session) is
      Timed_Out : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Protocol.Message :=
              Client.Receive_Message (Item, Timeout => 0.2);
         begin
            Check
              (Protocol.Code (Ignored) = Character'Val (0),
               "invalid cancellation unexpectedly produced a response");
         end;
      exception
         when Flyology.IO.Timeout_Error =>
            Timed_Out := True;
      end;
      Check (Timed_Out, "invalid or stale credentials cancelled a query");
   end Expect_Still_Running;

   procedure Drain_Cancellation (Item : in out Client.Session) is
      Saw_Query_Cancelled : Boolean := False;
   begin
      loop
         declare
            Message : constant Protocol.Message :=
              Client.Receive_Message (Item, Timeout => 5.0);
         begin
            if Protocol.Code (Message) = 'E' then
               Saw_Query_Cancelled := Client.SQL_State (Message) = "57014";
            end if;
            exit when Client.Is_Ready (Item);
         end;
      end loop;
      Check (Saw_Query_Cancelled, "valid cancellation did not stop handler");
   end Drain_Cancellation;

   Old_Process_Id : Protocol.UInt32 := 0;
   Old_Secret     : Flyology.Bytes.Unbounded_Bytes;

   protected Concurrent_Result is
      procedure Fail;
      function Succeeded return Boolean;
   private
      Good : Boolean := True;
   end Concurrent_Result;

   protected body Concurrent_Result is
      procedure Fail is
      begin
         Good := False;
      end Fail;

      function Succeeded return Boolean is (Good);
   end Concurrent_Result;

begin
   OpenSSL.Initialize_Client
     (Backend,
      CA_File => Ada.Environment_Variables.Value ("POSTGRES_TLS_CA_FILE"),
      Library_Directory => Ada.Environment_Variables.Value
        ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));

   --  Incorrect credentials must be indistinguishable on their separate
   --  connections and must leave the current handler running.
   declare
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Server, Timeout => 5.0);
      Client.Startup_TLS
        (Session,
         Backend,
         Server_Name => Server_Name,
         User     => "flyology",
         Database => "postgres",
         Password => "flyology-secret",
         Timeout  => 5.0);
      Check
        (Client.Backend_Secret_Key (Session)'Length = 32,
         "protocol 3.2 server did not issue a 32-byte key");
      Old_Process_Id := Client.Backend_Process_Id (Session);
      Old_Secret := Flyology.Bytes.To_Unbounded_Bytes
        (Client.Backend_Secret_Key (Session));

      Client.Send_Query (Session, "select pg_sleep(30)", Timeout => 5.0);
      delay 0.1;
      declare
         Wrong_Secret : Protocol.Byte_Array :=
           Client.Backend_Secret_Key (Session);
      begin
         Wrong_Secret (Wrong_Secret'First) :=
           Wrong_Secret (Wrong_Secret'First) xor 1;
         Send_Raw_Cancel
           (Client.Backend_Process_Id (Session), Wrong_Secret);
         Send_Raw_Cancel
           (Client.Backend_Process_Id (Session) xor 1,
            Client.Backend_Secret_Key (Session));
      end;
      Expect_Still_Running (Session);
      Client_Sockets.Cancel_TLS
        (Session, Server, Backend, Server_Name, Timeout => 5.0);
      Drain_Cancellation (Session);
      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
   end;

   delay 0.1;

   --  A stale key cannot affect a later session. Concurrent duplicates of
   --  the live key all route safely to the same one-shot operation token.
   declare
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Server, Timeout => 5.0);
      Client.Startup_TLS
        (Session,
         Backend,
         Server_Name => Server_Name,
         User     => "flyology",
         Database => "postgres",
         Password => "flyology-secret",
         Timeout  => 5.0);
      Client.Send_Query (Session, "select pg_sleep(30)", Timeout => 5.0);
      delay 0.1;
      Send_Raw_Cancel
        (Old_Process_Id, Flyology.Bytes.To_Array (Old_Secret));
      Expect_Still_Running (Session);

      declare
         task type Canceller;
         task body Canceller is
         begin
            Client_Sockets.Cancel_TLS
              (Session, Server, Backend, Server_Name, Timeout => 5.0);
         exception
            when others =>
               Concurrent_Result.Fail;
         end Canceller;

         Workers : array (1 .. 8) of Canceller;
         pragma Unreferenced (Workers);
      begin
         null;
      end;
      Check
        (Concurrent_Result.Succeeded,
         "concurrent CancelRequest dispatch failed");
      Drain_Cancellation (Session);
      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
   end;

   Ada.Text_IO.Put_Line
     ("Flyology server cancellation routing integration passed");
end Postgres_Test_Cancellation;
