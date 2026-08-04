with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;

procedure Postgres_Test_Client is

   package Client renames Flyology.Postgres.Client;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Byte;
   use type Protocol.UInt16;
   use type Protocol.UInt32;

   protected Result is
      procedure Pass;
      procedure Fail;
      entry Await (Succeeded : out Boolean);
   private
      Done : Boolean := False;
      Good : Boolean := False;
   end Result;

   protected body Result is
      procedure Pass is
      begin
         Done := True;
         Good := True;
      end Pass;

      procedure Fail is
      begin
         Done := True;
         Good := False;
      end Fail;

      entry Await (Succeeded : out Boolean) when Done is
      begin
         Succeeded := Good;
      end Await;
   end Result;

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_TEST_PORT", "55433"));
   end Port;

   task Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      Saw_One : Boolean := False;
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port),
         Timeout => 5.0);
      Client.Startup
        (Session,
         User     => "flyology",
         Database => "postgres",
         Password => "flyology-secret",
         Timeout  => 5.0);
      Client.Send_Query (Session, "select 1", Timeout => 5.0);

      loop
         declare
            Message : constant Protocol.Message :=
              Client.Receive_Message (Session, Timeout => 5.0);
         begin
            if Protocol.Code (Message) = 'D' then
               declare
                  Contents : constant Protocol.Byte_Array :=
                    Protocol.Payload (Message);
                  Cursor : Protocol.Byte_Offset := Contents'First;
                  Columns : constant Protocol.UInt16 :=
                    Protocol.Read_U16 (Contents, Cursor);
                  Length : constant Protocol.UInt32 :=
                    Protocol.Read_U32 (Contents, Cursor);
               begin
                  Saw_One := Columns = 1
                    and then Length = 1
                    and then Contents (Cursor) =
                      Protocol.Byte (Character'Pos ('1'));
               end;
            elsif Protocol.Code (Message) = 'E' then
               raise Client.Database_Error with Client.Error_Message (Message);
            end if;
            exit when Client.Is_Ready (Session);
         end;
      end loop;

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
      Sockets.Close_Socket (Socket);
      if Saw_One then
         Result.Pass;
      else
         Result.Fail;
      end if;
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         Result.Fail;
   end Worker;

begin
   declare
      Succeeded : Boolean;
   begin
      Result.Await (Succeeded);
      if not Succeeded then
         raise Program_Error with
           "lightweight Postgres client did not receive select 1";
      end if;
   end;
   Ada.Text_IO.Put_Line ("Flyology Postgres client integration passed");
end Postgres_Test_Client;
