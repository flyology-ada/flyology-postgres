with Interfaces.C;
with Interfaces.C.Strings;

package body Flyology.Postgres.SQL.Backends is

   use Interfaces.C;
   use Interfaces.C.Strings;
   use type System.Address;

   function PG14_Parse (Input : chars_ptr; Options : int) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg14_parse";
   function PG14_Data (Handle : System.Address) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg14_data";
   function PG14_Length (Handle : System.Address) return size_t
     with Import, Convention => C, External_Name => "flyology_pg14_length";
   function PG14_Error (Handle : System.Address) return chars_ptr
     with Import, Convention => C, External_Name => "flyology_pg14_error";
   function PG14_Error_Position (Handle : System.Address) return int
     with Import, Convention => C, External_Name => "flyology_pg14_error_position";
   procedure PG14_Free (Handle : System.Address)
     with Import, Convention => C, External_Name => "flyology_pg14_free";

   function PG15_Parse (Input : chars_ptr; Options : int) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg15_parse";
   function PG15_Data (Handle : System.Address) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg15_data";
   function PG15_Length (Handle : System.Address) return size_t
     with Import, Convention => C, External_Name => "flyology_pg15_length";
   function PG15_Error (Handle : System.Address) return chars_ptr
     with Import, Convention => C, External_Name => "flyology_pg15_error";
   function PG15_Error_Position (Handle : System.Address) return int
     with Import, Convention => C, External_Name => "flyology_pg15_error_position";
   procedure PG15_Free (Handle : System.Address)
     with Import, Convention => C, External_Name => "flyology_pg15_free";

   function PG16_Parse (Input : chars_ptr; Options : int) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg16_parse";
   function PG16_Data (Handle : System.Address) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg16_data";
   function PG16_Length (Handle : System.Address) return size_t
     with Import, Convention => C, External_Name => "flyology_pg16_length";
   function PG16_Error (Handle : System.Address) return chars_ptr
     with Import, Convention => C, External_Name => "flyology_pg16_error";
   function PG16_Error_Position (Handle : System.Address) return int
     with Import, Convention => C, External_Name => "flyology_pg16_error_position";
   procedure PG16_Free (Handle : System.Address)
     with Import, Convention => C, External_Name => "flyology_pg16_free";

   function PG17_Parse (Input : chars_ptr; Options : int) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg17_parse";
   function PG17_Data (Handle : System.Address) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg17_data";
   function PG17_Length (Handle : System.Address) return size_t
     with Import, Convention => C, External_Name => "flyology_pg17_length";
   function PG17_Error (Handle : System.Address) return chars_ptr
     with Import, Convention => C, External_Name => "flyology_pg17_error";
   function PG17_Error_Position (Handle : System.Address) return int
     with Import, Convention => C, External_Name => "flyology_pg17_error_position";
   procedure PG17_Free (Handle : System.Address)
     with Import, Convention => C, External_Name => "flyology_pg17_free";

   function PG18_Parse (Input : chars_ptr; Options : int) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg18_parse";
   function PG18_Data (Handle : System.Address) return System.Address
     with Import, Convention => C, External_Name => "flyology_pg18_data";
   function PG18_Length (Handle : System.Address) return size_t
     with Import, Convention => C, External_Name => "flyology_pg18_length";
   function PG18_Error (Handle : System.Address) return chars_ptr
     with Import, Convention => C, External_Name => "flyology_pg18_error";
   function PG18_Error_Position (Handle : System.Address) return int
     with Import, Convention => C, External_Name => "flyology_pg18_error_position";
   procedure PG18_Free (Handle : System.Address)
     with Import, Convention => C, External_Name => "flyology_pg18_free";

   function Backend_Parse
     (Version : Major_Version; Input : chars_ptr; Options : int) return System.Address is
     (case Version is
         when PostgreSQL_14 => PG14_Parse (Input, Options),
         when PostgreSQL_15 => PG15_Parse (Input, Options),
         when PostgreSQL_16 => PG16_Parse (Input, Options),
         when PostgreSQL_17 => PG17_Parse (Input, Options),
         when PostgreSQL_18 => PG18_Parse (Input, Options));

   function Option_Bits (Options : Parse_Options) return int is
      Result : int := Parse_Mode'Pos (Options.Mode);
   begin
      if not Options.Backslash_Quote then Result := Result + 16; end if;
      if not Options.Standard_Conforming_Strings then Result := Result + 32; end if;
      if not Options.Escape_String_Warning then Result := Result + 64; end if;
      return Result;
   end Option_Bits;

   procedure Start
     (Handle  : in out Backend_Handle;
      SQL     : String;
      Version : Major_Version;
      Options : Parse_Options)
   is
      Input : chars_ptr := Null_Ptr;
   begin
      if Handle.Value /= System.Null_Address then
         raise Program_Error with "PostgreSQL backend handle is already active";
      end if;
      if not Supports_Parse_Options (Version) and then Options /= Default_Options then
         raise Unsupported_Parse_Options with
           "PostgreSQL 14's extracted parser supports only Default_Options";
      end if;
      Input := New_String (SQL);
      Handle.Version := Version;
      Handle.Value := Backend_Parse (Version, Input, Option_Bits (Options));
      Free (Input);
      Input := Null_Ptr;
      if Handle.Value = System.Null_Address then
         raise Storage_Error with "PostgreSQL parser result allocation failed";
      end if;
   exception
      when others =>
         if Input /= Null_Ptr then Free (Input); end if;
         raise;
   end Start;

   function Data (Handle : Backend_Handle) return System.Address is
     (case Handle.Version is
         when PostgreSQL_14 => PG14_Data (Handle.Value),
         when PostgreSQL_15 => PG15_Data (Handle.Value),
         when PostgreSQL_16 => PG16_Data (Handle.Value),
         when PostgreSQL_17 => PG17_Data (Handle.Value),
         when PostgreSQL_18 => PG18_Data (Handle.Value));

   function Raw_Length (Handle : Backend_Handle) return size_t is
     (case Handle.Version is
         when PostgreSQL_14 => PG14_Length (Handle.Value),
         when PostgreSQL_15 => PG15_Length (Handle.Value),
         when PostgreSQL_16 => PG16_Length (Handle.Value),
         when PostgreSQL_17 => PG17_Length (Handle.Value),
         when PostgreSQL_18 => PG18_Length (Handle.Value));

   function Byte_Length (Handle : Backend_Handle) return Natural is
      Value : constant size_t := Raw_Length (Handle);
   begin
      if Value > size_t (Natural'Last) then
         raise Parser_Backend_Error with "protobuf result is too large for this Ada runtime";
      end if;
      return Natural (Value);
   end Byte_Length;

   function Raw_Error (Handle : Backend_Handle) return chars_ptr is
     (case Handle.Version is
         when PostgreSQL_14 => PG14_Error (Handle.Value),
         when PostgreSQL_15 => PG15_Error (Handle.Value),
         when PostgreSQL_16 => PG16_Error (Handle.Value),
         when PostgreSQL_17 => PG17_Error (Handle.Value),
         when PostgreSQL_18 => PG18_Error (Handle.Value));

   function Error_Message (Handle : Backend_Handle) return Unbounded_String is
      Pointer : constant chars_ptr := Raw_Error (Handle);
   begin
      return (if Pointer = Null_Ptr then Null_Unbounded_String
              else To_Unbounded_String (Value (Pointer)));
   end Error_Message;

   function Raw_Error_Position (Handle : Backend_Handle) return int is
     (case Handle.Version is
         when PostgreSQL_14 => PG14_Error_Position (Handle.Value),
         when PostgreSQL_15 => PG15_Error_Position (Handle.Value),
         when PostgreSQL_16 => PG16_Error_Position (Handle.Value),
         when PostgreSQL_17 => PG17_Error_Position (Handle.Value),
         when PostgreSQL_18 => PG18_Error_Position (Handle.Value));

   function Error_Position (Handle : Backend_Handle) return Natural is
      Position : constant int := Raw_Error_Position (Handle);
   begin
      return (if Position > 0 then Natural (Position) else 0);
   end Error_Position;

   procedure Release (Handle : in out Backend_Handle) is
   begin
      if Handle.Value = System.Null_Address then return; end if;
      case Handle.Version is
         when PostgreSQL_14 => PG14_Free (Handle.Value);
         when PostgreSQL_15 => PG15_Free (Handle.Value);
         when PostgreSQL_16 => PG16_Free (Handle.Value);
         when PostgreSQL_17 => PG17_Free (Handle.Value);
         when PostgreSQL_18 => PG18_Free (Handle.Value);
      end case;
      Handle.Value := System.Null_Address;
   end Release;

end Flyology.Postgres.SQL.Backends;
