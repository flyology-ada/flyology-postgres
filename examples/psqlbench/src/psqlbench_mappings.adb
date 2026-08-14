with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed;
with Psqlbench_JSON;

package body Psqlbench_Mappings is

   function Source_Name (Rule : Mapping_Rule) return String is
     (if Rule.Source_Length = 0 then ""
      else Rule.Source (1 .. Rule.Source_Length));

   function Target_Name (Rule : Mapping_Rule) return String is
     (if Rule.Target_Length = 0 then ""
      else Rule.Target (1 .. Rule.Target_Length));

   function Target_Type (Rule : Mapping_Rule) return String is
     (if Rule.Type_Length = 0 then ""
      else Rule.Target_Type (1 .. Rule.Type_Length));

   procedure Store
     (Target : out String; Length : out Natural; Value : String) is
   begin
      if Value'Length > Target'Length then
         raise Constraint_Error with "mapping component is too long";
      end if;
      Target := (others => ' ');
      Length := Value'Length;
      if Length > 0 then
         Target (Target'First .. Target'First + Length - 1) := Value;
      end if;
   end Store;

   function Valid_Target_Type (Value : String) return Boolean is
      Depth : Natural := 0;
      Brackets : Natural := 0;
   begin
      if Value'Length not in 1 .. Max_Type_Bytes
        or else Value (Value'First) not in 'a' .. 'z' | '_'
      then
         return False;
      end if;
      for Character of Value loop
         if Character in 'a' .. 'z' | '0' .. '9' | '_' | ' ' | ',' | '.' then
            null;
         elsif Character = '(' then
            Depth := Depth + 1;
         elsif Character = ')' then
            if Depth = 0 then
               return False;
            end if;
            Depth := Depth - 1;
         elsif Character = '[' then
            Brackets := Brackets + 1;
         elsif Character = ']' then
            if Brackets = 0 then
               return False;
            end if;
            Brackets := Brackets - 1;
         else
            return False;
         end if;
      end loop;
      return Depth = 0 and then Brackets = 0;
   end Valid_Target_Type;

   procedure Parse
     (Value : String; Rules : out Mapping_Array; Count : out Natural)
   is
      First : Integer := Value'First;

      procedure Parse_Line (Raw : String) is
         Line : constant String := Ada.Strings.Fixed.Trim (Raw, Both);
         Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
         Cast : constant Natural := Ada.Strings.Fixed.Index (Line, "::");
      begin
         if Line'Length = 0 or else Line (Line'First) = '#' then
            return;
         elsif Arrow = 0 or else Arrow = Line'First
           or else Arrow + 2 > Line'Last
         then
            raise Constraint_Error with
              "mapping rules use source -> target [:: target_type]";
         elsif Ada.Strings.Fixed.Index
           (Line (Arrow + 2 .. Line'Last), "->") > 0
         then
            raise Constraint_Error with "mapping rule has more than one arrow";
         elsif Cast > 0
           and then
             (Cast <= Arrow + 2
              or else Ada.Strings.Fixed.Index
                (Line (Cast + 2 .. Line'Last), "::") > 0)
         then
            raise Constraint_Error with "mapping rule has an invalid cast";
         end if;
         declare
            Source : constant String := Ada.Strings.Fixed.Trim
              (Line (Line'First .. Arrow - 1), Both);
            Target_Last : constant Natural :=
              (if Cast = 0 then Line'Last else Cast - 1);
            Target : constant String := Ada.Strings.Fixed.Trim
              (Line (Arrow + 2 .. Target_Last), Both);
            Type_Name : constant String :=
              (if Cast = 0 then ""
               else Ada.Strings.Fixed.Trim
                 (Line (Cast + 2 .. Line'Last), Both));
         begin
            if not Psqlbench_JSON.Valid_SQL_Identifier (Source)
              or else not Psqlbench_JSON.Valid_SQL_Identifier (Target)
            then
               raise Constraint_Error with
                 "mapped columns use lowercase SQL identifiers";
            elsif Cast > 0 and then not Valid_Target_Type (Type_Name) then
               raise Constraint_Error with
                 "target casts use a safe lowercase SQL type expression";
            elsif Count = Max_Columns then
               raise Constraint_Error with "column mapping capacity is 64";
            end if;
            for Index in 1 .. Count loop
               if Source_Name (Rules (Index)) = Source then
                  raise Constraint_Error with
                    "source column is mapped more than once: " & Source;
               elsif Target_Name (Rules (Index)) = Target then
                  raise Constraint_Error with
                    "target column is mapped more than once: " & Target;
               end if;
            end loop;
            Count := Count + 1;
            Store
              (Rules (Count).Source, Rules (Count).Source_Length, Source);
            Store
              (Rules (Count).Target, Rules (Count).Target_Length, Target);
            Store
              (Rules (Count).Target_Type,
               Rules (Count).Type_Length, Type_Name);
         end;
      end Parse_Line;
   begin
      Rules := (others => <>);
      Count := 0;
      if Value'Length = 0 then
         return;
      end if;
      for Index in Value'Range loop
         if Value (Index) = ASCII.LF then
            if Index > First then
               Parse_Line (Value (First .. Index - 1));
            end if;
            First := Index + 1;
         end if;
      end loop;
      if First <= Value'Last then
         Parse_Line (Value (First .. Value'Last));
      end if;
      if Count = 0 then
         raise Constraint_Error with "column mapping contains no rules";
      end if;
   end Parse;

end Psqlbench_Mappings;
