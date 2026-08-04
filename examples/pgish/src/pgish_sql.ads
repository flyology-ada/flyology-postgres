package Pgish_SQL is

   Maximum_Query_Length : constant := 8_192;
   Maximum_Tokens       : constant := 128;
   Maximum_Projections  : constant := 16;
   Maximum_Predicates   : constant := 8;
   Maximum_Name_Length  : constant := 128;
   Maximum_Value_Length : constant := 256;
   Maximum_Result_Rows  : constant := 32;

   Syntax_Error : exception;

   type Text (Capacity : Positive) is record
      Length : Natural := 0;
      Data   : String (1 .. Capacity) := (others => ' ');
   end record;

   function Make_Text (Value : String; Capacity : Positive) return Text;
   function Image (Value : Text) return String;
   function Is_Empty (Value : Text) return Boolean;

   subtype Name_Text is Text (Maximum_Name_Length);
   subtype Value_Text is Text (Maximum_Value_Length);

   type Statement_Kind is (Select_Statement, Show_Statement);
   type Projection_Kind is
     (Column_Projection,
      Star_Projection,
      Literal_Projection,
      Function_Projection);
   type Function_Kind is
     (Current_Database_Function,
      Current_User_Function,
      Version_Function,
      Now_Function);
   type Comparison_Operator is
     (Equal_To,
      Not_Equal_To,
      Less_Than,
      Less_Or_Equal,
      Greater_Than,
      Greater_Or_Equal,
      Like_Match,
      Is_Null,
      Is_Not_Null);

   type Projection is record
      Kind       : Projection_Kind := Column_Projection;
      Name       : Name_Text;
      Literal    : Value_Text;
      Function_Id : Function_Kind := Current_Database_Function;
      Alias      : Name_Text;
   end record;
   type Projection_Array is array (Positive range <>) of Projection;

   type Predicate is record
      Column : Name_Text;
      Operator : Comparison_Operator := Equal_To;
      Value : Value_Text;
   end record;
   type Predicate_Array is array (Positive range <>) of Predicate;

   type Query is record
      Kind             : Statement_Kind := Select_Statement;
      Projections      : Projection_Array (1 .. Maximum_Projections);
      Projection_Count : Natural range 0 .. Maximum_Projections := 0;
      Table_Name       : Name_Text;
      Predicates       : Predicate_Array (1 .. Maximum_Predicates);
      Predicate_Count  : Natural range 0 .. Maximum_Predicates := 0;
      Order_Column     : Name_Text;
      Order_Descending : Boolean := False;
      Has_Limit        : Boolean := False;
      Limit            : Natural range 0 .. Maximum_Result_Rows :=
        Maximum_Result_Rows;
      Show_Name        : Name_Text;
   end record;

   function Parse (SQL : String) return Query;

end Pgish_SQL;
