with Ada.Strings.Unbounded;

package Psqlbench_Assets is

   type Bundle is record
      HTML       : Ada.Strings.Unbounded.Unbounded_String;
      Stylesheet : Ada.Strings.Unbounded.Unbounded_String;
      Script     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   procedure Load (Item : out Bundle);

end Psqlbench_Assets;
