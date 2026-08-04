with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with HMAC_SHA256;
with System_Random;
with System.Storage_Elements;

package body Flyology.Postgres.SCRAM is

   use type System.Storage_Elements.Storage_Offset;

   package Random_Bytes is new System_Random
     (Element       => Ada.Streams.Stream_Element,
      Index         => Ada.Streams.Stream_Element_Offset,
      Element_Array => Ada.Streams.Stream_Element_Array);

   Base64_Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   procedure Fail (Reason : String) is
   begin
      raise SCRAM_Error with Reason;
   end Fail;

   function To_Bytes (Value : String) return Byte_Array is
      Result : Byte_Array (1 .. Value'Length);
      Cursor : System.Storage_Elements.Storage_Offset := Result'First;
   begin
      for Item of Value loop
         Result (Cursor) :=
           System.Storage_Elements.Storage_Element (Character'Pos (Item));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end To_Bytes;

   function To_String (Value : Byte_Array) return String is
      Result : String (1 .. Value'Length);
      Cursor : System.Storage_Elements.Storage_Offset := Value'First;
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Value (Cursor));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end To_String;

   function Base64_Encode (Value : Byte_Array) return String is
      Length : constant Natural := Natural (4 * ((Value'Length + 2) / 3));
      Result : String (1 .. Length);
      Input  : System.Storage_Elements.Storage_Offset := Value'First;
      Output : Natural := Result'First;
      Remaining : Natural := Natural (Value'Length);
   begin
      while Remaining > 0 loop
         declare
            A : constant Natural := Natural (Value (Input));
            B : constant Natural :=
              (if Remaining > 1 then Natural (Value (Input + 1)) else 0);
            C : constant Natural :=
              (if Remaining > 2 then Natural (Value (Input + 2)) else 0);
         begin
            Result (Output) := Base64_Alphabet (A / 4 + 1);
            Result (Output + 1) :=
              Base64_Alphabet ((A mod 4) * 16 + B / 16 + 1);
            Result (Output + 2) :=
              (if Remaining > 1
               then Base64_Alphabet ((B mod 16) * 4 + C / 64 + 1)
               else '=');
            Result (Output + 3) :=
              (if Remaining > 2
               then Base64_Alphabet (C mod 64 + 1)
               else '=');
         end;
         Input := Input + 3;
         Output := Output + 4;
         if Remaining > 3 then
            Remaining := Remaining - 3;
         else
            Remaining := 0;
         end if;
      end loop;
      return Result;
   end Base64_Encode;

   function Base64_Value (Item : Character) return Integer is
      Position : constant Natural :=
        Ada.Strings.Fixed.Index (Base64_Alphabet, String'(1 => Item));
   begin
      return (if Position = 0 then -1 else Position - 1);
   end Base64_Value;

   function Base64_Decode (Value : String) return Byte_Array is
      Padding : Natural := 0;
   begin
      if Value'Length = 0 or else Value'Length mod 4 /= 0 then
         Fail ("invalid base64 length");
      end if;
      if Value (Value'Last) = '=' then
         Padding := 1;
         if Value (Value'Last - 1) = '=' then
            Padding := 2;
         end if;
      end if;

      declare
         Result : Byte_Array
           (1 .. System.Storage_Elements.Storage_Offset
             (Value'Length / 4 * 3 - Padding));
         Input  : Natural := Value'First;
         Output : System.Storage_Elements.Storage_Offset := Result'First;
      begin
         while Input <= Value'Last loop
            declare
               Last_Group : constant Boolean := Input + 3 = Value'Last;
               V1 : constant Integer := Base64_Value (Value (Input));
               V2 : constant Integer := Base64_Value (Value (Input + 1));
               V3 : constant Integer :=
                 (if Value (Input + 2) = '=' then 0
                  else Base64_Value (Value (Input + 2)));
               V4 : constant Integer :=
                 (if Value (Input + 3) = '=' then 0
                  else Base64_Value (Value (Input + 3)));
            begin
               if V1 < 0 or else V2 < 0 or else V3 < 0 or else V4 < 0
                 or else Value (Input) = '=' or else Value (Input + 1) = '='
                 or else (Value (Input + 2) = '='
                          and then Value (Input + 3) /= '=')
                 or else ((Value (Input + 2) = '='
                           or else Value (Input + 3) = '=')
                          and then not Last_Group)
                 or else (Value (Input + 2) = '=' and then V2 mod 16 /= 0)
                 or else (Value (Input + 3) = '=' and then V3 mod 4 /= 0)
               then
                  Fail ("invalid base64 data");
               end if;
               Result (Output) :=
                 System.Storage_Elements.Storage_Element (V1 * 4 + V2 / 16);
               Output := Output + 1;
               if Value (Input + 2) /= '=' then
                  Result (Output) :=
                    System.Storage_Elements.Storage_Element
                      ((V2 mod 16) * 16 + V3 / 4);
                  Output := Output + 1;
               end if;
               if Value (Input + 3) /= '=' then
                  Result (Output) :=
                    System.Storage_Elements.Storage_Element
                      ((V3 mod 4) * 64 + V4);
                  Output := Output + 1;
               end if;
            end;
            Input := Input + 4;
         end loop;
         return Result;
      end;
   end Base64_Decode;

   function Parse_Positive (Value : String) return Positive is
      Result : Natural := 0;
   begin
      if Value'Length = 0 then
         Fail ("missing SCRAM iteration count");
      end if;
      for Item of Value loop
         if Item not in '0' .. '9'
           or else Result > (Maximum_Iterations - Character'Pos (Item) +
                             Character'Pos ('0')) / 10
         then
            Fail ("invalid SCRAM iteration count");
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      if Result < Minimum_Iterations or else Result > Maximum_Iterations then
         Fail ("SCRAM iteration count is outside the supported range");
      end if;
      return Positive (Result);
   end Parse_Positive;

   function Parse_Verifier (Value : String) return Verifier is
      Prefix : constant String := Mechanism & "$";
      Colon_1, Dollar_2, Colon_2 : Natural;
   begin
      if Value'Length > Maximum_Message_Length
        or else Value'Length <= Prefix'Length
        or else Value (Value'First .. Value'First + Prefix'Length - 1) /=
          Prefix
      then
         Fail ("invalid Postgres SCRAM verifier prefix");
      end if;
      Colon_1 := Ada.Strings.Fixed.Index
        (Value, ":", From => Value'First + Prefix'Length);
      Dollar_2 := Ada.Strings.Fixed.Index
        (Value,
         "$",
         From => (if Colon_1 = 0 then Value'Last else Colon_1 + 1));
      Colon_2 := Ada.Strings.Fixed.Index
        (Value,
         ":",
         From => (if Dollar_2 = 0 then Value'Last else Dollar_2 + 1));
      if Colon_1 = 0 or else Dollar_2 = 0 or else Colon_2 = 0
        or else Colon_1 >= Dollar_2 - 1 or else Dollar_2 >= Colon_2 - 1
        or else Colon_2 = Value'Last
      then
         Fail ("invalid Postgres SCRAM verifier fields");
      end if;

      declare
         Iterations : constant Positive := Parse_Positive
           (Value (Value'First + Prefix'Length .. Colon_1 - 1));
         Salt_Text : constant String := Value (Colon_1 + 1 .. Dollar_2 - 1);
         Salt      : constant Byte_Array := Base64_Decode (Salt_Text);
         Stored    : constant Byte_Array := Base64_Decode
           (Value (Dollar_2 + 1 .. Colon_2 - 1));
         Server    : constant Byte_Array := Base64_Decode
           (Value (Colon_2 + 1 .. Value'Last));
      begin
         if Salt'Length = 0 or else Salt'Length > 1_024
           or else Stored'Length /= Digest'Length
           or else Server'Length /= Digest'Length
         then
            Fail ("invalid Postgres SCRAM verifier data length");
         end if;
         return
           (Iteration_Count => Iterations,
            Encoded_Salt    => To_Unbounded_String (Salt_Text),
            Stored_Key      => Digest (Stored),
            Server_Key      => Digest (Server));
      end;
   end Parse_Verifier;

   function Make_Verifier_Raw
     (Password   : String;
      Salt       : Byte_Array;
      Iterations : Positive := Minimum_Iterations) return String is
   begin
      if Salt'Length = 0 or else Salt'Length > 1_024
        or else Iterations < Minimum_Iterations
        or else Iterations > Maximum_Iterations
      then
         Fail ("invalid SCRAM verifier parameters");
      end if;
      declare
         Password_Data : Byte_Array := To_Bytes (Password);
         Salted, Client_Key, Stored_Key, Server_Key : Digest;
      begin
         SCRAM_Core.PBKDF2_HMAC_SHA256
           (Password_Data, Salt, Iterations, Salted);
         HMAC_SHA256.Compute
           (Byte_Array (Salted), To_Bytes ("Client Key"), Client_Key);
         SCRAM_Core.Hash (Byte_Array (Client_Key), Stored_Key);
         HMAC_SHA256.Compute
           (Byte_Array (Salted), To_Bytes ("Server Key"), Server_Key);
         declare
            Result : constant String :=
              Mechanism & "$"
              & Positive'Image (Iterations)
                (2 .. Positive'Image (Iterations)'Last)
              & ":" & Base64_Encode (Salt)
              & "$" & Base64_Encode (Byte_Array (Stored_Key))
              & ":" & Base64_Encode (Byte_Array (Server_Key));
         begin
            Password_Data := (others => 0);
            SCRAM_Core.Wipe (Salted);
            SCRAM_Core.Wipe (Client_Key);
            SCRAM_Core.Wipe (Stored_Key);
            SCRAM_Core.Wipe (Server_Key);
            pragma Inspection_Point (Password_Data);
            return Result;
         end;
      end;
   end Make_Verifier_Raw;

   procedure Validate_Nonce (Value : String) is
   begin
      if Value'Length < 16 or else Value'Length > 256 then
         Fail ("invalid SCRAM nonce length");
      end if;
      for Item of Value loop
         if Character'Pos (Item) not in 16#21# .. 16#7E#
           or else Item = ','
         then
            Fail ("invalid SCRAM nonce character");
         end if;
      end loop;
   end Validate_Nonce;

   function Random_Nonce return String is
      Data : aliased Ada.Streams.Stream_Element_Array := (1 .. 18 => 0);
      Converted : Byte_Array (1 .. 18);
   begin
      Random_Bytes.Random (Data);
      for Index in Data'Range loop
         Converted (System.Storage_Elements.Storage_Offset (Index)) :=
           System.Storage_Elements.Storage_Element (Data (Index));
      end loop;
      return Base64_Encode (Converted);
   end Random_Nonce;

   function Escape_Name (Value : String) return String is
      Result : Unbounded_String;
   begin
      if Value'Length = 0 then
         Fail ("empty SCRAM username");
      end if;
      for Item of Value loop
         case Item is
            when Character'Val (0) => Fail ("NUL in SCRAM username");
            when ',' => Append (Result, "=2C");
            when '=' => Append (Result, "=3D");
            when others => Append (Result, Item);
         end case;
      end loop;
      return To_String (Result);
   end Escape_Name;

   function Client_First_Bare (User, Nonce : String) return String is
   begin
      Validate_Nonce (Nonce);
      declare
         Result : constant String :=
           "n=" & Escape_Name (User) & ",r=" & Nonce;
      begin
         if Result'Length > Maximum_Message_Length - 3 then
            Fail ("SCRAM client-first-message is too long");
         end if;
         return Result;
      end;
   end Client_First_Bare;

   function Client_First_Message (User, Nonce : String) return String is
     ("n,," & Client_First_Bare (User, Nonce));

   function Attribute_Value
     (Token : String; Name : Character) return String is
   begin
      if Token'Length < 2
        or else Token (Token'First) /= Name
        or else Token (Token'First + 1) /= '='
      then
         Fail
           ("malformed SCRAM attribute; expected "
            & String'(1 => Name));
      end if;
      return Token (Token'First + 2 .. Token'Last);
   end Attribute_Value;

   function Next_Token
     (Message : String; Cursor : in out Natural) return String is
      Comma : Natural;
   begin
      if Cursor < Message'First or else Cursor > Message'Last then
         Fail ("missing SCRAM attribute");
      end if;
      Comma := Ada.Strings.Fixed.Index (Message, ",", From => Cursor);
      if Comma = 0 then
         declare
            Result : constant String := Message (Cursor .. Message'Last);
         begin
            Cursor := Message'Last + 1;
            return Result;
         end;
      elsif Comma = Cursor then
         Fail ("empty SCRAM attribute");
      end if;
      declare
         Result : constant String := Message (Cursor .. Comma - 1);
      begin
         Cursor := Comma + 1;
         return Result;
      end;
   end Next_Token;

   procedure Parse_Client_First
     (Message : String;
      Bare    : out Unbounded_String;
      Nonce   : out Unbounded_String;
      Channel_Binding : out Unbounded_String) is
   begin
      if Message'Length > Maximum_Message_Length or else Message'Length < 8
        or else Message (Message'First .. Message'First + 2)
          not in "n,," | "y,,"
      then
         Fail ("unsupported SCRAM GS2 header");
      end if;
      Channel_Binding := To_Unbounded_String
        ((if Message (Message'First) = 'n' then "biws" else "eSws"));
      declare
         Bare_Text : constant String :=
           Message (Message'First + 3 .. Message'Last);
         Cursor : Natural := Bare_Text'First;
         Name_Token : constant String := Next_Token (Bare_Text, Cursor);
         Name : constant String := Attribute_Value (Name_Token, 'n');
         Nonce_Token : constant String := Next_Token (Bare_Text, Cursor);
         Nonce_Text : constant String := Attribute_Value (Nonce_Token, 'r');
      begin
         --  Postgres deliberately ignores the SCRAM username and libpq
         --  sends an empty n= value, relying on the startup-message user.
         if Cursor <= Bare_Text'Last then
            Fail ("malformed SCRAM client-first-message");
         end if;
         for Index in Name'Range loop
            if Name (Index) = '='
              and then (Index > Name'Last - 2
                        or else Name (Index + 1 .. Index + 2)
                          not in "2C" | "3D")
            then
               Fail ("invalid SCRAM escaped username");
            end if;
         end loop;
         Validate_Nonce (Nonce_Text);
         Bare := To_Unbounded_String (Bare_Text);
         Nonce := To_Unbounded_String (Nonce_Text);
      end;
   end Parse_Client_First;

   function Bare_From_Client_First (Message : String) return String is
      Bare, Nonce, Channel_Binding : Unbounded_String;
   begin
      Parse_Client_First (Message, Bare, Nonce, Channel_Binding);
      return To_String (Bare);
   end Bare_From_Client_First;

   function Nonce_From_Client_First (Message : String) return String is
      Bare, Nonce, Channel_Binding : Unbounded_String;
   begin
      Parse_Client_First (Message, Bare, Nonce, Channel_Binding);
      return To_String (Nonce);
   end Nonce_From_Client_First;

   function Channel_Binding_From_Client_First
     (Message : String) return String is
      Bare, Nonce, Channel_Binding : Unbounded_String;
   begin
      Parse_Client_First (Message, Bare, Nonce, Channel_Binding);
      return To_String (Channel_Binding);
   end Channel_Binding_From_Client_First;

   function Server_First_Message
     (Credential     : Verifier;
      Combined_Nonce : String) return String is
   begin
      Validate_Nonce (Combined_Nonce);
      return "r=" & Combined_Nonce
        & ",s=" & To_String (Credential.Encoded_Salt)
        & ",i=" & Positive'Image (Credential.Iteration_Count)
          (2 .. Positive'Image (Credential.Iteration_Count)'Last);
   end Server_First_Message;

   procedure Parse_Server_First
     (Message      : String;
      Client_Nonce : String;
      Nonce        : out Unbounded_String;
      Salt         : out Unbounded_String;
      Iterations   : out Positive) is
      Cursor : Natural := Message'First;
   begin
      if Message'Length = 0
        or else Message'Length > Maximum_Message_Length
      then
         Fail ("invalid SCRAM server-first-message length");
      end if;
      declare
         R : constant String := Attribute_Value
           (Next_Token (Message, Cursor), 'r');
         S : constant String := Attribute_Value
           (Next_Token (Message, Cursor), 's');
         I : constant String := Attribute_Value
           (Next_Token (Message, Cursor), 'i');
         Decoded_Salt : constant Byte_Array := Base64_Decode (S);
      begin
         if Cursor <= Message'Last or else R'Length <= Client_Nonce'Length
           or else R (R'First .. R'First + Client_Nonce'Length - 1) /=
             Client_Nonce
           or else Decoded_Salt'Length = 0
           or else Decoded_Salt'Length > 1_024
         then
            Fail ("invalid SCRAM server-first-message");
         end if;
         Validate_Nonce (R);
         Nonce := To_Unbounded_String (R);
         Salt := To_Unbounded_String (S);
         Iterations := Parse_Positive (I);
      end;
   end Parse_Server_First;

   function Client_Final_Message
     (Password                  : String;
      Bare_Client_First         : String;
      Server_First              : String;
      Client_Nonce              : String;
      Expected_Server_Signature : out Digest) return String is
      Nonce, Encoded_Salt : Unbounded_String;
      Iterations : Positive;
   begin
      Parse_Server_First
        (Server_First, Client_Nonce, Nonce, Encoded_Salt, Iterations);
      declare
         Final_Without_Proof : constant String :=
           "c=biws,r=" & To_String (Nonce);
         Auth_Message : constant String :=
           Bare_Client_First & "," & Server_First & "," & Final_Without_Proof;
         Password_Data : Byte_Array := To_Bytes (Password);
         Salt : constant Byte_Array :=
           Base64_Decode (To_String (Encoded_Salt));
         Salted, Client_Key, Stored_Key : Digest;
         Client_Signature, Proof, Server_Key : Digest;
      begin
         SCRAM_Core.PBKDF2_HMAC_SHA256
           (Password_Data, Salt, Iterations, Salted);
         HMAC_SHA256.Compute
           (Byte_Array (Salted), To_Bytes ("Client Key"), Client_Key);
         SCRAM_Core.Hash (Byte_Array (Client_Key), Stored_Key);
         HMAC_SHA256.Compute
           (Byte_Array (Stored_Key),
            To_Bytes (Auth_Message),
            Client_Signature);
         SCRAM_Core.Exclusive_Or (Client_Key, Client_Signature, Proof);
         HMAC_SHA256.Compute
           (Byte_Array (Salted), To_Bytes ("Server Key"), Server_Key);
         HMAC_SHA256.Compute
           (Byte_Array (Server_Key),
            To_Bytes (Auth_Message),
            Expected_Server_Signature);
         declare
            Result : constant String :=
              Final_Without_Proof & ",p="
              & Base64_Encode (Byte_Array (Proof));
         begin
            Password_Data := (others => 0);
            SCRAM_Core.Wipe (Salted);
            SCRAM_Core.Wipe (Client_Key);
            SCRAM_Core.Wipe (Stored_Key);
            SCRAM_Core.Wipe (Client_Signature);
            SCRAM_Core.Wipe (Proof);
            SCRAM_Core.Wipe (Server_Key);
            pragma Inspection_Point (Password_Data);
            return Result;
         end;
      end;
   end Client_Final_Message;

   procedure Verify_Server_Final
     (Message : String; Expected_Server_Signature : Digest) is
   begin
      if Message'Length > Maximum_Message_Length then
         Fail ("invalid SCRAM server-final-message length");
      elsif Message'Length >= 2
        and then Message (Message'First .. Message'First + 1) = "e="
      then
         Fail ("SCRAM server rejected authentication");
      end if;
      declare
         Signature_Text : constant String := Attribute_Value (Message, 'v');
         Signature : constant Byte_Array := Base64_Decode (Signature_Text);
      begin
         if Signature'Length /= Digest'Length
           or else not HMAC_SHA256.Equal
             (Digest (Signature), Expected_Server_Signature)
         then
            Fail ("SCRAM server signature verification failed");
         end if;
      end;
   end Verify_Server_Final;

   procedure Verify_Client_Final
     (Credential        : Verifier;
      Bare_Client_First : String;
      Server_First      : String;
      Combined_Nonce    : String;
      Client_Final      : String;
      Server_Signature  : out Digest;
      Valid             : out Boolean;
      Channel_Binding   : String := "biws") is
      Cursor : Natural := Client_Final'First;
   begin
      Server_Signature := (others => 0);
      Valid := False;
      if Client_Final'Length = 0
        or else Client_Final'Length > Maximum_Message_Length
      then
         Fail ("invalid SCRAM client-final-message length");
      end if;
      declare
         C : constant String := Attribute_Value
           (Next_Token (Client_Final, Cursor), 'c');
         R : constant String := Attribute_Value
           (Next_Token (Client_Final, Cursor), 'r');
         P_Token : constant String := Next_Token (Client_Final, Cursor);
         P : constant String := Attribute_Value (P_Token, 'p');
         Proof_Data : constant Byte_Array := Base64_Decode (P);
      begin
         if C /= Channel_Binding or else R /= Combined_Nonce
           or else Cursor <= Client_Final'Last
           or else Proof_Data'Length /= Digest'Length
         then
            Fail ("invalid SCRAM client-final-message");
         end if;
         declare
            Final_Without_Proof : constant String :=
              Client_Final (Client_Final'First .. P_Token'First - 2);
            Auth_Message : constant String :=
              Bare_Client_First & "," & Server_First & ","
              & Final_Without_Proof;
            Client_Signature, Recovered_Client_Key : Digest;
            Computed_Stored_Key : Digest;
         begin
            HMAC_SHA256.Compute
              (Byte_Array (Credential.Stored_Key),
               To_Bytes (Auth_Message),
               Client_Signature);
            SCRAM_Core.Exclusive_Or
              (Digest (Proof_Data), Client_Signature, Recovered_Client_Key);
            SCRAM_Core.Hash
              (Byte_Array (Recovered_Client_Key), Computed_Stored_Key);
            if not HMAC_SHA256.Equal
              (Computed_Stored_Key, Credential.Stored_Key)
            then
               SCRAM_Core.Wipe (Client_Signature);
               SCRAM_Core.Wipe (Recovered_Client_Key);
               SCRAM_Core.Wipe (Computed_Stored_Key);
               return;
            end if;
            HMAC_SHA256.Compute
              (Byte_Array (Credential.Server_Key),
               To_Bytes (Auth_Message),
               Server_Signature);
            SCRAM_Core.Wipe (Client_Signature);
            SCRAM_Core.Wipe (Recovered_Client_Key);
            SCRAM_Core.Wipe (Computed_Stored_Key);
            Valid := True;
         end;
      end;
   end Verify_Client_Final;

end Flyology.Postgres.SCRAM;
