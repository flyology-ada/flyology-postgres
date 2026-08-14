with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Request_Bodies.Files;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Files;
with Psqlbench_JSON;
with Util.Properties;
with Util.Properties.JSON;

package body Psqlbench_Docker is

   package HTTP renames Flyology.HTTP.Client;
   package File_Bodies renames Flyology.HTTP.Client.Request_Bodies.Files;
   package Files renames Flyology.IO.Files;

   use type Ada.Real_Time.Time;

   Docker : aliased HTTP.Client (Capacity => 8);
   Configured : Boolean := False;

   function Socket_Path return String is
     (Ada.Environment_Variables.Value
        ("PSQLBENCH_DOCKER_SOCKET", "/var/run/docker.sock"));

   function Compact (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   procedure Store
     (Item      : in out Result;
      Value     : String;
      Truncated : Boolean := False) is
   begin
      Item.Length := Natural'Min (Value'Length, Max_Output_Bytes);
      if Item.Length > 0 then
         Item.Output (1 .. Item.Length) :=
           Value (Value'First .. Value'First + Item.Length - 1);
      end if;
      Item.Truncated := Truncated or else Value'Length > Max_Output_Bytes;
   end Store;

   function Text (Item : Result) return String is
     (if Item.Length = 0 then "" else Item.Output (1 .. Item.Length));

   function Timeout_For (Deadline : Ada.Real_Time.Time) return Duration is
   begin
      if Deadline = Ada.Real_Time.Time_Last then
         return -1.0;
      elsif Ada.Real_Time.Clock >= Deadline then
         raise Flyology.IO.Timeout_Error;
      else
         return Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
      end if;
   end Timeout_For;

   function Encoded (Value : String) return String is
      Hex : constant String := "0123456789ABCDEF";
      Output : Unbounded_String;
   begin
      for Item of Value loop
         if Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
           or else Item in '-' | '_' | '.' | '~'
         then
            Append (Output, Item);
         else
            declare
               Code : constant Natural := Character'Pos (Item);
            begin
               Append (Output, '%');
               Append (Output, Hex (Code / 16 + 1));
               Append (Output, Hex (Code mod 16 + 1));
            end;
         end if;
      end loop;
      return To_String (Output);
   end Encoded;

   function Error_Detail (Payload : String; Status : Natural) return String is
   begin
      declare
         Message : constant String :=
           Psqlbench_JSON.String_Field (Payload, "message");
      begin
         if Message'Length > 0 then
            return Message;
         end if;
      end;
      if Payload'Length > 0 then
         return Payload;
      end if;
      return "Docker Engine returned HTTP " & Compact (Status);
   exception
      when others =>
         return
           (if Payload'Length > 0 then Payload
            else "Docker Engine returned HTTP " & Compact (Status));
   end Error_Detail;

   function Read_Content
     (Response  : in out HTTP.Response;
      Token     : access Flyology.Cancellation.Token;
      Truncated : out Boolean) return String
   is
      use type Ada.Streams.Stream_Element_Offset;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 8 * 1_024);
      Last : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean := False;
      Content : Flyology.Bytes.Unbounded_Bytes;
   begin
      Truncated := False;
      Flyology.Bytes.Reserve_Capacity (Content, Max_Output_Bytes);
      while not Finished loop
         HTTP.Read_Body (Response, Buffer, Last, Finished, Token);
         if Last >= Buffer'First then
            declare
               Count : constant Natural :=
                 Natural (Last - Buffer'First + 1);
               Remaining : constant Natural :=
                 Max_Output_Bytes - Flyology.Bytes.Length (Content);
               Retained : constant Natural := Natural'Min (Count, Remaining);
            begin
               if Retained > 0 then
                  Flyology.Bytes.Append
                    (Content,
                     Buffer
                       (Buffer'First
                        .. Buffer'First
                             + Ada.Streams.Stream_Element_Offset (Retained)
                             - 1));
               end if;
               Truncated := Truncated or else Retained < Count;
            end;
         end if;
      end loop;
      return Flyology.Bytes.To_Byte_String (Content);
   end Read_Content;

   function Call
     (Method   : Flyology.HTTP.Method;
      Target   : String;
      Payload  : String := "";
      Media_Type : String := "";
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Accept_Not_Modified : Boolean := False) return Result
   is
      Request : HTTP.Request;
      Value : Result;
   begin
      HTTP.Set_Method (Request, Method);
      HTTP.Set_Target (Request, Target);
      if Media_Type'Length > 0 then
         HTTP.Add_Header (Request, "Content-Type", Media_Type);
      end if;
      if Payload'Length > 0 then
         HTTP.Set_Body (Request, Payload);
      end if;
      declare
         Response : HTTP.Response :=
           HTTP.Execute
             (Docker, Request, Timeout_For (Deadline), Token);
         Status : constant Natural := Natural (HTTP.Status (Response));
         Truncated : Boolean;
         Content : constant String :=
           Read_Content (Response, Token, Truncated);
      begin
         Value.Exit_Code := Integer (Status);
         Value.Success := Status in 200 .. 299
           or else (Accept_Not_Modified and then Status = 304);
         Store
           (Value,
            (if Value.Success then Content
             else Error_Detail (Content, Status)),
            Truncated);
      end;
      return Value;
   exception
      when Flyology.Cancellation.Operation_Cancelled |
           Flyology.IO.Timeout_Error =>
         raise;
      when Error : others =>
         Value.Exit_Code := -1;
         Store (Value, Ada.Exceptions.Exception_Message (Error));
         return Value;
   end Call;

   function Upload_Archive
     (Name     : String;
      Path     : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Request : HTTP.Request;
      File : aliased Files.File_Descriptor := Files.Invalid_File;
      Value : Result;
   begin
      File := Files.Open (Path);
      declare
         Count : constant HTTP.Body_Size :=
           HTTP.Body_Size (Ada.Directories.Size (Path));
         Source : File_Bodies.Range_Source
           (File'Access, Offset => 0, Count => Count);
      begin
         HTTP.Set_Method (Request, Flyology.HTTP.Methods.PUT);
         HTTP.Set_Target
           (Request,
            "/containers/" & Encoded (Name)
            & "/archive?path="
            & Encoded ("/var/lib/postgresql/data"));
         HTTP.Add_Header (Request, "Content-Type", "application/x-tar");
         declare
            Response : HTTP.Response :=
              HTTP.Execute
                (Docker, Request, Source, Timeout_For (Deadline), Token);
            Status : constant Natural := Natural (HTTP.Status (Response));
            Truncated : Boolean;
            Content : constant String :=
              Read_Content (Response, Token, Truncated);
         begin
            Value.Exit_Code := Integer (Status);
            Value.Success := Status in 200 .. 299;
            Store
              (Value,
               (if Value.Success then Content
                else Error_Detail (Content, Status)),
               Truncated);
         end;
      end;
      Files.Close (File);
      return Value;
   exception
      when Flyology.Cancellation.Operation_Cancelled |
           Flyology.IO.Timeout_Error =>
         Files.Close (File);
         raise;
      when Error : others =>
         Files.Close (File);
         Value.Exit_Code := -1;
         Store (Value, Ada.Exceptions.Exception_Message (Error));
         return Value;
   end Upload_Archive;

   function Parse (Document : String) return Util.Properties.Manager is
      Values : Util.Properties.Manager;
   begin
      Util.Properties.JSON.Parse_JSON (Values, Document);
      return Values;
   end Parse;

   function Property
     (Values : Util.Properties.Manager;
      Name   : String) return String is
     (Values.Get (Name, ""));

   function Container_Name (Name : String) return String is
     ("psqlbench-" & Name);

   procedure Start is
   begin
      if not Configured then
         HTTP.Configure
           (Docker,
            Flyology.HTTP.Parse_Origin ("http://localhost"),
            HTTP.Unix_Socket (Socket_Path),
            Mode => HTTP.HTTP_1_Only);
         Configured := True;
      end if;
   end Start;

   procedure Shutdown is
   begin
      if Configured then
         HTTP.Shutdown (Docker);
      end if;
   end Shutdown;

   function Check
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Value : Result :=
        Call
          (Flyology.HTTP.Methods.GET, "/version",
           Token => Token, Deadline => Deadline);
   begin
      if Value.Success then
         declare
            Version : constant String :=
              Psqlbench_JSON.String_Field (Text (Value), "Version");
         begin
            Store (Value, Version);
         end;
      end if;
      return Value;
   end Check;

   function Ensure_Network
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Value : constant Result :=
        Call
          (Flyology.HTTP.Methods.GET, "/networks/psqlbench",
           Token => Token, Deadline => Deadline);
   begin
      if Value.Success or else Value.Exit_Code /= 404 then
         return Value;
      end if;
      declare
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document, 1_024);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "Name", "psqlbench");
         Psqlbench_JSON.String_Value (Document, "Driver", "bridge");
         Psqlbench_JSON.Start_Object (Document, "Labels");
         Psqlbench_JSON.String_Value
           (Document, "org.flyology.psqlbench.network", "true");
         Psqlbench_JSON.End_Object (Document, "Labels");
         Psqlbench_JSON.End_Object (Document);
         return Call
           (Flyology.HTTP.Methods.POST, "/networks/create",
            Psqlbench_JSON.Finish (Document), "application/json",
            Token, Deadline);
      end;
   end Ensure_Network;

   function List_Document
     (Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document, 256);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.Start_Array (Document, "label");
      Psqlbench_JSON.String_Value
        (Document, "", "org.flyology.psqlbench.instance");
      Psqlbench_JSON.End_Array (Document, "label");
      Psqlbench_JSON.End_Object (Document);
      return Call
        (Flyology.HTTP.Methods.GET,
         "/containers/json?all=true&filters="
         & Encoded (Psqlbench_JSON.Finish (Document)),
         Token => Token, Deadline => Deadline);
   end List_Document;

   function Label_Text
     (Values : Util.Properties.Manager;
      Prefix : String) return String
   is
      Output : Unbounded_String;
      procedure Add (Name : String) is
         Value : constant String := Property (Values, Prefix & Name);
      begin
         if Value'Length > 0 then
            if Length (Output) > 0 then
               Append (Output, ',');
            end if;
            Append (Output, Name & "=" & Value);
         end if;
      end Add;
   begin
      Add ("org.flyology.psqlbench.instance");
      Add ("org.flyology.psqlbench.version");
      Add ("org.flyology.psqlbench.port");
      Add ("org.flyology.psqlbench.role");
      return To_String (Output);
   end Label_Text;

   function List_Instances
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Value : Result := List_Document (Token, Deadline);
   begin
      if not Value.Success then
         return Value;
      end if;
      declare
         Values : constant Util.Properties.Manager := Parse (Text (Value));
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document, Max_Output_Bytes);
         Psqlbench_JSON.Start_Array (Document);
         for Index in 0 .. 1_023 loop
            declare
               Prefix : constant String := Compact (Index) & ".";
            begin
               exit when not Values.Exists (Prefix & "Id");
               declare
                  Name : constant String :=
                    Property
                      (Values,
                       Prefix
                       & "Labels.org.flyology.psqlbench.instance");
               begin
                  Psqlbench_JSON.Start_Object (Document);
                  Psqlbench_JSON.String_Value
                    (Document, "Labels",
                     Label_Text (Values, Prefix & "Labels."));
                  Psqlbench_JSON.String_Value
                    (Document, "Names", Container_Name (Name));
                  Psqlbench_JSON.String_Value
                    (Document, "Image", Property (Values, Prefix & "Image"));
                  Psqlbench_JSON.String_Value
                    (Document, "State", Property (Values, Prefix & "State"));
                  Psqlbench_JSON.String_Value
                    (Document, "Status", Property (Values, Prefix & "Status"));
                  Psqlbench_JSON.End_Object (Document);
               end;
            end;
         end loop;
         Psqlbench_JSON.End_Array (Document);
         Store (Value, Psqlbench_JSON.Finish (Document));
      end;
      return Value;
   exception
      when Error : others =>
         Value.Success := False;
         Value.Exit_Code := -1;
         Store
           (Value,
            "Docker container list: "
            & Ada.Exceptions.Exception_Message (Error));
         return Value;
   end List_Instances;

   function List_Instance_Names
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Value : Result := List_Document (Token, Deadline);
      Output : Unbounded_String;
   begin
      if not Value.Success then
         return Value;
      end if;
      declare
         Values : constant Util.Properties.Manager := Parse (Text (Value));
      begin
         for Index in 0 .. 1_023 loop
            declare
               Prefix : constant String := Compact (Index) & ".";
            begin
               exit when not Values.Exists (Prefix & "Id");
               Append
                 (Output,
                  Property
                    (Values,
                     Prefix
                     & "Labels.org.flyology.psqlbench.instance"));
               Append (Output, ASCII.LF);
            end;
         end loop;
      end;
      Store (Value, To_String (Output));
      return Value;
   exception
      when Error : others =>
         Value.Success := False;
         Value.Exit_Code := -1;
         Store
           (Value,
            "Docker container names: "
            & Ada.Exceptions.Exception_Message (Error));
         return Value;
   end List_Instance_Names;

   function Inspect_Instance
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Call
        (Flyology.HTTP.Methods.GET,
         "/containers/" & Encoded (Container_Name (Name)) & "/json",
         Token => Token, Deadline => Deadline);
   end Inspect_Instance;

   function Inspect_Field
     (Name     : String;
      Field    : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Value : Result := Inspect_Instance (Name, Token, Deadline);
   begin
      if Value.Success then
         declare
            Values : constant Util.Properties.Manager := Parse (Text (Value));
         begin
            Store (Value, Property (Values, Field));
         end;
      end if;
      return Value;
   exception
      when Error : others =>
         Value.Success := False;
         Value.Exit_Code := -1;
         Store (Value, Ada.Exceptions.Exception_Message (Error));
         return Value;
   end Inspect_Field;

   function Instance_Port
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Inspect_Field
        (Name, "Config.Labels.org.flyology.psqlbench.port", Token, Deadline);
   end Instance_Port;

   function Instance_Version
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Inspect_Field
        (Name, "Config.Labels.org.flyology.psqlbench.version",
         Token, Deadline);
   end Instance_Version;

   function Instance_Role
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Inspect_Field
        (Name, "Config.Labels.org.flyology.psqlbench.role", Token, Deadline);
   end Instance_Role;

   function Instance_Running
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Inspect_Field (Name, "State.Running", Token, Deadline);
   end Instance_Running;

   function Decode_Multiplexed (Value : String) return String is
      Position : Natural := Value'First;
      Output : Unbounded_String;
   begin
      while Position + 7 <= Value'Last loop
         if Character'Pos (Value (Position)) not in 0 .. 3
           or else Value (Position + 1 .. Position + 3) /=
             String'(1 .. 3 => ASCII.NUL)
         then
            return Value;
         end if;
         declare
            Count : constant Natural :=
              Character'Pos (Value (Position + 4)) * 16#1000000#
              + Character'Pos (Value (Position + 5)) * 16#10000#
              + Character'Pos (Value (Position + 6)) * 16#100#
              + Character'Pos (Value (Position + 7));
            First : constant Natural := Position + 8;
         begin
            if Count > Value'Last - First + 1 then
               return Value;
            end if;
            if Count > 0 then
               Append (Output, Value (First .. First + Count - 1));
            end if;
            Position := First + Count;
         end;
      end loop;
      return To_String (Output);
   end Decode_Multiplexed;

   function Logs
     (Name     : String;
      Since    : String;
      Initial  : Boolean;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Target : constant String :=
        "/containers/" & Encoded (Container_Name (Name))
        & "/logs?stdout=true&stderr=true&timestamps=true"
        & (if Initial then "&tail=200" else "&since=" & Encoded (Since));
      Value : Result :=
        Call
          (Flyology.HTTP.Methods.GET, Target,
           Token => Token, Deadline => Deadline);
   begin
      if Value.Success then
         Store (Value, Decode_Multiplexed (Text (Value)));
      end if;
      return Value;
   end Logs;

   function Exec
     (Name     : String;
      Script   : String;
      User     : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document, 4 * 1_024);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.Boolean_Value (Document, "AttachStdout", True);
      Psqlbench_JSON.Boolean_Value (Document, "AttachStderr", True);
      Psqlbench_JSON.String_Value (Document, "User", User);
      Psqlbench_JSON.Start_Array (Document, "Cmd");
      Psqlbench_JSON.String_Value (Document, "", "sh");
      Psqlbench_JSON.String_Value (Document, "", "-c");
      Psqlbench_JSON.String_Value (Document, "", Script);
      Psqlbench_JSON.End_Array (Document, "Cmd");
      Psqlbench_JSON.End_Object (Document);
      declare
         Created : constant Result :=
           Call
             (Flyology.HTTP.Methods.POST,
              "/containers/" & Encoded (Container_Name (Name)) & "/exec",
              Psqlbench_JSON.Finish (Document), "application/json",
              Token, Deadline);
      begin
         if not Created.Success then
            return Created;
         end if;
         declare
            Id : constant String :=
              Psqlbench_JSON.String_Field (Text (Created), "Id");
            Start_Document : Psqlbench_JSON.Writer;
         begin
            Psqlbench_JSON.Initialize (Start_Document, 128);
            Psqlbench_JSON.Start_Object (Start_Document);
            Psqlbench_JSON.Boolean_Value
              (Start_Document, "Detach", False);
            Psqlbench_JSON.Boolean_Value
              (Start_Document, "Tty", False);
            Psqlbench_JSON.End_Object (Start_Document);
            declare
               Started : Result :=
                 Call
                   (Flyology.HTTP.Methods.POST,
                    "/exec/" & Encoded (Id) & "/start",
                    Psqlbench_JSON.Finish (Start_Document),
                    "application/json", Token, Deadline);
            begin
               if not Started.Success then
                  return Started;
               end if;
               declare
                  Output : constant String :=
                    Decode_Multiplexed (Text (Started));
                  Inspected : constant Result :=
                    Call
                      (Flyology.HTTP.Methods.GET,
                       "/exec/" & Encoded (Id) & "/json",
                       Token => Token, Deadline => Deadline);
               begin
                  if not Inspected.Success then
                     return Inspected;
                  end if;
                  declare
                     Exit_Code : constant Natural :=
                       Psqlbench_JSON.Natural_Field
                         (Text (Inspected), "ExitCode", 1);
                  begin
                     Started.Exit_Code := Integer (Exit_Code);
                     Started.Success := Exit_Code = 0;
                     Store
                       (Started,
                        (if Started.Success then Output
                         elsif Output'Length > 0 then Output
                         else "Docker exec exited " & Compact (Exit_Code)));
                     return Started;
                  end;
               end;
            end;
         end;
      end;
   end Exec;

   function Enable_Replication_Access
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
   begin
      return Exec
        (Name,
         "grep -qxF 'host replication psqlbench samenet scram-sha-256' "
         & """$PGDATA/pg_hba.conf"" || printf '%s\n' "
         & "'host replication psqlbench samenet scram-sha-256' >> "
         & """$PGDATA/pg_hba.conf""; pg_ctl reload",
         "postgres", Token, Deadline);
   end Enable_Replication_Access;

   function Ensure_Image
     (Version  : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Image : constant String := "postgres:" & Version & "-bookworm";
      Value : constant Result :=
        Call
          (Flyology.HTTP.Methods.GET,
           "/images/" & Encoded (Image) & "/json",
           Token => Token, Deadline => Deadline);
   begin
      if Value.Success or else Value.Exit_Code /= 404 then
         return Value;
      end if;
      return Call
        (Flyology.HTTP.Methods.POST,
         "/images/create?fromImage=postgres&tag="
         & Encoded (Version & "-bookworm"),
         Token => Token, Deadline => Deadline);
   end Ensure_Image;

   procedure Add_Common_Host_Config
     (Document : in out Psqlbench_JSON.Writer;
      Port     : Positive;
      Volume   : String := "") is
   begin
      Psqlbench_JSON.Start_Object (Document, "HostConfig");
      Psqlbench_JSON.String_Value (Document, "NetworkMode", "psqlbench");
      Psqlbench_JSON.Start_Array (Document, "ExtraHosts");
      Psqlbench_JSON.String_Value
        (Document, "", "host.docker.internal:host-gateway");
      Psqlbench_JSON.End_Array (Document, "ExtraHosts");
      Psqlbench_JSON.Start_Object (Document, "PortBindings");
      Psqlbench_JSON.Start_Array (Document, "5432/tcp");
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "HostIp", "127.0.0.1");
      Psqlbench_JSON.String_Value
        (Document, "HostPort", Compact (Port));
      Psqlbench_JSON.End_Object (Document);
      Psqlbench_JSON.End_Array (Document, "5432/tcp");
      Psqlbench_JSON.End_Object (Document, "PortBindings");
      if Volume'Length > 0 then
         Psqlbench_JSON.Start_Array (Document, "Mounts");
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "Type", "volume");
         Psqlbench_JSON.String_Value (Document, "Source", Volume);
         Psqlbench_JSON.String_Value
           (Document, "Target", "/var/lib/postgresql/data");
         Psqlbench_JSON.End_Object (Document);
         Psqlbench_JSON.End_Array (Document, "Mounts");
      end if;
      Psqlbench_JSON.End_Object (Document, "HostConfig");
   end Add_Common_Host_Config;

   procedure Add_Healthcheck
     (Document : in out Psqlbench_JSON.Writer;
      Retries  : Positive) is
   begin
      Psqlbench_JSON.Start_Object (Document, "Healthcheck");
      Psqlbench_JSON.Start_Array (Document, "Test");
      Psqlbench_JSON.String_Value (Document, "", "CMD-SHELL");
      Psqlbench_JSON.String_Value
        (Document, "", "pg_isready -U psqlbench -d postgres");
      Psqlbench_JSON.End_Array (Document, "Test");
      Psqlbench_JSON.Integer_Value (Document, "Interval", 1_000_000_000);
      Psqlbench_JSON.Integer_Value (Document, "Timeout", 3_000_000_000);
      Psqlbench_JSON.Integer_Value
        (Document, "Retries", Long_Long_Integer (Retries));
      Psqlbench_JSON.End_Object (Document, "Healthcheck");
   end Add_Healthcheck;

   procedure Add_Labels
     (Document : in out Psqlbench_JSON.Writer;
      Name     : String;
      Version  : String;
      Port     : Positive;
      Role     : String := "") is
   begin
      Psqlbench_JSON.Start_Object (Document, "Labels");
      Psqlbench_JSON.String_Value
        (Document, "org.flyology.psqlbench.instance", Name);
      Psqlbench_JSON.String_Value
        (Document, "org.flyology.psqlbench.version", Version);
      Psqlbench_JSON.String_Value
        (Document, "org.flyology.psqlbench.port", Compact (Port));
      if Role'Length > 0 then
         Psqlbench_JSON.String_Value
           (Document, "org.flyology.psqlbench.role", Role);
      end if;
      Psqlbench_JSON.End_Object (Document, "Labels");
   end Add_Labels;

   procedure Add_Exposed_Port
     (Document : in out Psqlbench_JSON.Writer) is
   begin
      Psqlbench_JSON.Start_Object (Document, "ExposedPorts");
      Psqlbench_JSON.Start_Object (Document, "5432/tcp");
      Psqlbench_JSON.End_Object (Document, "5432/tcp");
      Psqlbench_JSON.End_Object (Document, "ExposedPorts");
   end Add_Exposed_Port;

   procedure Add_Command_Value
     (Document : in out Psqlbench_JSON.Writer;
      Value    : String) is
   begin
      Psqlbench_JSON.String_Value (Document, "", Value);
   end Add_Command_Value;

   function Primary_Config
     (Name : String; Version : String; Port : Positive) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document, 16 * 1_024);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "Hostname", Name);
      Psqlbench_JSON.String_Value
        (Document, "Image", "postgres:" & Version & "-bookworm");
      Psqlbench_JSON.Start_Array (Document, "Env");
      Add_Command_Value (Document, "POSTGRES_USER=psqlbench");
      Add_Command_Value (Document, "POSTGRES_PASSWORD=psqlbench");
      Add_Command_Value (Document, "POSTGRES_DB=postgres");
      Psqlbench_JSON.End_Array (Document, "Env");
      Add_Exposed_Port (Document);
      Add_Labels (Document, Name, Version, Port);
      Add_Common_Host_Config (Document, Port);
      Add_Healthcheck (Document, 30);
      Psqlbench_JSON.Start_Array (Document, "Cmd");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "listen_addresses=*");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "wal_level=logical");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_wal_senders=20");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_replication_slots=20");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_prepared_transactions=20");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "hot_standby=on");
      Psqlbench_JSON.End_Array (Document, "Cmd");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Primary_Config;

   function Create_Instance
     (Name     : String;
      Version  : String;
      Port     : Positive;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Image : constant Result := Ensure_Image (Version, Token, Deadline);
      Value : Result;
   begin
      if not Image.Success then
         return Image;
      end if;
      Value := Call
        (Flyology.HTTP.Methods.POST,
         "/containers/create?name=" & Encoded (Container_Name (Name)),
         Primary_Config (Name, Version, Port), "application/json",
         Token, Deadline);
      if not Value.Success then
         return Value;
      end if;
      return Apply (Name, Start_Instance, Token, Deadline);
   end Create_Instance;

   function Delete_Container
     (Name     : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result is
   begin
      return Call
        (Flyology.HTTP.Methods.DELETE,
         "/containers/" & Encoded (Name) & "?force=true&v=true",
         Token => Token, Deadline => Deadline);
   end Delete_Container;

   function Delete_Volume
     (Name     : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result is
   begin
      return Call
        (Flyology.HTTP.Methods.DELETE,
         "/volumes/" & Encoded (Name) & "?force=true",
         Token => Token, Deadline => Deadline);
   end Delete_Volume;

   function Helper_Config
     (Image : String; Volume : String) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document, 8 * 1_024);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "Image", Image);
      Psqlbench_JSON.Start_Array (Document, "Env");
      Add_Command_Value (Document, "PGDATA=/var/lib/postgresql/data");
      Psqlbench_JSON.End_Array (Document, "Env");
      Psqlbench_JSON.Start_Object (Document, "HostConfig");
      Psqlbench_JSON.Start_Array (Document, "Mounts");
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "Type", "volume");
      Psqlbench_JSON.String_Value (Document, "Source", Volume);
      Psqlbench_JSON.String_Value
        (Document, "Target", "/var/lib/postgresql/data");
      Psqlbench_JSON.End_Object (Document);
      Psqlbench_JSON.End_Array (Document, "Mounts");
      Psqlbench_JSON.End_Object (Document, "HostConfig");
      Psqlbench_JSON.Start_Array (Document, "Cmd");
      Add_Command_Value (Document, "sh");
      Add_Command_Value (Document, "-c");
      Add_Command_Value
        (Document,
         "touch ""$PGDATA/standby.signal"""
         & " && chown -R postgres:postgres ""$PGDATA""");
      Psqlbench_JSON.End_Array (Document, "Cmd");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Helper_Config;

   function Standby_Config
     (Name       : String;
      Version    : String;
      Port       : Positive;
      Slot       : String;
      Relay_Port : Positive;
      Volume     : String) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document, 16 * 1_024);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "Hostname", Name);
      Psqlbench_JSON.String_Value
        (Document, "Image", "postgres:" & Version & "-bookworm");
      Psqlbench_JSON.Start_Array (Document, "Env");
      Add_Command_Value (Document, "PGDATA=/var/lib/postgresql/data");
      Add_Command_Value (Document, "POSTGRES_PASSWORD=psqlbench");
      Psqlbench_JSON.End_Array (Document, "Env");
      Add_Exposed_Port (Document);
      Add_Labels (Document, Name, Version, Port, "physical-standby");
      Add_Common_Host_Config (Document, Port, Volume);
      Add_Healthcheck (Document, 60);
      Psqlbench_JSON.Start_Array (Document, "Cmd");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "listen_addresses=*");
      Add_Command_Value (Document, "-c");
      Add_Command_Value
        (Document,
         "primary_conninfo=host=host.docker.internal port="
         & Compact (Relay_Port)
         & " user=psqlbench password=psqlbench application_name=" & Name);
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "primary_slot_name=" & Slot);
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "hot_standby=on");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "wal_level=logical");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_wal_senders=20");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_replication_slots=20");
      Add_Command_Value (Document, "-c");
      Add_Command_Value (Document, "max_prepared_transactions=20");
      Psqlbench_JSON.End_Array (Document, "Cmd");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Standby_Config;

   function Bootstrap_Physical_Standby
     (Name       : String;
      Version    : String;
      Port       : Positive;
      Slot       : String;
      Relay_Port : Positive;
      Archive_Path : String;
      Token      : access Flyology.Cancellation.Token := null;
      Deadline   : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
      return Result
   is
      Volume_Name : constant String := Container_Name (Name) & "-data";
      Helper_Name : constant String := Container_Name (Name) & "-bootstrap";
      Image : constant String := "postgres:" & Version & "-bookworm";
      Value : Result;

      procedure Remove_Helper is
         Ignored : constant Result :=
           Delete_Container (Helper_Name, Token, Deadline);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Remove_Helper;
   begin
      Value := Ensure_Image (Version, Token, Deadline);
      if not Value.Success then
         return Value;
      end if;
      Remove_Helper;
      declare
         Ignored : constant Result :=
           Delete_Volume (Volume_Name, Token, Deadline);
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      declare
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document, 1_024);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "Name", Volume_Name);
         Psqlbench_JSON.Start_Object (Document, "Labels");
         Psqlbench_JSON.String_Value
           (Document, "org.flyology.psqlbench.instance", Name);
         Psqlbench_JSON.End_Object (Document, "Labels");
         Psqlbench_JSON.End_Object (Document);
         Value := Call
           (Flyology.HTTP.Methods.POST, "/volumes/create",
            Psqlbench_JSON.Finish (Document), "application/json",
            Token, Deadline);
      end;
      if not Value.Success then
         return Value;
      end if;
      Value := Call
        (Flyology.HTTP.Methods.POST,
         "/containers/create?name=" & Encoded (Helper_Name),
         Helper_Config (Image, Volume_Name), "application/json",
         Token, Deadline);
      if not Value.Success then
         Remove_Helper;
         return Value;
      end if;
      Value := Upload_Archive
        (Helper_Name, Archive_Path, Token, Deadline);
      if not Value.Success then
         Remove_Helper;
         return Value;
      end if;
      Value := Call
        (Flyology.HTTP.Methods.POST,
         "/containers/" & Encoded (Helper_Name) & "/start",
         Token => Token, Deadline => Deadline,
         Accept_Not_Modified => True);
      if not Value.Success then
         Remove_Helper;
         return Value;
      end if;
      Value := Call
        (Flyology.HTTP.Methods.POST,
         "/containers/" & Encoded (Helper_Name)
         & "/wait?condition=not-running",
         Token => Token, Deadline => Deadline);
      if Value.Success
        and then Psqlbench_JSON.Natural_Field
          (Text (Value), "StatusCode", 1) /= 0
      then
         declare
            Failure : Result := Call
              (Flyology.HTTP.Methods.GET,
               "/containers/" & Encoded (Helper_Name)
               & "/logs?stdout=true&stderr=true&tail=50",
               Token => Token, Deadline => Deadline);
         begin
            Failure.Success := False;
            if Failure.Exit_Code in 200 .. 299 then
               Failure.Exit_Code := 1;
               Store (Failure, Decode_Multiplexed (Text (Failure)));
            end if;
            Remove_Helper;
            return Failure;
         end;
      elsif not Value.Success then
         Remove_Helper;
         return Value;
      end if;
      Remove_Helper;
      return Call
        (Flyology.HTTP.Methods.POST,
         "/containers/create?name=" & Encoded (Container_Name (Name)),
         Standby_Config
           (Name, Version, Port, Slot, Relay_Port, Volume_Name),
         "application/json", Token, Deadline);
   end Bootstrap_Physical_Standby;

   function Apply
     (Name     : String;
      Action   : Instance_Action;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Full_Name : constant String := Container_Name (Name);
      Value : Result;
   begin
      case Action is
         when Start_Instance =>
            return Call
              (Flyology.HTTP.Methods.POST,
               "/containers/" & Encoded (Full_Name) & "/start",
               Token => Token, Deadline => Deadline,
               Accept_Not_Modified => True);
         when Stop_Instance =>
            return Call
              (Flyology.HTTP.Methods.POST,
               "/containers/" & Encoded (Full_Name) & "/stop?t=10",
               Token => Token, Deadline => Deadline,
               Accept_Not_Modified => True);
         when Remove_Instance =>
            Value := Delete_Container (Full_Name, Token, Deadline);
            if Value.Success then
               declare
                  Ignored : constant Result :=
                    Delete_Volume (Full_Name & "-data", Token, Deadline);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            end if;
            return Value;
      end case;
   end Apply;

end Psqlbench_Docker;
