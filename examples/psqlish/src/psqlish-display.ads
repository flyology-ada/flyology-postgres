with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Psqlish.Display is

   type Display_Limits is record
      Buffered_Rows : Positive;
      Result_Bytes  : Positive;
      Cell_Width    : Positive;
   end record;

   Unbounded_Limits : constant Display_Limits :=
     (Buffered_Rows => Positive'Last,
      Result_Bytes  => Positive'Last,
      Cell_Width    => Positive'Last);

   type Cell is private;
   function Text_Cell
     (Value : String; Maximum_Width : Positive := Positive'Last) return Cell;
   function Binary_Cell
     (Value : String; Maximum_Width : Positive := Positive'Last) return Cell;
   function Null_Cell return Cell;

   type Cell_Array is array (Positive range <>) of Cell;

   type Column is private;
   function Make_Column
     (Name          : String;
      Binary        : Boolean := False;
      Maximum_Width : Positive := Positive'Last) return Column;
   type Column_Array is array (Positive range <>) of Column;

   type Result_State is tagged private;
   procedure Configure_Limits
     (Item : in out Result_State; Limits : Display_Limits);
   procedure Set_Expanded (Item : in out Result_State; Enabled : Boolean);
   function Expanded (Item : Result_State) return Boolean;
   procedure Set_Null_Text (Item : in out Result_State; Value : String);
   function Null_Text (Item : Result_State) return String;

   procedure Begin_Result
     (Item : in out Result_State; Columns : Column_Array);
   function Try_Add_Row
     (Item : in out Result_State; Values : Cell_Array) return Boolean;
   --  False means the configured row/byte batch is full. Item is unchanged,
   --  so a streaming caller can render it, begin another batch, and retry.
   procedure Add_Row (Item : in out Result_State; Values : Cell_Array);

   --  Return a complete rendering and reset only the active result. Display
   --  preferences survive, which lets one state process multiple result sets.
   function Finish_Result
     (Item        : in out Result_State;
      Command_Tag : String := "";
      Empty_Query : Boolean := False) return String;

private
   use Ada.Strings.Unbounded;

   type Cell is record
      Null_Value : Boolean := True;
      Binary     : Boolean := False;
      Value      : Unbounded_String;
      Truncated  : Boolean := False;
   end record;

   type Column is record
      Name   : Unbounded_String;
      Binary : Boolean := False;
   end record;

   package Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column);
   package Cell_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Cell);

   type Row is record
      Values : Cell_Vectors.Vector;
   end record;
   package Row_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Row);

   type Result_State is tagged record
      Columns         : Column_Vectors.Vector;
      Rows            : Row_Vectors.Vector;
      Total_Rows      : Natural := 0;
      Buffered_Bytes  : Natural := 0;
      Omitted_Rows    : Natural := 0;
      Truncated_Cells : Natural := 0;
      Limits          : Display_Limits := Unbounded_Limits;
      Is_Expanded     : Boolean := False;
      Null_Value      : Unbounded_String := To_Unbounded_String ("NULL");
   end record;

end Psqlish.Display;
