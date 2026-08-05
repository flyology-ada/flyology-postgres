with Ada.Strings.Unbounded;
with System;

private package Flyology.Postgres.SQL.Backends is

   type Backend_Handle is limited private;

   procedure Start
     (Handle  : in out Backend_Handle;
      SQL     : String;
      Version : Major_Version;
      Options : Parse_Options);
   function Data (Handle : Backend_Handle) return System.Address;
   function Byte_Length (Handle : Backend_Handle) return Natural;
   function Error_Message
     (Handle : Backend_Handle) return Ada.Strings.Unbounded.Unbounded_String;
   function Error_Position (Handle : Backend_Handle) return Natural;
   procedure Release (Handle : in out Backend_Handle);

private

   type Backend_Handle is limited record
      Version : Major_Version := PostgreSQL_18;
      Value   : System.Address := System.Null_Address;
   end record;

end Flyology.Postgres.SQL.Backends;
