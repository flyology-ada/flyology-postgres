with Ada.Containers.Vectors;

package body Flyology.Postgres.SQL.Native.LALR is

   use type Builders.Dynamic_Value;

   package State_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Integer);
   package Semantic_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Builders.Dynamic_Value);
   package Location_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Integer);

   procedure Parse is
      States          : State_Vectors.Vector;
      Values          : Semantic_Vectors.Vector;
      Locations       : Location_Vectors.Vector;
      External_Token  : Integer := -1;
      Internal_Token  : Integer := 0;
      Lookahead_Value : Builders.Dynamic_Value;
      Lookahead_Loc   : Integer := 0;
      State           : Integer := 0;

      procedure Read_Lookahead is
      begin
         if External_Token < 0 then
            Next_Token (External_Token, Lookahead_Value, Lookahead_Loc);
            if External_Token >= 0 and then External_Token <= Maximum_Token then
               Internal_Token := Translate (External_Token);
            else
               Internal_Token := 2;
            end if;
         end if;
      end Read_Lookahead;

      procedure Perform_Reduction (Rule : Positive) is
         Count       : constant Natural := Natural (Rule_Length (Rule));
         First       : constant Integer := Integer (Values.Last_Index) - Count + 1;
         RHS_Values  : Builders.Semantic_Array (1 .. Integer (Count));
         RHS_Locs    : Builders.Location_Array (1 .. Integer (Count));
         Result      : Builders.Dynamic_Value :=
           (if Count = 0 then Builders.No_Value
            else Values.Element (Natural (First)));
         Result_Loc  : Integer := -1;
      begin
         for Index in 1 .. Integer (Count) loop
            RHS_Values (Index) := Values.Element (Natural (First + Index - 1));
            RHS_Locs (Index) := Locations.Element (Natural (First + Index - 1));
            if Result_Loc < 0 and then RHS_Locs (Index) >= 0 then
               Result_Loc := RHS_Locs (Index);
            end if;
         end loop;
         Reduce (Rule, RHS_Values, RHS_Locs, Result, Result_Loc);

         for Index in 1 .. Count loop
            pragma Unreferenced (Index);
            States.Delete_Last;
            Values.Delete_Last;
            Locations.Delete_Last;
         end loop;

         declare
            Previous : constant Integer := States.Last_Element;
            Symbol   : constant Integer := Rule_Left (Rule);
            Candidate : constant Integer :=
              Goto_Offset (Symbol - Terminal_Count) + Previous;
         begin
            if Candidate >= 0
              and then Candidate <= Last_Table_Index
              and then Action_Check (Candidate) = Previous
            then
               State := Action_Table (Candidate);
            else
               State := Default_Goto (Symbol - Terminal_Count);
            end if;
         end;
         States.Append (State);
         Values.Append (Result);
         Locations.Append (Result_Loc);
      end Perform_Reduction;

   begin
      States.Append (0);
      Values.Append (Builders.No_Value);
      Locations.Append (-1);

      loop
         State := States.Last_Element;
         declare
            Offset : constant Integer := Action_Offset (State);
         begin
            if Offset = Pact_Default then
               declare
                  Rule : constant Integer := Default_Action (State);
               begin
                  if Rule = 0 then
                     Read_Lookahead;
                     Syntax_Error (Lookahead_Loc, External_Token);
                     return;
                  end if;
                  Perform_Reduction (Positive (Rule));
               end;
            else
               Read_Lookahead;
               declare
                  Index : constant Integer := Offset + Internal_Token;
               begin
                  if Index < 0
                    or else Index > Last_Table_Index
                    or else Action_Check (Index) /= Internal_Token
                  then
                     declare
                        Rule : constant Integer := Default_Action (State);
                     begin
                        if Rule = 0 then
                           Syntax_Error (Lookahead_Loc, External_Token);
                           return;
                        end if;
                        Perform_Reduction (Positive (Rule));
                     end;
                  else
                     declare
                        Action : constant Integer := Action_Table (Index);
                     begin
                        if Action = Final_State then
                           return;
                        elsif Action > 0 then
                           State := Action;
                           States.Append (State);
                           Values.Append (Lookahead_Value);
                           Locations.Append (Lookahead_Loc);
                           External_Token := -1;
                        elsif Action < 0 and then Action /= Table_Error then
                           Perform_Reduction (Positive (-Action));
                        else
                           Syntax_Error (Lookahead_Loc, External_Token);
                           return;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Parse;

end Flyology.Postgres.SQL.Native.LALR;
