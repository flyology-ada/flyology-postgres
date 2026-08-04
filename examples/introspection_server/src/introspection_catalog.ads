with Introspection_SQL;
with Introspection_State;

package Introspection_Catalog is

   Undefined_Table_Error  : exception;
   Undefined_Column_Error : exception;
   Unsupported_Error      : exception;
   Resource_Limit_Error   : exception;

   Maximum_Columns : constant := Introspection_SQL.Maximum_Projections;
   Maximum_Rows    : constant := Introspection_SQL.Maximum_Result_Rows;

   type Column_Definition is record
      Name      : Introspection_SQL.Name_Text;
      Type_Oid  : Natural := 25;
      Type_Size : Integer := -1;
   end record;
   type Column_Array is
     array (Positive range 1 .. Maximum_Columns) of Column_Definition;

   type Cell is record
      Is_Null : Boolean := True;
      Value   : Introspection_SQL.Value_Text;
   end record;
   type Cell_Array is array (Positive range 1 .. Maximum_Columns) of Cell;

   type Result_Row is record
      Values : Cell_Array;
   end record;
   type Row_Array is array (Positive range 1 .. Maximum_Rows) of Result_Row;

   type Result_Set is record
      Columns      : Column_Array;
      Column_Count : Natural range 0 .. Maximum_Columns := 0;
      Rows         : Row_Array;
      Row_Count    : Natural range 0 .. Maximum_Rows := 0;
   end record;

   procedure Execute
     (State   : in out Introspection_State.Server_State;
      Session : Introspection_State.Session_Snapshot;
      Query   : Introspection_SQL.Query;
      Result  : out Result_Set);

   procedure Psql_Compatibility
     (Context  : in out Introspection_State.Server_State;
      SQL_Text : String;
      Matched  : out Boolean;
      Result   : out Result_Set);

end Introspection_Catalog;
