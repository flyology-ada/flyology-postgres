with Ada.Environment_Variables;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;

procedure Postgres_Client_Operations_Benchmark is
   package Client renames Flyology.Postgres.Client;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Ada.Real_Time.Time;
   use type Protocol.Backend_Message_Kind;

   function Environment_Natural
     (Name : String; Default : Positive) return Positive
   is
      Value : constant String :=
        Ada.Environment_Variables.Value (Name, Positive'Image (Default));
   begin
      return Positive'Value (Value);
   exception
      when Constraint_Error =>
         raise Program_Error with Name & " must be a positive integer";
   end Environment_Natural;

   function Image (Value : Long_Float) return String is
     (Ada.Strings.Fixed.Trim (Long_Float'Image (Value), Ada.Strings.Both));

   function Image (Value : Positive) return String is
     (Ada.Strings.Fixed.Trim (Positive'Image (Value), Ada.Strings.Both));

   Samples              : constant Positive :=
     Environment_Natural ("BENCHMARK_SAMPLES", 7);
   Warmup_Connections   : constant Positive :=
     Environment_Natural ("BENCHMARK_WARMUP_CONNECTIONS", 50);
   Warmup_Queries       : constant Positive :=
     Environment_Natural ("BENCHMARK_WARMUP_QUERIES", 500);
   Measured_Connections : constant Positive :=
     Environment_Natural ("BENCHMARK_CONNECTIONS", 500);
   Measured_Queries     : constant Positive :=
     Environment_Natural ("BENCHMARK_QUERIES", 5_000);
   Rows_Per_Query       : constant Positive :=
     Environment_Natural ("BENCHMARK_ROWS", 8);
   Port                 : constant Sockets.Port :=
     Sockets.Port'Value
       (Ada.Environment_Variables.Value ("BENCHMARK_PORT", "55439"));
   Server               : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port);
   SQL                  : constant String :=
     "select n::text, repeat('x', 32) "
     & "from generate_series(1, " & Image (Rows_Per_Query) & ") n";

   type Sample_Array is array (Positive range <>) of Long_Float;
   Combined_Rates : Sample_Array (1 .. Samples);
   Query_Rates    : Sample_Array (1 .. Samples);
   Row_Rates      : Sample_Array (1 .. Samples);

   function Seconds_Since (Started : Ada.Real_Time.Time) return Long_Float is
     (Long_Float
        (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started)));

   procedure Open
     (Socket  : in out Sockets.Socket_Type;
      Session : in out Client.Session) is
   begin
      Sockets.Create_Socket (Socket, Family => Server.Family);
      Sockets.Connect (Socket, Server, Timeout => 10.0);
      Client.Startup
        (Session,
         User             => "flyology_benchmark",
         Database         => "postgres",
         Password         => "flyology-benchmark",
         Application_Name => "flyology_postgres_benchmark",
         Timeout          => 10.0);
   end Open;

   procedure Close
     (Socket  : in out Sockets.Socket_Type;
      Session : in out Client.Session) is
   begin
      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 10.0);
      Sockets.Close_Socket (Socket);
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Close;

   function Query (Session : in out Client.Session) return Natural is
      Rows : Natural := 0;
   begin
      Client.Send_Query (Session, SQL, Timeout => 10.0);
      loop
         declare
            Event : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Session, Timeout => 10.0);
         begin
            case Protocol.Response_Kind (Event) is
               when Protocol.Data_Row_Response =>
                  Rows := Rows + 1;
               when Protocol.Error_Response =>
                  raise Program_Error with
                    "benchmark query returned a database error";
               when Protocol.Ready_For_Query_Response =>
                  exit;
               when others =>
                  null;
            end case;
         end;
      end loop;
      if Rows /= Rows_Per_Query then
         raise Program_Error with
           "benchmark query returned" & Rows'Image & " rows";
      end if;
      return Rows;
   end Query;

   procedure Run_Combined
     (Iterations : Positive;
      Elapsed    : out Long_Float;
      Rows       : out Natural)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Rows := 0;
      for Iteration in 1 .. Iterations loop
         declare
            Socket  : aliased Sockets.Socket_Type;
            Channel : aliased Transports.Socket_Transport (Socket'Access);
            Session : Client.Session (Channel'Access);
         begin
            Open (Socket, Session);
            Rows := Rows + Query (Session);
            Close (Socket, Session);
         exception
            when others =>
               if Sockets.Is_Open (Socket) then
                  Sockets.Close_Socket (Socket);
               end if;
               raise;
         end;
      end loop;
      Elapsed := Seconds_Since (Started);
   end Run_Combined;

   procedure Run_Queries
     (Iterations : Positive;
      Elapsed    : out Long_Float;
      Rows       : out Natural)
   is
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      Started : Ada.Real_Time.Time;
   begin
      Rows := 0;
      Open (Socket, Session);
      Started := Ada.Real_Time.Clock;
      for Iteration in 1 .. Iterations loop
         Rows := Rows + Query (Session);
      end loop;
      Elapsed := Seconds_Since (Started);
      Close (Socket, Session);
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Run_Queries;

   procedure Sort (Values : in out Sample_Array) is
   begin
      for Left in Values'First .. Values'Last loop
         for Right in Left + 1 .. Values'Last loop
            if Values (Right) < Values (Left) then
               declare
                  Saved : constant Long_Float := Values (Left);
               begin
                  Values (Left) := Values (Right);
                  Values (Right) := Saved;
               end;
            end if;
         end loop;
      end loop;
   end Sort;

   procedure Print_Summary (Name : String; Values : Sample_Array) is
      Ordered  : Sample_Array := Values;
      Sum      : Long_Float := 0.0;
      Variance : Long_Float := 0.0;
      Mean     : Long_Float;
      Median   : Long_Float;
   begin
      Sort (Ordered);
      for Value of Values loop
         Sum := Sum + Value;
      end loop;
      Mean := Sum / Long_Float (Values'Length);
      for Value of Values loop
         Variance := Variance + (Value - Mean) ** 2;
      end loop;
      Variance := Variance / Long_Float (Values'Length);
      Median :=
        (if Values'Length mod 2 = 1
         then Ordered (Ordered'First + Values'Length / 2)
         else
           (Ordered (Ordered'First + Values'Length / 2 - 1)
            + Ordered (Ordered'First + Values'Length / 2)) / 2.0);
      Ada.Text_IO.Put_Line
        ("summary metric=" & Name
         & " unit=operations_per_second"
         & " min=" & Image (Ordered (Ordered'First))
         & " median=" & Image (Median)
         & " mean=" & Image (Mean)
         & " max=" & Image (Ordered (Ordered'Last))
         & " stddev="
         & Image (Ada.Numerics.Long_Elementary_Functions.Sqrt (Variance)));
   end Print_Summary;

   Ignored_Elapsed : Long_Float;
   Ignored_Rows    : Natural;
begin
   Ada.Text_IO.Put_Line
     ("configuration samples=" & Image (Samples)
      & " warmup_connections=" & Image (Warmup_Connections)
      & " warmup_queries=" & Image (Warmup_Queries)
      & " measured_connections=" & Image (Measured_Connections)
      & " measured_queries=" & Image (Measured_Queries)
      & " rows_per_query=" & Image (Rows_Per_Query)
      & " port=" & Ada.Strings.Fixed.Trim (Port'Image, Ada.Strings.Both));

   Run_Combined (Warmup_Connections, Ignored_Elapsed, Ignored_Rows);
   Run_Queries (Warmup_Queries, Ignored_Elapsed, Ignored_Rows);

   for Sample in 1 .. Samples loop
      declare
         Combined_Elapsed : Long_Float;
         Query_Elapsed    : Long_Float;
         Combined_Rows    : Natural;
         Query_Rows       : Natural;
      begin
         Run_Combined
           (Measured_Connections, Combined_Elapsed, Combined_Rows);
         Run_Queries (Measured_Queries, Query_Elapsed, Query_Rows);
         Combined_Rates (Sample) :=
           Long_Float (Measured_Connections) / Combined_Elapsed;
         Query_Rates (Sample) :=
           Long_Float (Measured_Queries) / Query_Elapsed;
         Row_Rates (Sample) := Long_Float (Query_Rows) / Query_Elapsed;
         Ada.Text_IO.Put_Line
           ("sample=" & Image (Sample)
            & " combined_seconds=" & Image (Combined_Elapsed)
            & " combined_operations_per_second="
            & Image (Combined_Rates (Sample))
            & " combined_microseconds_per_operation="
            & Image (1_000_000.0 / Combined_Rates (Sample))
            & " query_seconds=" & Image (Query_Elapsed)
            & " query_operations_per_second="
            & Image (Query_Rates (Sample))
            & " query_microseconds_per_operation="
            & Image (1_000_000.0 / Query_Rates (Sample))
            & " result_rows_per_second=" & Image (Row_Rates (Sample)));
      end;
   end loop;

   Print_Summary ("combined_connect_query_result", Combined_Rates);
   Print_Summary ("persistent_query_result", Query_Rates);
   Print_Summary ("persistent_result_rows", Row_Rates);
end Postgres_Client_Operations_Benchmark;
