private with Util.Serialize.IO.JSON;
private with Util.Streams.Buffered;
private with Util.Streams.Texts;

package Psqlbench_JSON is

   type Writer is limited private;

   procedure Initialize
     (Item : in out Writer; Capacity : Positive := 64 * 1_024);
   procedure Start_Object (Item : in out Writer; Name : String := "");
   procedure End_Object (Item : in out Writer; Name : String := "");
   procedure Start_Array (Item : in out Writer; Name : String := "");
   procedure End_Array (Item : in out Writer; Name : String := "");
   procedure String_Value
     (Item : in out Writer; Name : String; Value : String);
   procedure Integer_Value
     (Item : in out Writer; Name : String; Value : Long_Long_Integer);
   procedure Boolean_Value
     (Item : in out Writer; Name : String; Value : Boolean);
   procedure Null_Value (Item : in out Writer; Name : String := "");
   function Finish (Item : in out Writer) return String;

   function String_Field
     (Document : String;
      Name     : String) return String;

   function Natural_Field
     (Document : String;
      Name     : String;
      Default  : Natural) return Natural;

   function Valid_Name (Value : String) return Boolean;
   function Valid_SQL_Identifier (Value : String) return Boolean;
   function Valid_Version (Value : String) return Boolean;

private
   type Writer is limited record
      Buffer : aliased Util.Streams.Buffered.Output_Buffer_Stream;
      Print  : aliased Util.Streams.Texts.Print_Stream;
      Output : Util.Serialize.IO.JSON.Output_Stream;
      Initialized : Boolean := False;
      Finished    : Boolean := False;
   end record;

end Psqlbench_JSON;
