#!/usr/bin/env python3
"""Generate native Ada scanner/parser tables from PostgreSQL's C outputs.

The checked-in libpg_query extraction contains the exact Bison and Flex output
used by its native parser.  Reading the resolved tables avoids making the Ada
generator depend on a particular maintainer installation of Bison or Flex.
The corresponding gram.y and scan.l files are retained beside those outputs
for semantic-action generation, auditing, and provenance.
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


PARSER_ARRAYS = (
    "yytranslate",
    "yyr1",
    "yyr2",
    "yydefact",
    "yydefgoto",
    "yypact",
    "yypgoto",
    "yytable",
    "yycheck",
)

PARSER_CONSTANTS = (
    "YYFINAL",
    "YYLAST",
    "YYNTOKENS",
    "YYNNTS",
    "YYNRULES",
    "YYNSTATES",
    "YYMAXUTOK",
    "YYPACT_NINF",
    "YYTABLE_NINF",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_c_comments(value: str) -> str:
    return re.sub(r"/\*.*?\*/", "", value, flags=re.DOTALL)


def c_array(source: str, name: str) -> list[int]:
    match = re.search(
        rf"(?:static\s+)?const\s+[^;=]+\b{re.escape(name)}\s*\[[^]]*\]\s*=\s*\{{(.*?)\n\}};",
        source,
        re.DOTALL,
    )
    if not match:
        raise ValueError(f"C array {name} was not found")
    body = strip_c_comments(match.group(1))
    return [int(item, 0) for item in re.findall(r"(?<![A-Za-z_])-?(?:0x[0-9A-Fa-f]+|\d+)", body)]


def parser_constant(source: str, name: str) -> int:
    match = re.search(rf"^#define\s+{name}\s+\(?\s*(-?\d+)\s*\)?", source, re.MULTILINE)
    if not match:
        raise ValueError(f"parser constant {name} was not found")
    return int(match.group(1))


def tokens(source: str) -> list[tuple[str, int]]:
    match = re.search(r"enum\s+yytokentype\s*\{(.*?)\};", source, re.DOTALL)
    if not match:
        raise ValueError("enum yytokentype was not found")
    result: list[tuple[str, int]] = []
    next_value = 0
    for name, explicit in re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(-?\d+))?\s*(?:,|$)",
        strip_c_comments(match.group(1)),
    ):
        if explicit:
            next_value = int(explicit)
        result.append((name, next_value))
        next_value += 1
    return result


def scanner_transitions(source: str) -> list[tuple[int, int]]:
    match = re.search(
        r"yy_transition\s*\[[^]]+\]\s*=\s*\{(.*?)\n\};",
        source,
        re.DOTALL,
    )
    if not match:
        raise ValueError("Flex full-speed transition table was not found")
    pairs = re.findall(r"\{\s*(-?\d+)\s*,\s*(-?\d+)\s*\}", match.group(1))
    if not pairs:
        raise ValueError("Flex transition table is empty")
    return [(int(verify), int(offset)) for verify, offset in pairs]


def scanner_starts(source: str) -> list[int]:
    match = re.search(
        r"yy_start_state_list\s*\[[^]]+\]\s*=\s*\{(.*?)\n\};",
        source,
        re.DOTALL,
    )
    if not match:
        raise ValueError("Flex start-state table was not found")
    return [int(value) for value in re.findall(r"&yy_transition\[(\d+)\]", match.group(1))]


def scanner_rule_count(source: str) -> int:
    actions = [int(item) for item in re.findall(r"^case\s+(\d+):", source, re.MULTILINE)]
    if not actions:
        raise ValueError("Flex scanner actions were not found")
    return max(actions)


def scanner_case_bodies(source: str) -> dict[int, str]:
    start = source.find("do_action:")
    end = source.find("case YY_END_OF_BUFFER:", start)
    if start < 0 or end < 0:
        raise ValueError("Flex action switch was not found")
    section = source[start:end]
    matches = list(re.finditer(r"^case\s+(\d+):", section, re.MULTILINE))
    return {
        int(match.group(1)): section[
            match.end():matches[index + 1].start() if index + 1 < len(matches) else len(section)
        ]
        for index, match in enumerate(matches)
    }


def scanner_actions(source: str, token_values: dict[str, int]) -> list[tuple[str, int]]:
    count = scanner_rule_count(source)
    if count < 56:
        raise ValueError("PostgreSQL scanner has fewer common actions than expected")
    common: dict[int, tuple[str, int | str]] = {
        1: ("Ignore", 0), 2: ("Return_Token", "SQL_COMMENT"),
        3: ("Comment_Start", 0), 4: ("Comment_Nest", 0),
        5: ("Comment_End", 0), 6: ("Ignore", 0), 7: ("Ignore", 0),
        8: ("Ignore", 0), 9: ("Bit_Start", 0), 10: ("Literal_Add", 0),
        11: ("Literal_Add", 0), 12: ("Hex_Start", 0), 13: ("Nchar_Start", 0),
        14: ("Quote_Start", 0), 15: ("Escape_Start", 0),
        16: ("Unicode_String_Start", 0), 17: ("Quote_Stop", 0),
        18: ("Quote_Continue", 0), 19: ("Quote_Finish", 0),
        20: ("Quote_Finish", 0), 21: ("Quote_Double", 0),
        22: ("Literal_Add", 0), 23: ("Literal_Add", 0),
        24: ("Unicode_Escape", 0), 25: ("Unicode_Surrogate", 0),
        26: ("Unicode_Surrogate_Error", 0), 27: ("Unicode_Surrogate_Error", 0),
        28: ("Unicode_Escape_Error", 0), 29: ("Escape_Character", 0),
        30: ("Octal_Escape", 0), 31: ("Hex_Escape", 0),
        32: ("Escape_Trailing", 0), 33: ("Dollar_Start", 0),
        34: ("Dollar_Failed", 0), 35: ("Dollar_Delimiter", 0),
        36: ("Literal_Add", 0), 37: ("Literal_Add", 0),
        38: ("Dollar_Character", 0), 39: ("Identifier_Start", 0),
        40: ("Unicode_Identifier_Start", 0), 41: ("Identifier_Stop", 0),
        42: ("Unicode_Identifier_Stop", 0), 43: ("Identifier_Double", 0),
        44: ("Literal_Add", 0), 45: ("Unicode_Failed", 0),
        46: ("Return_Token", "TYPECAST"), 47: ("Return_Token", "DOT_DOT"),
        48: ("Return_Token", "COLON_EQUALS"),
        49: ("Return_Token", "EQUALS_GREATER"),
        50: ("Return_Token", "LESS_EQUALS"),
        51: ("Return_Token", "GREATER_EQUALS"),
        52: ("Return_Token", "NOT_EQUALS"),
        53: ("Return_Token", "NOT_EQUALS"), 54: ("Self_Character", 0),
        55: ("Operator_Token", 0), 56: ("Parameter_Token", 0),
    }
    result: list[tuple[str, int]] = []
    for action in range(1, count + 1):
        if action in common:
            kind, argument = common[action]
            if isinstance(argument, str):
                if argument not in token_values:
                    raise ValueError(f"scanner token {argument} has no declaration")
                argument = token_values[argument]
            result.append((kind, argument))
            continue
        body = scanner_case_bodies(source).get(action, "")
        if "ScanKeywordLookup" in body:
            operation = ("Identifier_Token", 0)
        elif "YY_FATAL_ERROR" in body:
            operation = ("Scanner_Jam", 0)
        elif re.search(r"return\s+yytext\[0\]", body):
            operation = ("Other_Character", 0)
        elif "return FCONST" in body:
            operation = ("Float_Literal", 0)
        elif "process_integer_literal" in body:
            base_match = re.search(r"process_integer_literal\([^;]+,\s*(\d+)\s*\)", body)
            base = int(base_match.group(1)) if base_match else 10
            less_match = re.search(r"yyless\(yyleng\s*-\s*(\d+)\)", body)
            operation = (
                "Integer_Less" if less_match else "Integer_Literal",
                int(less_match.group(1)) if less_match else base,
            )
        elif "invalid hexadecimal integer" in body:
            operation = ("Invalid_Integer", 16)
        elif "invalid octal integer" in body:
            operation = ("Invalid_Integer", 8)
        elif "invalid binary integer" in body:
            operation = ("Invalid_Integer", 2)
        elif "trailing junk after parameter" in body:
            operation = ("Invalid_Parameter", 0)
        elif "trailing junk after numeric literal" in body:
            operation = ("Invalid_Numeric", 0)
        else:
            raise ValueError(f"unclassified Flex action {action}")
        result.append(operation)
    return result


def grammar_action_count(source: str) -> int:
    start = source.find("switch (yyn)")
    end = source.find("default: break;", start)
    if start < 0 or end < 0:
        raise ValueError("Bison reduction dispatch was not found")
    actions = [
        int(item)
        for item in re.findall(
            r"^\s*case\s+(\d+):", source[start:end], re.MULTILINE
        )
    ]
    if not actions:
        raise ValueError("Bison reduction actions were not found")
    return max(actions)


def keyword_rows(source: str, token_values: dict[str, int]) -> list[tuple[str, int, str, str]]:
    result = []
    for name, token, category, label in re.findall(
        r'PG_KEYWORD\("([^"]+)",\s*([A-Za-z_][A-Za-z0-9_]*),\s*'
        r"([A-Za-z_][A-Za-z0-9_]*),\s*([A-Za-z_][A-Za-z0-9_]*)\)",
        source,
    ):
        if token not in token_values:
            raise ValueError(f"keyword token {token} has no numeric declaration")
        result.append((name, token_values[token], category, label))
    if not result:
        raise ValueError("PostgreSQL keyword rows were not found")
    return result


def ada_integer_array(name: str, values: list[int]) -> list[str]:
    lines = [f"   {name} : constant Integer_Array (0 .. {len(values) - 1}) :=", "     ("]
    for start in range(0, len(values), 10):
        chunk = ", ".join(str(value) for value in values[start:start + 10])
        suffix = "," if start + 10 < len(values) else ""
        lines.append(f"      {chunk}{suffix}")
    lines.append("     );")
    return lines


def ada_transition_array(values: list[tuple[int, int]]) -> list[str]:
    lines = [
        f"   Scanner_Transitions : constant Transition_Array (0 .. {len(values) - 1}) :=",
        "     (",
    ]
    for index, (verify, offset) in enumerate(values):
        suffix = "," if index + 1 < len(values) else ""
        lines.append(f"      {index} => ({verify}, {offset}){suffix}")
    lines.append("     );")
    return lines


def token_identifier(name: str) -> str:
    return "Token_" + name.lower().capitalize()


def ada_keywords(values: list[tuple[str, int, str, str]]) -> list[str]:
    lines = [
        f"   Keywords : constant Keyword_Array (0 .. {len(values) - 1}) :=",
        "     (",
    ]
    for index, (name, token, _category, _label) in enumerate(values):
        if len(name) > 32:
            raise ValueError(f"keyword is longer than 32 bytes: {name}")
        padded = name + " " * (32 - len(name))
        suffix = "," if index + 1 < len(values) else ""
        lines.append(
            f'      {index} => ("{padded}", {len(name)}, {token}){suffix}'
        )
    lines.append("     );")
    return lines


def ada_scanner_actions(values: list[tuple[str, int]]) -> list[str]:
    lines = [
        f"   Scanner_Actions : constant Scanner_Action_Array (1 .. {len(values)}) :=",
        "     (",
    ]
    for index, (kind, argument) in enumerate(values, 1):
        suffix = "," if index < len(values) else ""
        lines.append(f"      {index} => ({kind}, {argument}){suffix}")
    lines.append("     );")
    return lines


def ada_string(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def generate(
    major: int,
    parser_c: Path,
    scanner_c: Path,
    grammar_y: Path,
    scanner_l: Path,
    kwlist: Path,
) -> str:
    parser_source = parser_c.read_text()
    scanner_source = scanner_c.read_text()
    token_rows = tokens(parser_source)
    token_values = dict(token_rows)
    keywords = keyword_rows(kwlist.read_text(), token_values)
    constants = {name: parser_constant(parser_source, name) for name in PARSER_CONSTANTS}
    arrays = {name: c_array(parser_source, name) for name in PARSER_ARRAYS}
    transitions = scanner_transitions(scanner_source)
    starts = scanner_starts(scanner_source)
    actions = scanner_actions(scanner_source, token_values)
    reduction_actions = grammar_action_count(parser_source)

    if len(arrays["yyr1"]) != constants["YYNRULES"] + 1:
        raise ValueError("Bison rule metadata does not match YYNRULES")
    if reduction_actions > constants["YYNRULES"]:
        raise ValueError("more reduction actions than grammar rules")

    lines = [
        "--  Generated by tools/generate_native_parser.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Tables;",
        "use Flyology.Postgres.SQL.Native.Tables;",
        "",
        f"package Flyology.Postgres.SQL.Native.Generated_V{major} is",
        "",
    ]
    for name, value in constants.items():
        lines.append(f"   {name} : constant := {value};")
    for name, value in token_rows:
        lines.append(f"   {token_identifier(name)} : constant := {value};")
    lines.extend([
        f"   Reduction_Action_Count : constant := {reduction_actions};",
        f"   Scanner_Rule_Count : constant := {scanner_rule_count(scanner_source)};",
        f"   Keyword_Count : constant := {len(keywords)};",
        f"   Grammar_SHA256 : constant String := {ada_string(sha256(grammar_y))};",
        f"   Scanner_SHA256 : constant String := {ada_string(sha256(scanner_l))};",
        "",
    ])
    for name in PARSER_ARRAYS:
        lines.extend(ada_integer_array(name.title().replace("_", ""), arrays[name]))
        lines.append("")
    lines.extend(ada_transition_array(transitions))
    lines.append("")
    lines.extend(ada_scanner_actions(actions))
    lines.append("")
    lines.extend(ada_integer_array("Scanner_Starts", starts))
    lines.append("")
    lines.extend(ada_keywords(keywords))
    lines.extend(["", f"end Flyology.Postgres.SQL.Native.Generated_V{major};", ""])
    return "\n".join(lines)


def generate_version_spec(major: int) -> str:
    return f"""--  Generated by tools/generate_native_parser.py.  Do not edit.
with Ada.Strings.Unbounded;
with Flyology.Postgres.SQL.Native.Builders;

package Flyology.Postgres.SQL.Native.Version_V{major} is

   procedure Parse
     (SQL          : String;
      Options      : Parse_Options;
      Build        : aliased in out Builders.Builder;
      Result       : out Builders.Dynamic_Value;
      Error_Offset : out Natural;
      Error_Message : out Ada.Strings.Unbounded.Unbounded_String;
      Success       : out Boolean);

end Flyology.Postgres.SQL.Native.Version_V{major};
"""


def generate_version_body(major: int, parser_source: str) -> str:
    values = dict(tokens(parser_source))

    def token(name: str, default: int = 0) -> int | str:
        return f"Generated.Token_{name.lower().capitalize()}" if name in values else default

    format_token = token("FORMAT") if major >= 16 else 0
    format_la = token("FORMAT_LA") if major >= 16 else 0
    json_token = token("JSON") if "JSON" in values else 0
    without = token("WITHOUT") if major >= 16 else 0
    without_la = token("WITHOUT_LA") if major >= 16 else 0
    return f"""--  Generated by tools/generate_native_parser.py.  Do not edit.
with Flyology.Postgres.SQL.Native.DFA;
with Flyology.Postgres.SQL.Native.Engine;
with Flyology.Postgres.SQL.Native.Generated_V{major};
with Flyology.Postgres.SQL.Native.Actions_V{major};
with Flyology.Postgres.SQL.Native.Scanner;

package body Flyology.Postgres.SQL.Native.Version_V{major} is

   package Generated renames Flyology.Postgres.SQL.Native.Generated_V{major};

   package Version_DFA is new Native.DFA
     (Transitions => Generated.Scanner_Transitions,
      Starts      => Generated.Scanner_Starts);

   package Version_Scanner is new Native.Scanner
     (Lexical_DFA       => Version_DFA,
      Actions           => Generated.Scanner_Actions,
      Keywords          => Generated.Keywords,
      Token_Ident       => Generated.Token_Ident,
      Token_Uident      => Generated.Token_Uident,
      Token_Fconst      => Generated.Token_Fconst,
      Token_Sconst      => Generated.Token_Sconst,
      Token_Usconst     => Generated.Token_Usconst,
      Token_Bconst      => Generated.Token_Bconst,
      Token_Xconst      => Generated.Token_Xconst,
      Token_Op          => Generated.Token_Op,
      Token_Iconst      => Generated.Token_Iconst,
      Token_Param       => Generated.Token_Param,
      Token_Sql_Comment => Generated.Token_Sql_comment,
      Token_C_Comment   => Generated.Token_C_comment,
      Token_Format      => {format_token},
      Token_Format_La   => {format_la},
      Token_Json        => {json_token},
      Token_Not         => Generated.Token_Not,
      Token_Not_La      => Generated.Token_Not_la,
      Token_Between     => Generated.Token_Between,
      Token_In          => Generated.Token_In_p,
      Token_Like        => Generated.Token_Like,
      Token_Ilike       => Generated.Token_Ilike,
      Token_Similar     => Generated.Token_Similar,
      Token_Nulls       => Generated.Token_Nulls_p,
      Token_Nulls_La    => Generated.Token_Nulls_la,
      Token_First       => Generated.Token_First_p,
      Token_Last        => Generated.Token_Last_p,
      Token_With        => Generated.Token_With,
      Token_With_La     => Generated.Token_With_la,
      Token_Without     => {without},
      Token_Without_La  => {without_la},
      Token_Time        => Generated.Token_Time,
      Token_Ordinality  => Generated.Token_Ordinality,
      Token_Uescape     => Generated.Token_Uescape);

   package Version_Engine is new Native.Engine
     (Lexical_Scanner  => Version_Scanner,
      Final_State      => Generated.YYFINAL,
      Last_Table_Index => Generated.YYLAST,
      Terminal_Count   => Generated.YYNTOKENS,
      Maximum_Token    => Generated.YYMAXUTOK,
      Pact_Default     => Generated.YYPACT_NINF,
      Table_Error      => Generated.YYTABLE_NINF,
      Translate        => Generated.Yytranslate,
      Rule_Left        => Generated.Yyr1,
      Rule_Length      => Generated.Yyr2,
      Default_Action   => Generated.Yydefact,
      Default_Goto     => Generated.Yydefgoto,
      Action_Offset    => Generated.Yypact,
      Goto_Offset      => Generated.Yypgoto,
      Action_Table     => Generated.Yytable,
      Action_Check     => Generated.Yycheck,
      Semantic_Reduce  => Native.Actions_V{major}.Reduce);

   procedure Parse
     (SQL          : String;
      Options      : Parse_Options;
      Build        : aliased in out Builders.Builder;
      Result       : out Builders.Dynamic_Value;
      Error_Offset : out Natural;
      Error_Message : out Ada.Strings.Unbounded.Unbounded_String;
      Success       : out Boolean)
   is
      Initial_Token : constant Natural :=
        (case Options.Mode is
            when SQL_Statements       => 0,
            when Type_Name            => Generated.Token_Mode_type_name,
            when PLpgSQL_Expression   => Generated.Token_Mode_plpgsql_expr,
            when PLpgSQL_Assignment_1 => Generated.Token_Mode_plpgsql_assign1,
            when PLpgSQL_Assignment_2 => Generated.Token_Mode_plpgsql_assign2,
            when PLpgSQL_Assignment_3 => Generated.Token_Mode_plpgsql_assign3);
   begin
      Version_Engine.Parse
        (SQL, Options, Initial_Token, Build, Result, Error_Offset,
         Error_Message, Success);
   end Parse;

end Flyology.Postgres.SQL.Native.Version_V{major};
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--major", type=int, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    postgres = args.vendor / "src" / "postgres"
    native = args.vendor / "native_source"
    output = args.output / f"flyology-postgres-sql-native-generated_v{args.major}.ads"
    parser_path = postgres / "src_backend_parser_gram.c"
    contents = generate(
        args.major,
        parser_path,
        postgres / "src_backend_parser_scan.c",
        native / "backend" / "parser" / "gram.y",
        native / "backend" / "parser" / "scan.l",
        native / "include" / "parser" / "kwlist.h",
    )
    version_spec = generate_version_spec(args.major)
    version_body = generate_version_body(args.major, parser_path.read_text())
    spec_output = args.output / f"flyology-postgres-sql-native-version_v{args.major}.ads"
    body_output = args.output / f"flyology-postgres-sql-native-version_v{args.major}.adb"
    if args.check:
        if (not output.exists() or output.read_text() != contents
                or not spec_output.exists() or spec_output.read_text() != version_spec
                or not body_output.exists() or body_output.read_text() != version_body):
            raise SystemExit(f"generated file is stale: {output}")
    else:
        for path, content in (
            (output, contents),
            (spec_output, version_spec),
            (body_output, version_body),
        ):
            if not path.exists() or path.read_text() != content:
                path.write_text(content)
    print(f"{'verified' if args.check else 'generated'} native PostgreSQL {args.major} tables")


if __name__ == "__main__":
    main()
