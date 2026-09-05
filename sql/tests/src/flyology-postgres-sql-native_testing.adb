with AUnit.Assertions; use AUnit.Assertions;
with Interfaces;
with Ada.Strings.Unbounded;

with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.Actions_V18;
with Flyology.Postgres.SQL.Native.DFA;
with Flyology.Postgres.SQL.Native.Generated_V18;
with Flyology.Postgres.SQL.Native.Scanner;
with Flyology.Postgres.SQL.Native.Semantics;
with Flyology.Postgres.SQL.Native.Version_V18;
with Flyology.Postgres.SQL.Native.Version_V14;
with Flyology.Postgres.SQL.Native.Version_V15;
with Flyology.Postgres.SQL.Native.Version_V16;
with Flyology.Postgres.SQL.Native.Version_V17;

package body Flyology.Postgres.SQL.Native_Testing is

   use type Interfaces.Integer_64;
   use type Native.Builders.Value_Kind;

   package V18_DFA is new Native.DFA
     (Transitions => Native.Generated_V18.Scanner_Transitions,
      Starts      => Native.Generated_V18.Scanner_Starts);

   package V18_Scanner is new Native.Scanner
     (Lexical_DFA       => V18_DFA,
      Actions           => Native.Generated_V18.Scanner_Actions,
      Keywords          => Native.Generated_V18.Keywords,
      Profile           => Native.Generated_V18.Profile,
      Token_Ident       => Native.Generated_V18.Token_Ident,
      Token_Uident      => Native.Generated_V18.Token_Uident,
      Token_Fconst      => Native.Generated_V18.Token_Fconst,
      Token_Sconst      => Native.Generated_V18.Token_Sconst,
      Token_Usconst     => Native.Generated_V18.Token_Usconst,
      Token_Bconst      => Native.Generated_V18.Token_Bconst,
      Token_Xconst      => Native.Generated_V18.Token_Xconst,
      Token_Op          => Native.Generated_V18.Token_Op,
      Token_Iconst      => Native.Generated_V18.Token_Iconst,
      Token_Param       => Native.Generated_V18.Token_Param,
      Token_Sql_Comment => Native.Generated_V18.Token_Sql_Comment,
      Token_C_Comment   => Native.Generated_V18.Token_C_Comment,
      Token_Format      => Native.Generated_V18.Token_Format,
      Token_Format_La   => Native.Generated_V18.Token_Format_La,
      Token_Json        => Native.Generated_V18.Token_Json,
      Token_Not         => Native.Generated_V18.Token_Not,
      Token_Not_La      => Native.Generated_V18.Token_Not_La,
      Token_Between     => Native.Generated_V18.Token_Between,
      Token_In          => Native.Generated_V18.Token_In_P,
      Token_Like        => Native.Generated_V18.Token_Like,
      Token_Ilike       => Native.Generated_V18.Token_Ilike,
      Token_Similar     => Native.Generated_V18.Token_Similar,
      Token_Nulls       => Native.Generated_V18.Token_Nulls_P,
      Token_Nulls_La    => Native.Generated_V18.Token_Nulls_La,
      Token_First       => Native.Generated_V18.Token_First_P,
      Token_Last        => Native.Generated_V18.Token_Last_P,
      Token_With        => Native.Generated_V18.Token_With,
      Token_With_La     => Native.Generated_V18.Token_With_La,
      Token_Without     => Native.Generated_V18.Token_Without,
      Token_Without_La  => Native.Generated_V18.Token_Without_La,
      Token_Time        => Native.Generated_V18.Token_Time,
      Token_Ordinality  => Native.Generated_V18.Token_Ordinality,
      Token_Uescape     => Native.Generated_V18.Token_Uescape);

   procedure Run is
      Build  : aliased Native.Builders.Builder;
      Object : constant Native.Builders.Dynamic_Value :=
        Build.New_Object ("SelectStmt");
      Items  : Native.Builders.Dynamic_Value := Build.New_List;
      String_Node : Native.Builders.Dynamic_Value;
      Reduction_Values : constant Native.Builders.Semantic_Array (1 .. 1) :=
        (1 => Native.Builders.Text ("identifier"));
      Reduction_Locations : constant Native.Builders.Location_Array (1 .. 1) :=
        (1 => 0);
      Reduction_Result : Native.Builders.Dynamic_Value := Native.Builders.No_Value;
      Reduction_Location : Integer := 0;
      Error_Location : aliased Integer := -1;
      Parse_Result : Native.Builders.Dynamic_Value := Native.Builders.No_Value;
      Scan   : V18_DFA.Scanner;
      Action : Positive;
      First  : Natural;
      Last   : Natural;
      Done   : Boolean;
      Lexer  : V18_Scanner.Lexer;
      Token  : Integer;
      Lexeme : Native.Builders.Dynamic_Value;
      Token_Location : Integer;
      Native_Root : Native.Builders.Dynamic_Value;
      Error_Offset : Natural;
      Error_Message : Ada.Strings.Unbounded.Unbounded_String;
      Parse_Success : Boolean;
   begin
      Build.Set_Field (Object, "location", Native.Builders.Number (12));
      Assert
        (Build.Field (Object, "location").Integer_Data = 12,
         "native semantic objects retain mutable fields");
      Items := Build.Append (Items, Object);
      Assert
        (Build.Length (Items) = 1
         and then Build.Element (Items, 1).Object_Data = Object.Object_Data,
         "native semantic lists retain ordered references");
      String_Node := Native.Semantics.Invoke
        (Build'Access, "makeString", (1 => Native.Builders.Text ("value")));
      Assert
        (Build.Object_Type (String_Node) = "String",
         "generated semantic helper dispatch constructs typed nodes");
      Native.Actions_V18.Reduce
        (Build, 137, Reduction_Values, Reduction_Locations,
         Reduction_Result, Reduction_Location, Error_Location'Access,
         Parse_Result);
      Assert
        (Native.Semantics.Text_Of (Reduction_Result) = "identifier",
         "generated reduction actions preserve semantic values");

      Scan.Initialize ("select");
      Scan.Match (Action, First, Last, Done);
      Assert
        (not Done and then First = 0 and then Last = 6
         and then Scan.Slice (First, Last) = "select",
         "generated Flex DFA recognizes the longest token");

      Lexer.Initialize
        ("SELECT ""MiXeD"", E'line\n' -- comment" & ASCII.LF & "FROM t");
      Lexer.Next_Token (Token, Lexeme, Token_Location);
      Assert
        (Token = Native.Generated_V18.Token_Select,
         "native scanner recognizes generated keyword tokens");
      Lexer.Next_Token (Token, Lexeme, Token_Location);
      Assert
        (Token = Native.Generated_V18.Token_Ident
         and then Native.Semantics.Text_Of (Lexeme) = "MiXeD",
         "native scanner preserves quoted identifier spelling");

      Native.Version_V18.Parse
        ("SELECT 1", Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success
         and then Native_Root.Kind = Native.Builders.List_Value
         and then Build.Length (Native_Root) = 1,
         "native LALR parser produces the PostgreSQL raw statement list");

      Native.Version_V14.Parse
        ("SELECT 1", Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success and then Native_Root.Kind = Native.Builders.List_Value,
         "PostgreSQL 14 native parser accepts a basic SELECT");
      Native.Version_V15.Parse
        ("SELECT 1", Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success and then Native_Root.Kind = Native.Builders.List_Value,
         "PostgreSQL 15 native parser accepts a basic SELECT");
      Native.Version_V16.Parse
        ("SELECT 1", Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success and then Native_Root.Kind = Native.Builders.List_Value,
         "PostgreSQL 16 native parser accepts a basic SELECT");
      Native.Version_V17.Parse
        ("SELECT 1", Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success and then Native_Root.Kind = Native.Builders.List_Value,
         "PostgreSQL 17 native parser accepts a basic SELECT");

      Native.Version_V18.Parse
        ("WITH x AS (SELECT a FROM t1 JOIN t2 ON t1.id = t2.id) " &
         "SELECT a + 1 FROM x WHERE a > 0",
         Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success,
         "native parser accepts representative CTE, join, and expression SQL");
      Native.Version_V18.Parse
        ("CREATE TABLE example (id bigint PRIMARY KEY, name text NOT NULL)",
         Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert (Parse_Success, "native parser accepts representative DDL");
      Native.Version_V18.Parse
        ("EXPLAIN (ANALYZE false) SELECT * FROM example",
         Default_Options, Build, Native_Root, Error_Offset,
         Error_Message, Parse_Success);
      Assert
        (Parse_Success, "native parser accepts representative utility SQL");
   end Run;

end Flyology.Postgres.SQL.Native_Testing;
