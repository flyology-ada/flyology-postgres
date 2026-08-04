#!/usr/bin/env python3
"""Generate Ada built-in type metadata from PostgreSQL's pg_type.dat."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


RESERVED = {
    "abort", "abs", "abstract", "accept", "access", "aliased", "all", "and",
    "array", "at", "begin", "body", "case", "constant", "declare", "delay",
    "delta", "digits", "do", "else", "elsif", "end", "entry", "exception",
    "exit", "for", "function", "generic", "goto", "if", "in", "interface",
    "is", "limited", "loop", "mod", "new", "not", "null", "of", "or", "others",
    "out", "overriding", "package", "parallel", "pragma", "private", "procedure",
    "protected", "raise", "range", "record", "rem", "renames", "requeue", "return",
    "reverse", "select", "separate", "some", "subtype", "synchronized", "tagged",
    "task", "terminate", "then", "type", "until", "use", "when", "while", "with",
    "xor",
}

KINDS = {
    "b": "Base_Type", "c": "Composite_Type", "d": "Domain_Type",
    "e": "Enum_Type", "m": "Multirange_Type", "p": "Pseudo_Type",
    "r": "Range_Type",
}
CATEGORIES = {
    "A": "Array_Category", "B": "Boolean_Category", "C": "Composite_Category",
    "D": "Date_Time_Category", "E": "Enum_Category", "G": "Geometric_Category",
    "I": "Network_Category", "N": "Numeric_Category", "P": "Pseudo_Category",
    "R": "Range_Category", "S": "String_Category", "T": "Time_Span_Category",
    "U": "User_Category", "V": "Bit_String_Category", "X": "Unknown_Category",
    "Z": "Internal_Category",
}
STORAGE = {"p": "Plain_Storage", "e": "External_Storage", "x": "Extended_Storage", "m": "Main_Storage"}
ALIGNMENT = {
    "c": "Character_Alignment", "s": "Short_Alignment", "i": "Integer_Alignment",
    "d": "Double_Alignment", "ALIGNOF_POINTER": "Platform_Alignment",
}


@dataclass
class TypeEntry:
    oid: int
    name: str
    array_oid: int
    element_name: str | None
    kind: str
    category: str
    storage: str
    alignment: str
    passing: str
    length_kind: str
    size: int
    preferred: bool


def ada_name(value: str) -> str:
    parts = [part for part in re.split(r"[^A-Za-z0-9]+", value) if part]
    result = "_".join(part[:1].upper() + part[1:].lower() for part in parts) or "Unnamed"
    if result[0].isdigit():
        result = "N_" + result
    if result.lower() in RESERVED:
        result = "Type_" + result
    return result


def record_texts(text: str) -> list[str]:
    #  Catalog comments are Perl-style and may contain unmatched apostrophes;
    #  remove them before applying the quoted-record scanner.
    text = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    result: list[str] = []
    start: int | None = None
    depth = 0
    quoted = False
    escaped = False
    for index, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "'":
                quoted = False
            continue
        if char == "'":
            quoted = True
        elif char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and start is not None:
                result.append(text[start : index + 1])
                start = None
    if depth != 0 or quoted:
        raise ValueError("unterminated record or string in pg_type.dat")
    return result


def fields(record: str) -> dict[str, str]:
    pattern = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=>\s*'((?:\\.|[^'])*)'")
    return {key: value.replace("\\'", "'").replace("\\\\", "\\") for key, value in pattern.findall(record)}


def length(value: str) -> tuple[str, int]:
    if value == "-1":
        return "Variable_Length", 0
    if value == "-2":
        return "Null_Terminated", 0
    if value.isdigit():
        return "Fixed_Length", int(value)
    if value in ("NAMEDATALEN", "SIZEOF_POINTER"):
        return "Platform_Length", 0
    raise ValueError(f"unknown typlen value {value}")


def parse(path: Path) -> list[TypeEntry]:
    explicit: list[TypeEntry] = []
    for source in record_texts(path.read_text()):
        item = fields(source)
        length_kind, size = length(item["typlen"])
        byval = item["typbyval"]
        passing = {"f": "By_Reference", "t": "By_Value", "FLOAT8PASSBYVAL": "Platform_Dependent_Passing"}[byval]
        explicit.append(
            TypeEntry(
                oid=int(item["oid"]),
                name=item["typname"],
                array_oid=int(item.get("array_type_oid", "0")),
                element_name=item.get("typelem"),
                kind=KINDS[item.get("typtype", "b")],
                category=CATEGORIES[item["typcategory"]],
                storage=STORAGE[item.get("typstorage", "p")],
                alignment=ALIGNMENT[item["typalign"]],
                passing=passing,
                length_kind=length_kind,
                size=size,
                preferred=item.get("typispreferred", "f") == "t",
            )
        )

    generated: list[TypeEntry] = []
    for item in explicit:
        if item.array_oid:
            generated.append(
                TypeEntry(
                    oid=item.array_oid,
                    name="_" + item.name,
                    array_oid=0,
                    element_name=item.name,
                    kind="Base_Type",
                    category="Array_Category",
                    storage="Extended_Storage",
                    alignment="Integer_Alignment",
                    passing="By_Reference",
                    length_kind="Variable_Length",
                    size=0,
                    preferred=False,
                )
            )
    result = explicit + generated
    by_oid: dict[int, TypeEntry] = {}
    by_name: dict[str, TypeEntry] = {}
    for item in result:
        if item.oid in by_oid:
            raise ValueError(f"duplicate type OID {item.oid}")
        if item.name in by_name:
            raise ValueError(f"duplicate type name {item.name}")
        by_oid[item.oid] = item
        by_name[item.name] = item
    for item in result:
        if item.element_name and item.element_name not in by_name:
            raise ValueError(f"unknown element type {item.element_name} for {item.name}")
    return sorted(result, key=lambda item: item.oid)


def constant_name(item: TypeEntry) -> str:
    if item.name.startswith("_"):
        return ada_name(item.name[1:]) + "_Array_OID"
    return ada_name(item.name) + "_OID"


def spec(major: int, entries: list[TypeEntry]) -> str:
    lines = [
        "--  Generated by tools/generate_types.py from PostgreSQL pg_type.dat.",
        'pragma Style_Checks ("M200");',
        "",
        f"package Flyology.Postgres.Types.V{major} is",
        "",
    ]
    seen: set[str] = set()
    for item in entries:
        name = constant_name(item)
        if name.lower() in seen:
            raise ValueError(f"Ada constant collision: {name}")
        seen.add(name.lower())
        lines.append(f"   {name} : constant OID := {item.oid};")
    lines.extend([
        "",
        "   function Lookup (Value : OID) return Type_Descriptor;",
        "   function Lookup (Name : String) return Type_Descriptor;",
        "",
        f"end Flyology.Postgres.Types.V{major};",
        "",
    ])
    return "\n".join(lines)


def descriptor(item: TypeEntry, by_name: dict[str, TypeEntry]) -> list[str]:
    element = by_name[item.element_name].oid if item.element_name else 0
    preferred = "True" if item.preferred else "False"
    return [
        f"              (OID_Value       => {item.oid},",
        f'               Name_Value      => To_Unbounded_String ("{item.name}"),',
        f"               Kind_Value      => {item.kind},",
        f"               Category_Value  => {item.category},",
        f"               Storage_Value   => {item.storage},",
        f"               Alignment_Value => {item.alignment},",
        f"               Passing_Value   => {item.passing},",
        f"               Length_Value    => {item.length_kind},",
        f"               Size_Value      => {item.size},",
        f"               Preferred_Value => {preferred},",
        f"               Element_Value   => {element},",
        f"               Array_Value     => {item.array_oid});",
    ]


def body(major: int, entries: list[TypeEntry]) -> str:
    by_name = {item.name: item for item in entries}
    lines = [
        "--  Generated by tools/generate_types.py from PostgreSQL pg_type.dat.",
        'pragma Style_Checks ("M200");',
        "with Ada.Characters.Handling;",
        "with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;",
        "",
        f"package body Flyology.Postgres.Types.V{major} is",
        "",
        "   function Lookup (Value : OID) return Type_Descriptor is",
        "   begin",
        "      case Value is",
    ]
    for item in entries:
        lines.append(f"         when {item.oid} =>")
        lines.append("            return")
        lines.extend(descriptor(item, by_name))
    lines.extend([
        "         when others => return Unknown_Type;",
        "      end case;",
        "   end Lookup;",
        "",
        "   function Lookup (Name : String) return Type_Descriptor is",
        "      Folded : constant String := Ada.Characters.Handling.To_Lower (Name);",
        "   begin",
    ])
    for index, item in enumerate(entries):
        keyword = "if" if index == 0 else "elsif"
        lines.append(f'      {keyword} Folded = "{item.name}" then')
        lines.append(f"         return Lookup ({item.oid});")
    lines.extend([
        "      else",
        "         return Unknown_Type;",
        "      end if;",
        "   end Lookup;",
        "",
        f"end Flyology.Postgres.Types.V{major};",
        "",
    ])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--major", type=int, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    entries = parse(args.catalog)
    args.output.mkdir(parents=True, exist_ok=True)
    stem = f"flyology-postgres-types-v{args.major}"
    generated = {
        args.output / f"{stem}.ads": spec(args.major, entries),
        args.output / f"{stem}.adb": body(args.major, entries),
    }
    for path, contents in generated.items():
        if args.check:
            if not path.exists() or path.read_text() != contents:
                raise SystemExit(f"generated file is stale: {path}")
        else:
            path.write_text(contents)
    action = "verified" if args.check else "generated"
    print(f"{action} PostgreSQL {args.major}: {len(entries)} catalog types")


if __name__ == "__main__":
    main()
