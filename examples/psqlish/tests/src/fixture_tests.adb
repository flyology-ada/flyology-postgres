with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Psqlish.Display;
with Psqlish.Options;

procedure Fixture_Tests is
   package Display renames Psqlish.Display;
   package Options renames Psqlish.Options;

   use type Options.SSL_Mode;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Contains (Text, Fragment : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Fragment) /= 0);

   View : Display.Result_State;
   Test_Limits : constant Display.Display_Limits :=
     (Buffered_Rows => 1_000,
      Result_Bytes  => 1_048_576,
      Cell_Width    => 80);
begin
   Display.Configure_Limits (View, Test_Limits);
   Display.Begin_Result
     (View,
      (Display.Make_Column ("n"),
       Display.Make_Column ("value"),
       Display.Make_Column ("empty")));
   Display.Add_Row
     (View,
      (Display.Text_Cell ("2"),
       Display.Null_Cell,
       Display.Text_Cell ("")));
   Display.Add_Row
     (View,
      (Display.Text_Cell ("100"),
       Display.Text_Cell ("alpha"),
       Display.Text_Cell ("x")));
   declare
      Output : constant String := Display.Finish_Result (View, "SELECT 2");
   begin
      Check (Contains (Output, "|   2 |"), "numeric cells must align right");
      Check (Contains (Output, "| NULL  |       |"),
             "NULL and empty strings must render differently");
      Check (Contains (Output, "(2 rows)"), "row count is missing");
      Check (Contains (Output, "SELECT 2"), "command tag is missing");
   end;

   Display.Begin_Result (View, (1 => Display.Make_Column ("payload")));
   Display.Add_Row
     (View,
      (1 => Display.Binary_Cell
         ((1 => Character'Val (0), 2 => Character'Val (16#FF#)))));
   declare
      Output : constant String := Display.Finish_Result (View, "SELECT 1");
   begin
      Check (Contains (Output, "\x00FF"), "binary value must be hex encoded");
   end;

   Display.Begin_Result (View, (1 => Display.Make_Column ("wide")));
   declare
      Wide : constant String (1 .. Test_Limits.Cell_Width + 20) :=
        (others => 'x');
   begin
      Display.Add_Row
        (View,
         (1 => Display.Text_Cell
            (Wide, Maximum_Width => Test_Limits.Cell_Width)));
   end;
   declare
      Output : constant String := Display.Finish_Result (View, "SELECT 1");
   begin
      Check (Contains (Output, "..."), "wide cell must show an ellipsis");
      Check (Contains (Output, "cells truncated"),
             "wide cell truncation must be reported");
   end;

   Display.Set_Expanded (View, True);
   Display.Set_Null_Text (View, "(null)");
   Display.Begin_Result (View, (1 => Display.Make_Column ("first")));
   Display.Add_Row (View, (1 => Display.Text_Cell ("one")));
   declare
      First : constant String := Display.Finish_Result (View, "SELECT 1");
   begin
      Check (Contains (First, "RECORD 1"), "expanded record is missing");
   end;
   Display.Begin_Result (View, (1 => Display.Make_Column ("second")));
   Display.Add_Row (View, (1 => Display.Null_Cell));
   declare
      Second : constant String := Display.Finish_Result (View, "SELECT 1");
   begin
      Check
        (Contains (Second, "(null)"),
         "display state did not survive result");
      Check
        (not Contains (Second, "first"),
         "prior result leaked into next result");
   end;

   Display.Set_Expanded (View, False);
   Display.Begin_Result (View, (1 => Display.Make_Column ("bounded")));
   for Index in 1 .. Test_Limits.Buffered_Rows + 1 loop
      Display.Add_Row (View, (1 => Display.Text_Cell (Natural'Image (Index))));
   end loop;
   declare
      Output : constant String := Display.Finish_Result (View, "SELECT 1001");
   begin
      Check (Contains (Output, "buffer limit reached"),
             "omitted buffered rows must be reported");
   end;

   declare
      Base : Options.Configuration;
      Arguments : constant Options.Argument_Array :=
        (new String'("--host=10.0.0.2"),
         new String'("--hostaddr=10.0.0.3"),
         new String'("-p"),
         new String'("6000"),
         new String'("--username"),
         new String'("alice"),
         new String'("-d"),
         new String'("app"),
         new String'("--sslmode=verify-full"),
         new String'("--sslrootcert=/tmp/test-ca.pem"),
         new String'("--command=select 1"));
      Parsed : constant Options.Configuration :=
        Options.Parse (Arguments, Base);
   begin
      Check (To_String (Parsed.Host) = "10.0.0.2", "host override failed");
      Check
        (To_String (Parsed.Host_Address) = "10.0.0.3",
         "host address override failed");
      Check (Parsed.Port = 6_000, "port override failed");
      Check (To_String (Parsed.User) = "alice", "user override failed");
      Check (To_String (Parsed.Database) = "app", "database override failed");
      Check
        (Parsed.TLS_Mode = Options.Verify_Full,
         "TLS mode override failed");
      Check
        (To_String (Parsed.SSL_Root_Cert) = "/tmp/test-ca.pem",
         "TLS root certificate override failed");
      Check
        (Parsed.Has_Command
         and then To_String (Parsed.Command) = "select 1",
         "command override failed");
   end;

   declare
      Raised : Boolean := False;
      Base : Options.Configuration;
      Arguments : constant Options.Argument_Array :=
        (1 => new String'("--sslmode=require"));
   begin
      begin
         Base := Options.Parse (Arguments, Base);
      exception
         when Options.Option_Error =>
            Raised := True;
      end;
      Check (Raised, "insecure or unsupported TLS modes must be rejected");
   end;

   declare
      Raised : Boolean := False;
      Base : Options.Configuration;
      Arguments : constant Options.Argument_Array :=
        (1 => new String'("--port=70000"));
   begin
      begin
         Base := Options.Parse (Arguments, Base);
      exception
         when Options.Option_Error =>
            Raised := True;
      end;
      Check (Raised, "invalid ports must fail option parsing");
   end;

   declare
      Base : Options.Configuration;
      Arguments : constant Options.Argument_Array :=
        (1 => new String'("--command="));
      Parsed : constant Options.Configuration :=
        Options.Parse (Arguments, Base);
   begin
      Check
        (Parsed.Has_Command and then Length (Parsed.Command) = 0,
         "an explicit empty command must remain an empty query");
   end;

   Ada.Text_IO.Put_Line ("psqlish fixture tests passed");
end Fixture_Tests;
