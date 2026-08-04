package Psqlish.Input is

   procedure Initialize;

   function Get_Line (Prompt : String) return String;

   procedure Save_History;

end Psqlish.Input;
