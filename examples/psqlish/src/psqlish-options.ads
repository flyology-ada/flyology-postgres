with Ada.Strings.Unbounded;

package Psqlish.Options is

   type Configuration is record
      Host     : Ada.Strings.Unbounded.Unbounded_String;
      Port     : Positive := 55_432;
      User     : Ada.Strings.Unbounded.Unbounded_String;
      Database : Ada.Strings.Unbounded.Unbounded_String;
      Password : Ada.Strings.Unbounded.Unbounded_String;
      Command  : Ada.Strings.Unbounded.Unbounded_String;
      Has_Command : Boolean := False;
      Show_Help    : Boolean := False;
      Show_Version : Boolean := False;
   end record;

   Option_Error : exception;

   function Defaults return Configuration;
   function Parse return Configuration;

   --  Exposed for deterministic fixtures. Arguments use the same spelling as
   --  the command line and override Base from left to right.
   type String_Access is access constant String;
   type Argument_Array is array (Positive range <>) of String_Access;
   function Parse
     (Arguments : Argument_Array;
      Base      : Configuration) return Configuration;

   function Help return String;

end Psqlish.Options;
