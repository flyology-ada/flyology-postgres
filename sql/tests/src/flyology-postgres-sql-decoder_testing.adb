with AUnit.Assertions; use AUnit.Assertions;
with Interfaces; use Interfaces;

with Flyology.Postgres.SQL.Decoders; use Flyology.Postgres.SQL.Decoders;
with Flyology.Postgres.SQL.Decoder_V18;
with Flyology.Postgres.SQL.Views.V18;

package body Flyology.Postgres.SQL.Decoder_Testing is

   package V18 renames Flyology.Postgres.SQL.Views.V18;
   use type V18.Node_Kind;

   type Byte_Array is array (Positive range <>) of aliased Unsigned_8;

   procedure Initialize (Stream : out Reader; Bytes : Byte_Array) is
   begin
      Decoders.Initialize (Stream, Bytes (Bytes'First)'Address, Bytes'Length);
   end Initialize;

   procedure Expect_Decode_Error (Bytes : Byte_Array; Label_Text : String) is
      Tree   : Syntax_Tree;
      Raised : Boolean := False;
   begin
      begin
         Decoder_V18.Load
           (Tree, Bytes (Bytes'First)'Address, Bytes'Length);
      exception
         when Decoder_Error => Raised := True;
      end;
      Assert (Raised, Label_Text);
   end Expect_Decode_Error;

   procedure Run is
      Stream : Reader;
      Child  : Reader;
   begin
      declare
         Bytes : aliased constant Byte_Array := (16#96#, 16#01#);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Varint (Stream) = 150, "varint decoding");
         Assert (At_End (Stream), "varint consumes its input");
      end;

      declare
         Bytes : aliased constant Byte_Array :=
           (16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#,
            16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#01#);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Int_64 (Stream) = -1, "two's-complement int64 varint");
         Initialize (Stream, Bytes);
         Assert (Read_Int_32 (Stream) = -1, "two's-complement int32 varint");
      end;

      declare
         Bytes : aliased constant Byte_Array := (1 => 3);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_SInt_32 (Stream) = -2, "zigzag sint32");
         Initialize (Stream, Bytes);
         Assert (Read_SInt_64 (Stream) = -2, "zigzag sint64");
      end;

      declare
         Bytes : aliased constant Byte_Array := (16#78#, 16#56#, 16#34#, 16#12#);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Fixed_32 (Stream) = 16#1234_5678#, "fixed32 decoding");
         Initialize (Stream, Bytes);
         Assert (Read_SFixed_32 (Stream) = 16#1234_5678#, "sfixed32 decoding");
      end;

      declare
         Bytes : aliased constant Byte_Array :=
           (16#EF#, 16#CD#, 16#AB#, 16#89#, 16#67#, 16#45#, 16#23#, 16#01#);
      begin
         Initialize (Stream, Bytes);
         Assert
           (Read_Fixed_64 (Stream) = 16#0123_4567_89AB_CDEF#,
            "fixed64 decoding");
         Initialize (Stream, Bytes);
         Assert
           (Read_SFixed_64 (Stream) = 16#0123_4567_89AB_CDEF#,
            "sfixed64 decoding");
      end;

      declare
         Bytes : aliased constant Byte_Array := (0, 0, 16#80#, 16#3F#);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Float (Stream) = 1.0, "IEEE float decoding");
      end;

      declare
         Bytes : aliased constant Byte_Array := (0, 0, 0, 0, 0, 0, 16#F0#, 16#3F#);
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Double (Stream) = 1.0, "IEEE double decoding");
      end;

      declare
         Bytes : aliased constant Byte_Array := (3, Character'Pos ('a'),
                                        Character'Pos ('b'), Character'Pos ('c'));
      begin
         Initialize (Stream, Bytes);
         Assert (Read_Text (Stream) = "abc", "string/bytes decoding");
         Assert (At_End (Stream), "length-delimited text consumes its input");
      end;

      declare
         Bytes : aliased constant Byte_Array := (2, 16#08#, 16#01#);
         Number : Positive;
         Encoding : Wire_Type;
      begin
         Initialize (Stream, Bytes);
         Read_Embedded (Stream, Child);
         Read_Key (Child, Number, Encoding);
         Assert (Number = 1 and Encoding = Varint, "embedded-message reader");
         Assert (Read_Varint (Child) = 1, "embedded-message payload");
      end;

      Expect_Decode_Error ((16#08#, 16#80#), "truncated varint is rejected");
      Expect_Decode_Error ((1 => 0), "field zero is rejected");
      Expect_Decode_Error ((1 => 16#0F#), "bad wire type is rejected");
      Expect_Decode_Error
        ((16#12#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#,
          16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#01#),
         "overflowing length is rejected");
      Expect_Decode_Error
        ((16#12#, 2, 16#08#), "truncated embedded message is rejected");
      Expect_Decode_Error
        ((16#A1#, 16#06#, 0, 0, 0, 0, 0, 0, 0),
         "truncated fixed64 payload is rejected while skipping unknown fields");
      Expect_Decode_Error
        ((16#AD#, 16#06#, 0, 0, 0),
         "truncated fixed32 payload is rejected while skipping unknown fields");
      Expect_Decode_Error
        ((16#08#, 16#80#, 16#80#, 16#80#, 16#80#, 16#10#),
         "uint32 overflow is rejected");

      declare
         Bytes : aliased constant Byte_Array := (16#08#, 0);
         Tree  : Syntax_Tree;
      begin
         Decoder_V18.Load
           (Tree, Bytes (Bytes'First)'Address, Bytes'Length);
         Tree.Valid := True;
         Tree.Parsed_Version := PostgreSQL_18;
         declare
            Root_View : constant V18.Parse_Result :=
              V18.View (Tree, V18.Root (Tree));
         begin
            Assert
              (Root_View.Version.Present and then Root_View.Version.Value = 0,
               "present scalar zero remains distinct from an omitted field");
            Assert
              (V18.Length (Tree, Root_View.Statements) = 0,
               "omitted repeated field remains an empty typed sequence");
         end;
      end;

      declare
         Bytes : aliased constant Byte_Array :=
           (16#08#, 1,
            16#A0#, 16#06#, 1,
            16#A1#, 16#06#, 0, 0, 0, 0, 0, 0, 0, 0,
            16#A2#, 16#06#, 2, 16#AA#, 16#BB#,
            16#A5#, 16#06#, 0, 0, 0, 0,
            16#A3#, 16#06#, 16#A8#, 16#06#, 1, 16#A4#, 16#06#);
         Tree : Syntax_Tree;
      begin
         Decoder_V18.Load
           (Tree, Bytes (Bytes'First)'Address, Bytes'Length);
         Tree.Valid := True;
         Tree.Parsed_Version := PostgreSQL_18;
         Assert
           (V18.View (Tree, V18.Root (Tree)).Version.Value = 1,
            "unknown varint, fixed, length, and group fields are skipped safely");
      end;

      declare
         --  ParseResult.stmts[0].stmt.A_Const contains two alternatives from
         --  the same oneof.  Protobuf requires the last alternative to win.
         Bytes : aliased constant Byte_Array :=
           (16#12#, 9,
            16#0A#, 7,
            16#FA#, 16#10#, 4,
            16#0A#, 0,
            16#12#, 0);
         Tree : Syntax_Tree;
      begin
         Decoder_V18.Load
           (Tree, Bytes (Bytes'First)'Address, Bytes'Length);
         Tree.Valid := True;
         Tree.Parsed_Version := PostgreSQL_18;
         declare
            Raw : constant V18.Raw_Stmt_Reference :=
              V18.Element
                (Tree, V18.Statements (Tree, V18.Root (Tree)), 1);
            Item : constant V18.Node_Reference := V18.Statement (Tree, Raw);
            Value : constant V18.A_Const :=
              V18.View (Tree, V18.As_A_Const (Tree, Item));
         begin
            Assert (V18.Kind (Tree, Item) = V18.Node_A_Const,
                    "oneof node wrapper remains well formed");
            Assert (not Value.Ival.Present and then Value.Fval.Present,
                    "the last protobuf oneof alternative wins");
         end;
      end;
   end Run;

end Flyology.Postgres.SQL.Decoder_Testing;
