with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;
with Psqlish;
with Psqlish.Display;
with Psqlish.Options;

procedure Flyology_Psql is

   package Client renames Flyology.Postgres.Client;
   package DNS renames Flyology.IO.DNS;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;
   package Display renames Psqlish.Display;

   use type Ada.Real_Time.Time;
   use type Display.Column;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Field_Format;

   package Format_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Protocol.Field_Format);
   package Display_Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Display.Column);

   Query_Timeout : constant Duration := 30.0;
   Client_Display_Limits : constant Display.Display_Limits :=
     (Buffered_Rows => 1_000,
      Result_Bytes  => 1_048_576,
      Cell_Width    => 80);

   procedure Put_Output (Value : String) is
   begin
      if Value'Length > 0 then
         Ada.Text_IO.Put (Value);
      end if;
   end Put_Output;

   procedure Put_Error (Value : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Value);
   end Put_Error;

   function Quoted_Literal (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("'");
   begin
      for Ch of Value loop
         Append (Result, Ch);
         if Ch = ''' then
            Append (Result, Ch);
         end if;
      end loop;
      Append (Result, "'");
      return To_String (Result);
   end Quoted_Literal;

   function Tables_SQL return String is
     ("SELECT schemaname AS schema, tablename AS name, "
      & "tableowner AS owner FROM pg_catalog.pg_tables "
      & "WHERE schemaname NOT IN ('pg_catalog', 'information_schema') "
      & "ORDER BY schemaname, tablename;");

   function Describe_SQL (Table_Name : String) return String is
     ("SELECT column_name AS column, data_type AS type, "
      & "is_nullable AS nullable, column_default AS default "
      & "FROM information_schema.columns WHERE table_name = "
      & Quoted_Literal (Table_Name) & " ORDER BY ordinal_position;");

   procedure Meta_Help is
   begin
      Ada.Text_IO.Put_Line ("General");
      Ada.Text_IO.Put_Line ("  \?                 show this help");
      Ada.Text_IO.Put_Line ("  \q                 quit");
      Ada.Text_IO.Put_Line ("Catalog");
      Ada.Text_IO.Put_Line ("  \dt                list user tables");
      Ada.Text_IO.Put_Line
        ("  \d [TABLE]         describe a table (or list tables)");
      Ada.Text_IO.Put_Line ("Display");
      Ada.Text_IO.Put_Line ("  \x on|off          expanded output");
      Ada.Text_IO.Put_Line ("  \timing on|off     query elapsed time");
      Ada.Text_IO.Put_Line ("  \pset null VALUE   set the NULL marker");
   end Meta_Help;

   procedure Handle_Meta
     (Line      : String;
      View      : in out Display.Result_State;
      Timing    : in out Boolean;
      Quit      : out Boolean;
      SQL       : out Unbounded_String;
      Has_SQL   : out Boolean) is
      use Ada.Strings;
      use Ada.Strings.Fixed;
      Text : constant String := Trim (Line, Both);
      Space : constant Natural := Index (Text, " ");
      Command : constant String :=
        (if Space = 0 then Text else Text (Text'First .. Space - 1));
      Argument : constant String :=
        (if Space = 0 then "" else Trim (Text (Space + 1 .. Text'Last), Both));

      procedure Toggle
        (Name : String; Value : String; Setting : in out Boolean) is
      begin
         if Value = "on" then
            Setting := True;
            Ada.Text_IO.Put_Line (Name & " is on");
         elsif Value = "off" then
            Setting := False;
            Ada.Text_IO.Put_Line (Name & " is off");
         else
            Put_Error ("usage: " & Command & " on|off");
         end if;
      end Toggle;
   begin
      Quit := False;
      Has_SQL := False;
      SQL := Null_Unbounded_String;
      if Command = "\q" then
         if Argument'Length = 0 then
            Quit := True;
         else
            Put_Error ("usage: \q");
         end if;
      elsif Command = "\?" then
         Meta_Help;
      elsif Command = "\dt" then
         if Argument'Length = 0 then
            SQL := To_Unbounded_String (Tables_SQL);
            Has_SQL := True;
         else
            Put_Error ("usage: \dt");
         end if;
      elsif Command = "\d" then
         SQL := To_Unbounded_String
           (if Argument'Length = 0
            then Tables_SQL
            else Describe_SQL (Argument));
         Has_SQL := True;
      elsif Command = "\x" then
         declare
            Setting : Boolean := Display.Expanded (View);
         begin
            Toggle ("Expanded display", Argument, Setting);
            Display.Set_Expanded (View, Setting);
         end;
      elsif Command = "\timing" then
         Toggle ("Timing", Argument, Timing);
      elsif Command = "\pset" then
         if Argument'Length >= 4
           and then Argument (Argument'First .. Argument'First + 3) = "null"
           and then (Argument'Length = 4
                     or else Argument (Argument'First + 4) = ' ')
         then
            declare
               Marker : constant String :=
                 (if Argument'Length = 4
                  then ""
                  else Argument (Argument'First + 5 .. Argument'Last));
            begin
               Display.Set_Null_Text (View, Marker);
               Ada.Text_IO.Put_Line
                 ("Null display is " & Display.Null_Text (View));
            end;
         else
            Put_Error ("usage: \pset null VALUE");
         end if;
      else
         Put_Error ("unknown command: " & Command & " (try \?)");
      end if;
   end Handle_Meta;

   function Statement_Complete (SQL : String) return Boolean is
   begin
      for Index in reverse SQL'Range loop
         if SQL (Index) not in ' ' | ASCII.HT | ASCII.CR | ASCII.LF then
            return SQL (Index) = ';';
         end if;
      end loop;
      return False;
   end Statement_Complete;

   function Execute_Query
     (Session : in out Client.Session;
      SQL     : String;
      View    : in out Display.Result_State;
      Timing  : Boolean) return Boolean is
      Formats    : Format_Vectors.Vector;
      Current_Columns : Display_Column_Vectors.Vector;
      Have_Result : Boolean := False;
      Had_Error   : Boolean := False;
      Started     : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Client.Send_Query (Session, SQL, Timeout => Query_Timeout);
      loop
         declare
            Event : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Session, Timeout => Query_Timeout);
         begin
            case Protocol.Response_Kind (Event) is
               when Protocol.Row_Description_Response =>
                  declare
                     Description : constant Protocol.Row_Description :=
                       Protocol.Description (Event);
                     Count : constant Positive :=
                       Protocol.Field_Count (Description);
                     Columns : Display.Column_Array (1 .. Count);
                  begin
                     Formats.Clear;
                     Current_Columns.Clear;
                     for Index in Columns'Range loop
                        declare
                           Field : constant Protocol.Field_Description :=
                             Protocol.Field_At (Description, Index);
                        begin
                           Formats.Append (Protocol.Format (Field));
                           Columns (Index) := Display.Make_Column
                             (Protocol.Field_Name (Field),
                              Binary => Protocol.Format (Field) =
                                Protocol.Binary_Format,
                              Maximum_Width =>
                                Client_Display_Limits.Cell_Width);
                           Current_Columns.Append (Columns (Index));
                        end;
                     end loop;
                     Display.Begin_Result (View, Columns);
                     Have_Result := True;
                  end;
               when Protocol.Data_Row_Response =>
                  declare
                     Row : constant Protocol.Data_Row :=
                       Protocol.Row_Data (Event);
                     Count : constant Positive :=
                       Protocol.Column_Count (Row);
                     Values : Display.Cell_Array (1 .. Count);
                  begin
                     for Index in Values'Range loop
                        declare
                           Value : constant Protocol.Column_Value :=
                             Protocol.Column_At (Row, Index);
                        begin
                           if Protocol.Is_Null (Value) then
                              Values (Index) := Display.Null_Cell;
                           elsif Formats.Element (Index) =
                             Protocol.Binary_Format
                           then
                              Values (Index) := Display.Binary_Cell
                                (Protocol.Column_Text (Value),
                                 Client_Display_Limits.Cell_Width);
                           else
                              Values (Index) := Display.Text_Cell
                                (Protocol.Column_Text (Value),
                                 Client_Display_Limits.Cell_Width);
                           end if;
                        end;
                     end loop;
                     if not Display.Try_Add_Row (View, Values) then
                        --  A page is complete. Rendering it releases retained
                        --  rows before the transport delivers the next one.
                        Put_Output (Display.Finish_Result (View));
                        declare
                           Columns : Display.Column_Array
                             (1 .. Natural (Current_Columns.Length));
                        begin
                           for Index in Columns'Range loop
                              Columns (Index) :=
                                Current_Columns.Element (Index);
                           end loop;
                           Display.Begin_Result (View, Columns);
                        end;
                        if not Display.Try_Add_Row (View, Values) then
                           raise Program_Error with
                             "one formatted row exceeds the configured batch";
                        end if;
                     end if;
                  end;
               when Protocol.Command_Complete_Response =>
                  Put_Output
                    (Display.Finish_Result
                       (View, Protocol.Completion_Tag (Event)));
                  Have_Result := False;
                  Formats.Clear;
               when Protocol.Empty_Query_Response =>
                  Put_Output
                    (Display.Finish_Result (View, Empty_Query => True));
                  Have_Result := False;
               when Protocol.Error_Response =>
                  if Have_Result then
                     Put_Output (Display.Finish_Result (View));
                     Have_Result := False;
                  end if;
                  declare
                     Diagnostic : constant Protocol.Diagnostic :=
                       Protocol.Diagnostic_Data (Event);
                     Severity : constant String :=
                       Protocol.Severity (Diagnostic);
                     State : constant String :=
                       Protocol.Diagnostic_SQL_State (Diagnostic);
                     Message : constant String :=
                       Protocol.Diagnostic_Message (Diagnostic);
                     Prefix : constant String :=
                       (if Severity'Length = 0 then "SERVER" else Severity);
                  begin
                     Put_Error
                       (Prefix &
                        (if State'Length = 0
                         then ": "
                         else " [" & State & "]: ")
                        & Message);
                     Had_Error := True;
                  end;
               when Protocol.Notice_Response =>
                  declare
                     Diagnostic : constant Protocol.Diagnostic :=
                       Protocol.Diagnostic_Data (Event);
                     Severity : constant String :=
                       Protocol.Severity (Diagnostic);
                     State : constant String :=
                       Protocol.Diagnostic_SQL_State (Diagnostic);
                     Message : constant String :=
                       Protocol.Diagnostic_Message (Diagnostic);
                     Prefix : constant String :=
                       (if Severity'Length = 0 then "NOTICE" else Severity);
                  begin
                     Put_Error
                       (Prefix &
                        (if State'Length = 0
                         then ": "
                         else " [" & State & "]: ")
                        & Message);
                  end;
               when Protocol.Parameter_Status_Response =>
                  declare
                     Status : constant Protocol.Parameter_Status :=
                       Protocol.Parameter_Data (Event);
                  begin
                     Ada.Text_IO.Put_Line
                       ("PARAMETER " & Protocol.Parameter_Name (Status)
                        & " = " & Protocol.Parameter_Value (Status));
                  end;
               when Protocol.Ready_For_Query_Response =>
                  if Have_Result then
                     Put_Output (Display.Finish_Result (View));
                  end if;
                  exit;
               when Protocol.Copy_In_Response |
                    Protocol.Copy_Out_Response |
                    Protocol.Copy_Both_Response =>
                  Had_Error := True;
                  Put_Error
                    ("ERROR [0A000]: COPY streaming is outside this "
                     & "example's scope");
                  raise Program_Error with
                    "COPY leaves this example connection unusable";
               when others =>
                  null;
            end case;
         end;
      end loop;
      if Timing then
         declare
            Elapsed : constant Duration := Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started);
            Milliseconds : constant Duration := Elapsed * 1_000;
         begin
            Ada.Text_IO.Put_Line
              ("Time:" & Duration'Image (Milliseconds) & " ms");
         end;
      end if;
      return not Had_Error;
   end Execute_Query;

   procedure Run (Configuration : Psqlish.Options.Configuration) is
      Addresses : constant DNS.Address_Array :=
        DNS.Resolve (To_String (Configuration.Host), Timeout => 5.0);
      Server : constant Sockets.Endpoint := Sockets.Network_Endpoint
        (Addresses (Addresses'First), Sockets.Port (Configuration.Port));
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      View    : Display.Result_State;
      Timing  : Boolean := False;
      Success : Boolean := True;
   begin
      Display.Configure_Limits (View, Client_Display_Limits);
      Sockets.Create_Socket (Socket, Family => Server.Family);
      Sockets.Connect (Socket, Server, Timeout => 5.0);
      Client.Startup
        (Session,
         User             => To_String (Configuration.User),
         Database         => To_String (Configuration.Database),
         Password         => To_String (Configuration.Password),
         Application_Name => "flyology_psql",
         Timeout          => Query_Timeout);
      if Configuration.Has_Command then
         Success := Execute_Query
           (Session, To_String (Configuration.Command), View, Timing => False);
      else
         Ada.Text_IO.Put_Line
           ("flyology_psql " & Psqlish.Version
            & " (TLS and COPY are not implemented; \? for help)");
         declare
            Buffer : Unbounded_String;
            Quit   : Boolean := False;
         begin
            while not Quit loop
               Ada.Text_IO.Put
                 ((if Length (Buffer) = 0
                   then To_String (Configuration.Database) & "=> "
                   else To_String (Configuration.Database) & "-> "));
               Ada.Text_IO.Flush;
               declare
                  Line : constant String := Ada.Text_IO.Get_Line;
                  Meta_SQL : Unbounded_String;
                  Has_SQL  : Boolean;
               begin
                  if Length (Buffer) = 0 and then Line'Length > 0
                    and then Line (Line'First) = '\'
                  then
                     Handle_Meta
                       (Line, View, Timing, Quit, Meta_SQL, Has_SQL);
                     if Has_SQL then
                        Success := Execute_Query
                          (Session, To_String (Meta_SQL), View, Timing)
                          and then Success;
                     end if;
                  else
                     if Length (Buffer) > 0 then
                        Append (Buffer, ASCII.LF);
                     end if;
                     Append (Buffer, Line);
                     if Statement_Complete (To_String (Buffer)) then
                        Success := Execute_Query
                          (Session, To_String (Buffer), View, Timing)
                          and then Success;
                        Buffer := Null_Unbounded_String;
                     end if;
                  end if;
               exception
                  when Ada.Text_IO.End_Error =>
                     if Length (Buffer) > 0 then
                        Success := Execute_Query
                          (Session, To_String (Buffer), View, Timing)
                          and then Success;
                     end if;
                     Ada.Text_IO.New_Line;
                     Quit := True;
               end;
            end loop;
         end;
      end if;

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
      Sockets.Close_Socket (Socket);
      if not Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   exception
      when others =>
         --  Do not send Terminate after a protocol/transport failure.
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Run;

begin
   declare
      Configuration : constant Psqlish.Options.Configuration :=
        Psqlish.Options.Parse;
   begin
      if Configuration.Show_Help then
         Ada.Text_IO.Put_Line (Psqlish.Options.Help);
      elsif Configuration.Show_Version then
         Ada.Text_IO.Put_Line ("flyology_psql " & Psqlish.Version);
      else
         Run (Configuration);
      end if;
   end;
exception
   when Error : Psqlish.Options.Option_Error =>
      Put_Error (Ada.Exceptions.Exception_Message (Error));
      Put_Error ("Try flyology_psql --help.");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when Error : others =>
      Put_Error (Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Flyology_Psql;
