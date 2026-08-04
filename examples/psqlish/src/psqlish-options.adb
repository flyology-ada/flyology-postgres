with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Psqlish.Options is

   function Environment (Name, Fallback : String) return Unbounded_String is
     (To_Unbounded_String
        (Ada.Environment_Variables.Value (Name, Fallback)));

   function Parse_Port (Value : String) return Positive is
      Number : Integer;
   begin
      Number := Integer'Value (Value);
      if Number not in 1 .. 65_535 then
         raise Constraint_Error;
      end if;
      return Positive (Number);
   exception
      when Constraint_Error =>
         raise Option_Error with "invalid port: " & Value;
   end Parse_Port;

   function Parse_SSL_Mode (Value : String) return SSL_Mode is
   begin
      if Value = "disable" then
         return Disable;
      elsif Value = "verify-full" then
         return Verify_Full;
      else
         raise Option_Error with
           "unsupported sslmode: " & Value
           & " (expected disable or verify-full)";
      end if;
   end Parse_SSL_Mode;

   function Defaults return Configuration is
      Result : Configuration;
      Port_Text : constant String :=
        Ada.Environment_Variables.Value ("PGPORT", "55432");
   begin
      Result.Host := Environment ("PGHOST", "127.0.0.1");
      Result.Host_Address := Environment ("PGHOSTADDR", "");
      Result.Port := Parse_Port (Port_Text);
      Result.User := Environment ("PGUSER", "flyology");
      Result.Database := Environment ("PGDATABASE", "flyology");
      Result.Password := Environment ("PGPASSWORD", "");
      Result.TLS_Mode := Parse_SSL_Mode
        (Ada.Environment_Variables.Value ("PGSSLMODE", "disable"));
      Result.SSL_Root_Cert := Environment ("PGSSLROOTCERT", "");
      return Result;
   end Defaults;

   function Long_Value
     (Argument : String; Name : String; Found : out Boolean) return String is
      Prefix : constant String := "--" & Name & "=";
   begin
      Found := Argument'Length >= Prefix'Length
        and then Argument
          (Argument'First .. Argument'First + Prefix'Length - 1)
          = Prefix;
      if Found then
         return Argument
           (Argument'First + Prefix'Length .. Argument'Last);
      end if;
      return "";
   end Long_Value;

   function Parse
     (Arguments : Argument_Array;
      Base      : Configuration) return Configuration is
      Result : Configuration := Base;
      Index  : Positive := Arguments'First;

      function Next_Value (Option_Name : String) return String is
      begin
         if Index = Arguments'Last then
            raise Option_Error with "missing value for " & Option_Name;
         end if;
         Index := Index + 1;
         return Arguments (Index).all;
      end Next_Value;

      procedure Set_Option (Name, Value : String) is
      begin
         if Name = "host" then
            if Value'Length = 0 then
               raise Option_Error with "host must not be empty";
            end if;
            Result.Host := To_Unbounded_String (Value);
         elsif Name = "hostaddr" then
            Result.Host_Address := To_Unbounded_String (Value);
         elsif Name = "port" then
            Result.Port := Parse_Port (Value);
         elsif Name = "username" then
            Result.User := To_Unbounded_String (Value);
         elsif Name = "dbname" then
            Result.Database := To_Unbounded_String (Value);
         elsif Name = "sslmode" then
            Result.TLS_Mode := Parse_SSL_Mode (Value);
         elsif Name = "sslrootcert" then
            Result.SSL_Root_Cert := To_Unbounded_String (Value);
         elsif Name = "command" then
            Result.Command := To_Unbounded_String (Value);
            Result.Has_Command := True;
         else
            raise Program_Error;
         end if;
      end Set_Option;
   begin
      while Index <= Arguments'Last loop
         declare
            Argument : constant String := Arguments (Index).all;
            Found    : Boolean;
         begin
            if Argument = "--help" or else Argument = "-?" then
               Result.Show_Help := True;
            elsif Argument = "--version" or else Argument = "-V" then
               Result.Show_Version := True;
            elsif Argument in "-h" | "-p" | "-U" | "-d" | "-c" then
               declare
                  Value : constant String := Next_Value (Argument);
               begin
                  if Argument = "-h" then
                     Set_Option ("host", Value);
                  elsif Argument = "-p" then
                     Set_Option ("port", Value);
                  elsif Argument = "-U" then
                     Set_Option ("username", Value);
                  elsif Argument = "-d" then
                     Set_Option ("dbname", Value);
                  else
                     Set_Option ("command", Value);
                  end if;
               end;
            else
               declare
                  Names : constant array (Positive range <>) of
                    Unbounded_String :=
                      (To_Unbounded_String ("host"),
                       To_Unbounded_String ("hostaddr"),
                       To_Unbounded_String ("port"),
                       To_Unbounded_String ("username"),
                       To_Unbounded_String ("dbname"),
                       To_Unbounded_String ("sslmode"),
                       To_Unbounded_String ("sslrootcert"),
                       To_Unbounded_String ("command"));
                  Matched : Boolean := False;
               begin
                  for Name of Names loop
                     declare
                        Value : constant String :=
                          Long_Value (Argument, To_String (Name), Found);
                     begin
                        if Found then
                           Set_Option (To_String (Name), Value);
                           Matched := True;
                           exit;
                        elsif Argument = "--" & To_String (Name) then
                           Set_Option
                             (To_String (Name), Next_Value (Argument));
                           Matched := True;
                           exit;
                        end if;
                     end;
                  end loop;
                  if not Matched then
                     raise Option_Error with "unknown option: " & Argument;
                  end if;
               end;
            end if;
         end;
         Index := Index + 1;
      end loop;
      return Result;
   end Parse;

   function Parse return Configuration is
      Count : constant Natural := Ada.Command_Line.Argument_Count;
   begin
      if Count = 0 then
         return Defaults;
      end if;
      declare
         Storage : array (1 .. Count) of Unbounded_String;
         Args    : Argument_Array (1 .. Count);
      begin
         for Index in Storage'Range loop
            Storage (Index) :=
              To_Unbounded_String (Ada.Command_Line.Argument (Index));
            Args (Index) := new String'(To_String (Storage (Index)));
         end loop;
         return Parse (Args, Defaults);
      end;
   end Parse;

   function Help return String is
     ("psqlish - a deliberately small Postgres terminal" & ASCII.LF
      & ASCII.LF
      & "Usage: psqlish [OPTION]..." & ASCII.LF
      & "  -h, --host HOST       server address (default 127.0.0.1)"
      & ASCII.LF
      & "      --hostaddr IP     connect address; --host remains TLS name"
      & ASCII.LF
      & "  -p, --port PORT       server port (default 55432)" & ASCII.LF
      & "  -U, --username USER   database user (default flyology)"
      & ASCII.LF
      & "  -d, --dbname NAME     database name (default flyology)"
      & ASCII.LF
      & "      --sslmode MODE    disable or verify-full (default disable)"
      & ASCII.LF
      & "      --sslrootcert FILE  PEM trust file for verify-full"
      & ASCII.LF
      & "  -c, --command SQL     execute SQL and exit" & ASCII.LF
      & "  -?, --help            show this help" & ASCII.LF
      & "  -V, --version         show the version" & ASCII.LF
      & ASCII.LF
      & "PGHOST, PGHOSTADDR, PGPORT, PGUSER, PGDATABASE, PGPASSWORD,"
      & " PGSSLMODE, and PGSSLROOTCERT provide defaults. CLI options"
      & " override them. Passwords are never printed.");

end Psqlish.Options;
