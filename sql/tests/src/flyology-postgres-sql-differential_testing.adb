with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;

with Flyology.Postgres.SQL.C_Oracle;
with Flyology.Postgres.SQL.Internals;

package body Flyology.Postgres.SQL.Differential_Testing is

   procedure Run is
      E_Acute : constant String :=
        Character'Val (16#C3#) & Character'Val (16#A9#);
      Syntax_Case : constant String := "SELECT '" & E_Acute & "', 1 1";
      Scanner_Case : constant String := "SELECT '" & E_Acute & "', 'x";
      NUL_Case : constant String :=
        E_Acute & Character'Val (0) & "SELECT 2";
      Diagnostic_Failures : Natural := 0;

      procedure Compare_Diagnostic
        (Text : String; Version : Major_Version)
      is
         Native_Tree : Syntax_Tree;
         C_Tree      : Syntax_Tree;
      begin
         Parse (Text, Version, Native_Tree);
         C_Oracle.Parse (Text, Version, C_Tree);
         if Message (Error (Native_Tree)) /= Message (Error (C_Tree)) then
            Ada.Text_IO.Put_Line
              (Version'Image & " " & Text & " message: native [" &
               Message (Error (Native_Tree)) & "] C [" &
               Message (Error (C_Tree)) & "]");
            Diagnostic_Failures := Diagnostic_Failures + 1;
         end if;
         if Cursor_Position (Error (Native_Tree)) /=
           Cursor_Position (Error (C_Tree))
         then
            Ada.Text_IO.Put_Line
              (Version'Image & " " & Text & " cursor: native" &
               Cursor_Position (Error (Native_Tree))'Image & " C" &
               Cursor_Position (Error (C_Tree))'Image);
            Diagnostic_Failures := Diagnostic_Failures + 1;
         end if;
      end Compare_Diagnostic;

      procedure Check
        (Text : String;
         First : Major_Version := Major_Version'First;
         Last  : Major_Version := Major_Version'Last)
      is
      begin
         for Version in First .. Last loop
            declare
               Native_Tree : Syntax_Tree;
               C_Tree      : Syntax_Tree;
            begin
               Parse (Text, Version, Native_Tree);
               C_Oracle.Parse (Text, Version, C_Tree);
               declare
                  Difference : constant String :=
                    Internals.First_Difference (Native_Tree, C_Tree);
               begin
                  if Difference'Length /= 0 then
                     Ada.Text_IO.Put_Line
                       ("differential " & Version'Image & " for " & Text);
                     Ada.Text_IO.Put_Line (Difference);
                  end if;
                  Assert
                    (Difference'Length = 0,
                     "native and C parser arenas agree for " & Version'Image);
               end;
            end;
         end loop;
      end Check;
   begin
      Check ("");
      Check ("SELECT 0, FALSE, NULL");
      Check ("SELECT DISTINCT name FROM events");
      Check ("SELECT 1; SELECT 2;");
      Check ("SELECT ""Mixed Case"" FROM ""Quoted Table""");
      Check ("SELECT 'é雪' AS unicode_text");
      Check ("-- leading" & ASCII.LF & "SELECT /* nested /* block */ ok */ 42");
      Check ("SELECT $$dollar 'quoted' ; text$$");
      Check ("SELECT E'line\n', U&'d\0061t\+000061'");
      Check ("SELECT E'\401'");
      Check ("SELECT $12345678901, 1", Last => PostgreSQL_17);
      Check ("SELECT E'a\vb'");
      Check ("SELECT -'abc'");
      Check ("SELECT -B'101'");
      Check ("SELECT -1");
      Check ("SELECT -1.5");
      Check
        ("WITH recent AS (SELECT id FROM events WHERE created_at > $1) " &
         "SELECT r.id + 1 FROM recent r JOIN accounts a ON a.id = r.id " &
         "WHERE r.id BETWEEN 1 AND 10 ORDER BY r.id DESC NULLS LAST LIMIT 5");
      Check ("INSERT INTO t (a, b) VALUES (1, 'x') RETURNING a");
      Check ("UPDATE t SET a = a + 1 WHERE b IS NOT NULL RETURNING *");
      Check ("DELETE FROM t USING u WHERE t.id = u.id RETURNING t.id");
      Check ("CREATE TABLE t (id bigint PRIMARY KEY, payload jsonb NOT NULL)");
      Check ("ALTER TABLE t ADD COLUMN created_at timestamptz DEFAULT now()");
      Check ("CREATE INDEX ON t ((payload->>'kind')) WHERE id > 0");
      Check ("EXPLAIN (ANALYZE false, VERBOSE true) SELECT * FROM t");
      Check ("COPY t FROM STDIN WITH (FORMAT csv, HEADER true)");
      Check ("SHOW search_path");
      Check ("SET LOCAL work_mem = '16MB'");
      Check ("BEGIN ISOLATION LEVEL SERIALIZABLE; COMMIT");
      Check
        ("MERGE INTO inventory i USING changes c ON i.id = c.id " &
         "WHEN MATCHED THEN UPDATE SET quantity = c.quantity " &
         "WHEN NOT MATCHED THEN INSERT (id, quantity) VALUES (c.id, c.quantity)",
         PostgreSQL_15);
      Check ("SELECT 'unterminated");
      Check ("SELECT $$unterminated");
      Check ("SELECT /* unterminated");
      Check ("SELECT FROM WHERE");
      Check ("CREATE TABLE (");
      Check ("SELECT foo.*.bar FROM foo");
      Check ("SELECT 1" & Character'Val (0) & "SELECT 2");
      Check (Syntax_Case);
      Check (Scanner_Case);
      Check ("SELECT 'e', 1 1");
      Check ("SELECT 'e', 'x");
      Check (NUL_Case);
      for Version in Major_Version loop
         Compare_Diagnostic ("SELECT 1 LIMIT 1, 2", Version);
         Compare_Diagnostic
           ("CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)", Version);
         Compare_Diagnostic ("CREATE ROLE r WITH foo", Version);
         if Version >= PostgreSQL_16 then
            Compare_Diagnostic
              ("SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON " &
               "ENCODING foo)", Version);
         end if;
      end loop;
      Assert
        (Diagnostic_Failures = 0,
         Diagnostic_Failures'Image &
           " grammar diagnostic comparisons differ from the C oracle");
      Check ("SELECT 1 LIMIT 1, 2");
      Check ("CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)");
      Check ("CREATE ROLE r WITH foo");
      Check
        ("SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)");
      for Version in Major_Version loop
         declare
            Tree : Syntax_Tree;
         begin
            Parse (NUL_Case, Version, Tree);
            Assert
              (Cursor_Position (Error (Tree)) = 2,
               "native NUL diagnostic character position agrees for " &
                 Version'Image);
         end;
      end loop;
   end Run;

end Flyology.Postgres.SQL.Differential_Testing;
