with Util.Properties;
with Util.Properties.JSON;
with Util.Serialize.IO.JSON;
with Util.Streams.Texts;

package body Psqlbench_JSON is

   procedure Initialize
     (Item : in out Writer; Capacity : Positive := 64 * 1_024) is
   begin
      Item.Buffer.Initialize (Size => Capacity);
      Item.Print.Initialize (Item.Buffer'Unchecked_Access);
      Item.Output.Initialize (Item.Print'Unchecked_Access);
      Item.Initialized := True;
      Item.Finished := False;
   end Initialize;

   procedure Require_Open (Item : Writer) is
   begin
      if not Item.Initialized or else Item.Finished then
         raise Program_Error with "JSON writer is not open";
      end if;
   end Require_Open;

   procedure Start_Object (Item : in out Writer; Name : String := "") is
   begin
      Require_Open (Item);
      Item.Output.Start_Entity (Name);
   end Start_Object;

   procedure End_Object (Item : in out Writer; Name : String := "") is
   begin
      Require_Open (Item);
      Item.Output.End_Entity (Name);
   end End_Object;

   procedure Start_Array (Item : in out Writer; Name : String := "") is
   begin
      Require_Open (Item);
      Item.Output.Start_Array (Name);
   end Start_Array;

   procedure End_Array (Item : in out Writer; Name : String := "") is
   begin
      Require_Open (Item);
      Item.Output.End_Array (Name);
   end End_Array;

   procedure String_Value
     (Item : in out Writer; Name : String; Value : String) is
   begin
      Require_Open (Item);
      Item.Output.Write_Entity (Name, Value);
   end String_Value;

   procedure Integer_Value
     (Item : in out Writer; Name : String; Value : Long_Long_Integer) is
   begin
      Require_Open (Item);
      Item.Output.Write_Long_Entity (Name, Value);
   end Integer_Value;

   procedure Boolean_Value
     (Item : in out Writer; Name : String; Value : Boolean) is
   begin
      Require_Open (Item);
      Item.Output.Write_Entity (Name, Value);
   end Boolean_Value;

   procedure Null_Value (Item : in out Writer; Name : String := "") is
   begin
      Require_Open (Item);
      Item.Output.Write_Null_Entity (Name);
   end Null_Value;

   function Finish (Item : in out Writer) return String is
   begin
      Require_Open (Item);
      Item.Output.Flush;
      Item.Finished := True;
      return Util.Streams.Texts.To_String (Item.Buffer);
   end Finish;

   function Properties (Document : String) return Util.Properties.Manager is
      Result : Util.Properties.Manager;
   begin
      Util.Properties.JSON.Parse_JSON (Result, Document);
      return Result;
   end Properties;

   function String_Field
     (Document : String;
      Name     : String) return String
   is
      Values : constant Util.Properties.Manager := Properties (Document);
   begin
      return Values.Get (Name, "");
   end String_Field;

   function Natural_Field
     (Document : String;
      Name     : String;
      Default  : Natural) return Natural
   is
      Values : constant Util.Properties.Manager := Properties (Document);
   begin
      if not Values.Exists (Name) then
         return Default;
      end if;
      return Natural'Value (Values.Get (Name));
   end Natural_Field;

   function Valid_Name (Value : String) return Boolean is
   begin
      if Value'Length not in 1 .. 40
        or else Value (Value'First) not in 'a' .. 'z'
      then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z' | '0' .. '9' | '-' then
            return False;
         end if;
      end loop;
      return Value (Value'Last) /= '-';
   end Valid_Name;

   function Valid_Version (Value : String) return Boolean is
     (Value in "14.23" | "15.18" | "16.14" | "17.10" | "18.4");

end Psqlbench_JSON;
