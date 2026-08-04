with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Introspection_Catalog;
with Introspection_SQL;

package body Introspection_Handler is

   package Protocol renames Flyology.Postgres.Protocol;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Catalog renames Introspection_Catalog;
   package SQL renames Introspection_SQL;
   package State renames Introspection_State;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Frontend_Kind;
   use type Protocol.UInt16;
   use type Protocol.UInt32;

   Timeout : constant Duration := 10.0;

   function Authenticate
     (Context  : in out Introspection_State.Server_State;
      Startup  : Flyology.Postgres.Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (Password);
      Accepted : Boolean;
      User : constant String := Ada.Strings.Unbounded.To_String (Startup.User);
      Database : constant String :=
        (if Ada.Strings.Unbounded.Length (Startup.Database) = 0
         then User else Ada.Strings.Unbounded.To_String (Startup.Database));
   begin
      Introspection_State.Register_Session
        (Context,
         User_Name        => User,
         Database_Name    => Database,
         Application_Name =>
           Ada.Strings.Unbounded.To_String (Startup.Application_Name),
         Accepted         => Accepted);
      return Accepted;
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (Context : in out Introspection_State.Server_State;
      Startup : Flyology.Postgres.Protocol.Startup_Information) return String is
      pragma Unreferenced (Context, Startup);
   begin
      return "";
   end Lookup_SCRAM_Verifier;

   procedure Send_Result
     (Client        : in out Sessions.Session;
      Result        : Catalog.Result_Set;
      Describe_Only : Boolean := False;
      Include_Description : Boolean := True;
      Maximum_Rows  : Natural := 0;
      Cancelled     : out Boolean) is
      Rows : constant Natural :=
        (if Maximum_Rows = 0 then Result.Row_Count
         else Natural'Min (Maximum_Rows, Result.Row_Count));
   begin
      Cancelled := False;
      if Include_Description then
         declare
            Fields : Protocol.Field_Description_Array
              (1 .. Result.Column_Count);
         begin
            for Index in Fields'Range loop
               Fields (Index) := Protocol.Make_Field_Description
                 (Name      => SQL.Image (Result.Columns (Index).Name),
                  Type_Oid  =>
                    Protocol.UInt32 (Result.Columns (Index).Type_Oid),
                  Type_Size =>
                    Protocol.Int16 (Result.Columns (Index).Type_Size));
            end loop;
            Sessions.Send_Row_Description (Client, Fields, Timeout);
         end;
      end if;
      if Describe_Only then
         return;
      end if;
      for Row_Index in 1 .. Rows loop
         if Sessions.Cancellation_Requested (Client) then
            Sessions.Send_Error
              (Client,
               Message   => "canceling statement due to user request",
               SQL_State => "57014",
               Timeout   => Timeout);
            Cancelled := True;
            return;
         end if;
         declare
            Values : Protocol.Column_Value_Array (1 .. Result.Column_Count);
         begin
            for Column in Values'Range loop
               Values (Column) :=
                 (if Result.Rows (Row_Index).Values (Column).Is_Null
                  then Protocol.Null_Column
                  else Protocol.Text_Column
                    (SQL.Image (Result.Rows (Row_Index).Values (Column).Value)));
            end loop;
            Sessions.Send_Data_Row (Client, Values, Timeout);
         end;
      end loop;
      Sessions.Send_Command_Complete
        (Client, "SELECT" & Rows'Image, Timeout);
   end Send_Result;

   function SQL_State_For
     (Occurrence : Ada.Exceptions.Exception_Occurrence) return String is
      Name : constant String := Ada.Exceptions.Exception_Name (Occurrence);
   begin
      if Ada.Strings.Fixed.Index (Name, "SYNTAX_ERROR") /= 0 then return "42601";
      elsif Ada.Strings.Fixed.Index (Name, "UNDEFINED_TABLE_ERROR") /= 0 then return "42P01";
      elsif Ada.Strings.Fixed.Index (Name, "UNDEFINED_COLUMN_ERROR") /= 0 then return "42703";
      elsif Ada.Strings.Fixed.Index (Name, "UNSUPPORTED_ERROR") /= 0 then return "0A000";
      elsif Ada.Strings.Fixed.Index (Name, "RESOURCE_LIMIT_ERROR") /= 0 then return "54000";
      elsif Ada.Strings.Fixed.Index (Name, "PROTOCOL_ERROR") /= 0 then return "08P01";
      elsif Name = "CONSTRAINT_ERROR" then return "26000";
      else return "XX000";
      end if;
   end SQL_State_For;

   procedure Report_Error
     (Context    : in out Introspection_State.Server_State;
      Client     : in out Sessions.Session;
      Occurrence : Ada.Exceptions.Exception_Occurrence;
      Simple     : Boolean) is
      Message : constant String := Ada.Exceptions.Exception_Message (Occurrence);
   begin
      Sessions.Send_Error
        (Client,
         Message   => (if Message'Length = 0 then "query failed" else Message),
         SQL_State => SQL_State_For (Occurrence),
         Timeout   => Timeout);
      if Simple then
         Sessions.Send_Ready (Client, Timeout => Timeout);
      else
         State.Set_Extended_Failed (Context, True);
      end if;
   end Report_Error;

   procedure Run_SQL
     (Context       : in out Introspection_State.Server_State;
      Client        : in out Sessions.Session;
      Text          : String;
      Simple        : Boolean;
      Describe_Only : Boolean := False;
      Include_Description : Boolean := True;
      Maximum_Rows  : Natural := 0) is
      Session    : State.Session_Snapshot;
      Query      : SQL.Query;
      Result     : Catalog.Result_Set;
      Cancelled  : Boolean;
      Begun      : Boolean := False;
      Compatible : Boolean;
   begin
      if Describe_Only then
         State.Current_Session (Context, Session);
      else
         State.Begin_Query (Context, Text, Session);
         Begun := True;
      end if;
      Catalog.Psql_Compatibility (Context, Text, Compatible, Result);
      if not Compatible then
         Query := SQL.Parse (Text);
         Catalog.Execute (Context, Session, Query, Result);
      end if;
      Send_Result
        (Client,
         Result,
         Describe_Only,
         Include_Description,
         Maximum_Rows,
         Cancelled);
      if Begun then
         State.End_Query (Context);
         Begun := False;
      end if;
      if Simple then
         Sessions.Send_Ready (Client, Timeout => Timeout);
      end if;
   exception
      when Occurrence : others =>
         if Begun then State.End_Query (Context); end if;
         Report_Error (Context, Client, Occurrence, Simple);
   end Run_SQL;

   function Payload (Command : Protocol.Message) return Protocol.Byte_Array is
     (Protocol.Payload (Command));

   procedure Require_End
     (Data : Protocol.Byte_Array; Cursor : Protocol.Byte_Offset) is
   begin
      if Cursor <= Data'Last then
         raise Protocol.Protocol_Error with "unexpected extended-query payload data";
      end if;
   end Require_End;

   procedure Decode_Parse
     (Command : Protocol.Message; Name : out SQL.Name_Text;
      Text : out State.Query_Text) is
      Data : constant Protocol.Byte_Array := Payload (Command);
      Cursor : Protocol.Byte_Offset := Data'First;
      Name_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      SQL_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      Count : constant Protocol.UInt16 := Protocol.Read_U16 (Data, Cursor);
   begin
      if Count /= 0 then
         raise Catalog.Unsupported_Error with "query parameters are not supported";
      end if;
      Require_End (Data, Cursor);
      Name := SQL.Make_Text (Name_Value, SQL.Maximum_Name_Length);
      Text := SQL.Make_Text (SQL_Value, SQL.Maximum_Query_Length);
   end Decode_Parse;

   procedure Decode_Bind
     (Command : Protocol.Message; Portal, Statement : out SQL.Name_Text) is
      Data : constant Protocol.Byte_Array := Payload (Command);
      Cursor : Protocol.Byte_Offset := Data'First;
      Portal_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      Statement_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      Format_Count : constant Protocol.UInt16 := Protocol.Read_U16 (Data, Cursor);
   begin
      for Index in 1 .. Natural (Format_Count) loop
         pragma Unreferenced (Index);
         if Protocol.Read_U16 (Data, Cursor) /= 0 then
            raise Catalog.Unsupported_Error with "binary parameter formats are not supported";
         end if;
      end loop;
      if Protocol.Read_U16 (Data, Cursor) /= 0 then
         raise Catalog.Unsupported_Error with "query parameters are not supported";
      end if;
      declare
         Result_Format_Count : constant Protocol.UInt16 :=
           Protocol.Read_U16 (Data, Cursor);
      begin
         if Result_Format_Count > 1 then
            raise Catalog.Unsupported_Error with "multiple result formats are not supported";
         elsif Result_Format_Count = 1
           and then Protocol.Read_U16 (Data, Cursor) /= 0
         then
            raise Catalog.Unsupported_Error with "binary results are not supported";
         end if;
      end;
      Require_End (Data, Cursor);
      Portal := SQL.Make_Text (Portal_Value, SQL.Maximum_Name_Length);
      Statement := SQL.Make_Text (Statement_Value, SQL.Maximum_Name_Length);
   end Decode_Bind;

   procedure Decode_Named
     (Command : Protocol.Message; Portal : out Boolean; Name : out SQL.Name_Text) is
      Data : constant Protocol.Byte_Array := Payload (Command);
      Cursor : Protocol.Byte_Offset := Data'First;
      Kind : Character;
   begin
      if Cursor > Data'Last then
         raise Protocol.Protocol_Error with "missing extended object kind";
      end if;
      Kind := Character'Val (Data (Cursor));
      Cursor := Cursor + 1;
      declare
         Name_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      begin
         Require_End (Data, Cursor);
         if Kind = 'P' then Portal := True;
         elsif Kind = 'S' then Portal := False;
         else raise Protocol.Protocol_Error with "invalid extended object kind";
         end if;
         Name := SQL.Make_Text (Name_Value, SQL.Maximum_Name_Length);
      end;
   end Decode_Named;

   procedure Decode_Execute
     (Command : Protocol.Message; Portal : out SQL.Name_Text;
      Maximum_Rows : out Natural) is
      Data : constant Protocol.Byte_Array := Payload (Command);
      Cursor : Protocol.Byte_Offset := Data'First;
      Portal_Value : constant String := Protocol.Read_C_String (Data, Cursor);
      Limit : constant Protocol.UInt32 := Protocol.Read_U32 (Data, Cursor);
   begin
      Require_End (Data, Cursor);
      if Limit /= 0 then
         raise Catalog.Unsupported_Error with
           "Execute row limits and portal suspension are not supported";
      end if;
      Portal := SQL.Make_Text (Portal_Value, SQL.Maximum_Name_Length);
      Maximum_Rows := Natural (Limit);
   end Decode_Execute;

   procedure Handle
     (Context : in out Introspection_State.Server_State;
      Client  : in out Flyology.Postgres.Server_Sessions.Session;
      Command : Flyology.Postgres.Protocol.Message) is
      Kind : constant Protocol.Frontend_Kind := Protocol.Kind (Command);
   begin
      if State.Extended_Failed (Context)
        and then Kind not in Protocol.Sync | Protocol.Terminate_Command
      then
         return;
      end if;
      case Kind is
         when Protocol.Query =>
            declare
               Text : constant String := Ada.Strings.Fixed.Trim
                 (Sessions.Query_Text (Command), Ada.Strings.Both);
            begin
               if Text'Length = 0 then
                  Sessions.Send_Empty_Query_Response (Client, Timeout);
                  Sessions.Send_Ready (Client, Timeout => Timeout);
               else
                  Run_SQL (Context, Client, Text, Simple => True);
               end if;
            end;

         when Protocol.Parse =>
            declare
               Name : SQL.Name_Text;
               Text : State.Query_Text;
               Ignored : SQL.Query;
            begin
               Decode_Parse (Command, Name, Text);
               Ignored := SQL.Parse (SQL.Image (Text));
               State.Store_Statement (Context, SQL.Image (Name), SQL.Image (Text));
               Sessions.Send_Parse_Complete (Client, Timeout);
            exception
               when Occurrence : others =>
                  Report_Error (Context, Client, Occurrence, Simple => False);
            end;

         when Protocol.Bind =>
            declare
               Portal, Statement : SQL.Name_Text;
            begin
               Decode_Bind (Command, Portal, Statement);
               State.Bind_Portal
                 (Context, SQL.Image (Portal), SQL.Image (Statement));
               Sessions.Send_Bind_Complete (Client, Timeout);
            exception
               when Occurrence : others =>
                  Report_Error (Context, Client, Occurrence, Simple => False);
            end;

         when Protocol.Describe =>
            declare
               Is_Portal : Boolean;
               Name : SQL.Name_Text;
               Found : Boolean;
            begin
               Decode_Named (Command, Is_Portal, Name);
               declare
                  Text : constant String :=
                    (if Is_Portal
                     then State.Portal_SQL (Context, SQL.Image (Name), Found)
                     else State.Statement_SQL (Context, SQL.Image (Name), Found));
               begin
                  if not Found then
                     raise Constraint_Error with "unknown extended-query object";
                  end if;
                  if not Is_Portal then
                     Sessions.Send
                       (Client,
                        Protocol.Make_Message
                          ('t', (1 .. 2 => 0)),
                        Timeout);
                  end if;
                  Run_SQL
                    (Context, Client, Text, Simple => False,
                     Describe_Only => True);
               end;
            exception
               when Occurrence : others =>
                  Report_Error (Context, Client, Occurrence, Simple => False);
            end;

         when Protocol.Execute =>
            declare
               Portal : SQL.Name_Text;
               Maximum_Rows : Natural;
               Found : Boolean;
            begin
               Decode_Execute (Command, Portal, Maximum_Rows);
               declare
                  Text : constant String :=
                    State.Portal_SQL (Context, SQL.Image (Portal), Found);
               begin
                  if not Found then raise Constraint_Error with "unknown portal"; end if;
                  Run_SQL
                    (Context, Client, Text, Simple => False,
                     Include_Description => False,
                     Maximum_Rows        => Maximum_Rows);
               end;
            exception
               when Occurrence : others =>
                  Report_Error (Context, Client, Occurrence, Simple => False);
            end;

         when Protocol.Close =>
            declare
               Is_Portal : Boolean;
               Name : SQL.Name_Text;
            begin
               Decode_Named (Command, Is_Portal, Name);
               State.Close_Extended
                 (Context, Is_Portal, SQL.Image (Name));
               Sessions.Send_Close_Complete (Client, Timeout);
            exception
               when Occurrence : others =>
                  Report_Error (Context, Client, Occurrence, Simple => False);
            end;

         when Protocol.Sync =>
            State.Set_Extended_Failed (Context, False);
            Sessions.Send_Ready (Client, Timeout => Timeout);

         when Protocol.Flush => null;
         when Protocol.Terminate_Command => State.Remove_Session (Context);
         when others =>
            Sessions.Send_Error
              (Client, "unsupported frontend command", "0A000", Timeout => Timeout);
            State.Set_Extended_Failed (Context, True);
      end case;
   end Handle;

end Introspection_Handler;
