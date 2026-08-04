#!/usr/bin/env python3
"""Generate idiomatic, versioned Ada views from pg_query.proto."""

from __future__ import annotations

import argparse
import dataclasses
import re
from collections import OrderedDict, deque
from pathlib import Path


SCALARS = {
    "bool": "Standard.Boolean",
    "string": "String",
    "bytes": "String",
    "int32": "Interfaces.Integer_32",
    "sint32": "Interfaces.Integer_32",
    "sfixed32": "Interfaces.Integer_32",
    "uint32": "Interfaces.Unsigned_32",
    "fixed32": "Interfaces.Unsigned_32",
    "int64": "Interfaces.Integer_64",
    "sint64": "Interfaces.Integer_64",
    "sfixed64": "Interfaces.Integer_64",
    "uint64": "Interfaces.Unsigned_64",
    "fixed64": "Interfaces.Unsigned_64",
    "float": "Interfaces.IEEE_Float_32",
    "double": "Interfaces.IEEE_Float_64",
}

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


@dataclasses.dataclass
class Field:
    type_name: str
    name: str
    json_name: str
    number: int
    repeated: bool
    oneof: str | None


@dataclasses.dataclass
class Message:
    name: str
    fields: list[Field]


@dataclasses.dataclass
class Enum:
    name: str
    values: list[tuple[str, int]]


def words(name: str) -> list[str]:
    name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    return [part for part in re.split(r"[^A-Za-z0-9]+", name) if part]


def ada_name(name: str) -> str:
    result = "_".join(part[:1].upper() + part[1:].lower() for part in words(name))
    if not result:
        result = "Unnamed"
    if result[0].isdigit():
        result = "N_" + result
    if result.lower() in RESERVED:
        result = "Field_" + result
    return result


MESSAGE_OVERRIDES = {
    "Integer": "Integer_Value",
    "Float": "Float_Value",
    "Boolean": "Boolean_Value",
    "String": "String_Value",
    "BitString": "Bit_String_Value",
    "List": "Node_List_Value",
}


def message_name(name: str) -> str:
    return MESSAGE_OVERRIDES.get(name, ada_name(name))


def reference_name(name: str) -> str:
    return message_name(name) + "_Reference"


def parse_proto(path: Path) -> tuple[OrderedDict[str, Message], OrderedDict[str, Enum]]:
    messages: OrderedDict[str, Message] = OrderedDict()
    enums: OrderedDict[str, Enum] = OrderedDict()
    current_message: Message | None = None
    current_enum: Enum | None = None
    depth = 0
    pending_kind: str | None = None
    pending_name: str | None = None
    current_oneof: str | None = None
    oneof_depth = 0
    field_pattern = re.compile(
        r'^\s*(repeated\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+'
        r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(-?\d+)'
        r'(?:\s+\[json_name="([^"]+)"\])?\s*;'
    )
    enum_pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(-?\d+)\s*;")

    for raw in path.read_text().splitlines():
        line = raw.split("//", 1)[0]
        if depth == 0:
            match = re.match(r"^\s*(message|enum)\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if match:
                pending_kind, pending_name = match.groups()
                if "{" in line:
                    depth = line.count("{") - line.count("}")
                    if pending_kind == "message":
                        current_message = Message(pending_name, [])
                        messages[pending_name] = current_message
                    else:
                        current_enum = Enum(pending_name, [])
                        enums[pending_name] = current_enum
                    pending_kind = pending_name = None
                continue
            if pending_kind and "{" in line:
                depth = line.count("{") - line.count("}")
                if pending_kind == "message":
                    current_message = Message(pending_name or "", [])
                    messages[current_message.name] = current_message
                else:
                    current_enum = Enum(pending_name or "", [])
                    enums[current_enum.name] = current_enum
                pending_kind = pending_name = None
                continue
            continue

        if current_message is not None:
            oneof_match = re.match(
                r"^\s*oneof\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{", line
            )
            if oneof_match:
                current_oneof = oneof_match.group(1)
                oneof_depth = depth + line.count("{") - line.count("}")
            match = field_pattern.match(line)
            if match:
                repeated, type_name, name, number, json_name = match.groups()
                current_message.fields.append(
                    Field(
                        type_name,
                        name,
                        json_name or name,
                        int(number),
                        repeated is not None,
                        current_oneof,
                    )
                )
        elif current_enum is not None and depth == 1:
            match = enum_pattern.match(line)
            if match:
                current_enum.values.append((match.group(1), int(match.group(2))))

        depth += line.count("{") - line.count("}")
        if current_oneof is not None and depth < oneof_depth:
            current_oneof = None
            oneof_depth = 0
        if depth == 0:
            current_message = None
            current_enum = None

    return messages, enums


def reachable_schema(
    messages: OrderedDict[str, Message], enums: OrderedDict[str, Enum]
) -> tuple[list[Message], list[Enum]]:
    reachable_messages: set[str] = set()
    reachable_enums: set[str] = set()
    pending = deque(["ParseResult", "Node"])
    while pending:
        name = pending.popleft()
        if name in reachable_messages or name not in messages:
            continue
        reachable_messages.add(name)
        for field in messages[name].fields:
            if field.type_name in messages:
                pending.append(field.type_name)
            elif field.type_name in enums:
                reachable_enums.add(field.type_name)
            elif field.type_name not in SCALARS:
                raise ValueError(f"unknown protobuf type {field.type_name} in {name}.{field.name}")
    return (
        [value for key, value in messages.items() if key in reachable_messages],
        [value for key, value in enums.items() if key in reachable_enums],
    )


def enum_literal(enum: Enum, value: str) -> str:
    prefix = ada_name(enum.name)
    literal = ada_name(value)
    #  PostgreSQL's protobuf values normally repeat the enum name already
    #  (for example QUERY_SOURCE_UNDEFINED in QuerySource).  Keep one prefix:
    #  it avoids homographs between enum types without producing distinctly
    #  un-Ada-like Query_Source_Query_Source_Undefined identifiers.
    if literal.lower().startswith((prefix + "_").lower()):
        return literal
    return prefix + "_" + literal


def field_type(field: Field, messages: dict[str, Message], enums: dict[str, Enum]) -> str:
    if field.type_name in SCALARS:
        if field.type_name in ("string", "bytes"):
            return "Text"
        return SCALARS[field.type_name]
    if field.type_name in messages:
        return reference_name(field.type_name)
    if field.type_name in enums:
        return ada_name(field.type_name)
    raise AssertionError(field.type_name)


def sequence_name(field: Field, messages: dict[str, Message], enums: dict[str, Enum]) -> str:
    if field.type_name in messages:
        target = message_name(field.type_name)
    else:
        target = field_type(field, messages, enums).replace("Interfaces.", "").replace("Standard.", "")
    return "Sequence_Of_" + target


def accessor_name(field: Field) -> str:
    if field.name == "stmt":
        return "Statement"
    if field.name == "stmts":
        return "Statements"
    return ada_name(field.name)


def optional_name(field: Field, messages: dict[str, Message], enums: dict[str, Enum]) -> str:
    target = field_type(field, messages, enums).replace("Interfaces.", "").replace("Standard.", "")
    return "Optional_" + target


def scalar_expression(field: Field, value_expr: str) -> str:
    target = SCALARS[field.type_name]
    if field.type_name in ("string", "bytes"):
        return f"To_Unbounded_String (Internals.String_Data (Tree, {value_expr}))"
    if field.type_name == "bool":
        return f"Internals.Boolean_Data (Tree, {value_expr})"
    if field.type_name in ("float", "double"):
        return f"{target} (Internals.Float_Data (Tree, {value_expr}))"
    if field.type_name in ("uint32", "fixed32", "uint64", "fixed64"):
        if target == "Interfaces.Unsigned_64":
            return f"Internals.Unsigned_Data (Tree, {value_expr})"
        return f"{target} (Internals.Unsigned_Data (Tree, {value_expr}))"
    if target == "Interfaces.Integer_64":
        return f"Internals.Signed_Data (Tree, {value_expr})"
    return f"{target} (Internals.Signed_Data (Tree, {value_expr}))"


WIRE_TYPES = {
    "bool": "Varint",
    "int32": "Varint",
    "sint32": "Varint",
    "uint32": "Varint",
    "int64": "Varint",
    "sint64": "Varint",
    "uint64": "Varint",
    "fixed64": "Fixed_64",
    "sfixed64": "Fixed_64",
    "double": "Fixed_64",
    "string": "Length_Delimited",
    "bytes": "Length_Delimited",
    "fixed32": "Fixed_32",
    "sfixed32": "Fixed_32",
    "float": "Fixed_32",
}


def decoder_name(name: str) -> str:
    return "Decode_" + message_name(name)


def scalar_decoder(type_name: str, stream: str = "Stream") -> str:
    readers = {
        "bool": f"Store_Boolean (Tree, Read_Varint ({stream}) /= 0)",
        "string": f"Store_Text (Tree, Read_Text ({stream}))",
        "bytes": f"Store_Text (Tree, Read_Text ({stream}))",
        "int32": f"Store_Signed (Tree, Interfaces.Integer_64 (Read_Int_32 ({stream})))",
        "sint32": f"Store_Signed (Tree, Interfaces.Integer_64 (Read_SInt_32 ({stream})))",
        "sfixed32": f"Store_Signed (Tree, Interfaces.Integer_64 (Read_SFixed_32 ({stream})))",
        "uint32": f"Store_Unsigned (Tree, Interfaces.Unsigned_64 (Read_Varint ({stream})))",
        "fixed32": f"Store_Unsigned (Tree, Interfaces.Unsigned_64 (Read_Fixed_32 ({stream})))",
        "int64": f"Store_Signed (Tree, Read_Int_64 ({stream}))",
        "sint64": f"Store_Signed (Tree, Read_SInt_64 ({stream}))",
        "sfixed64": f"Store_Signed (Tree, Read_SFixed_64 ({stream}))",
        "uint64": f"Store_Unsigned (Tree, Read_Varint ({stream}))",
        "fixed64": f"Store_Unsigned (Tree, Read_Fixed_64 ({stream}))",
        "float": f"Store_Float (Tree, Interfaces.IEEE_Float_64 (Read_Float ({stream})))",
        "double": f"Store_Float (Tree, Read_Double ({stream}))",
    }
    return readers[type_name]


def generate_decoder_spec(major: int) -> str:
    return "\n".join([
        "--  Generated by tools/generate_ada.py.  Do not edit.",
        "with System;",
        "",
        f"private package Flyology.Postgres.SQL.Decoder_V{major} is",
        "",
        "   procedure Load",
        "     (Tree : in out Syntax_Tree; Data : System.Address; Length : Natural);",
        "",
        f"end Flyology.Postgres.SQL.Decoder_V{major};",
        "",
    ])


def generate_decoder_body(
    major: int, messages: list[Message], enums: list[Enum]
) -> str:
    message_map = {item.name: item for item in messages}
    enum_map = {item.name: item for item in enums}
    lines = [
        "--  Generated by tools/generate_ada.py.  Do not edit.",
        'pragma Style_Checks ("M160");',
        "with Interfaces;",
        "with Flyology.Postgres.SQL.Decoders; use Flyology.Postgres.SQL.Decoders;",
        "",
        f"package body Flyology.Postgres.SQL.Decoder_V{major} is",
        "",
        "   use type Interfaces.Unsigned_64;",
        "",
    ]

    for message in messages:
        lines.extend([
            f"   procedure {decoder_name(message.name)}",
            "     (Tree : in out Syntax_Tree; Stream : in out Reader; Result : out Value_Id);",
        ])
    lines.append("")

    for enum in enums:
        name = ada_name(enum.name)
        lines.extend([
            f"   function Decode_Enum_{name}",
            "     (Tree : in out Syntax_Tree; Stream : in out Reader) return Value_Id",
            "   is",
            "      Number : constant Interfaces.Integer_32 := Read_Int_32 (Stream);",
            "   begin",
            "      case Number is",
        ])
        for literal, number in enum.values:
            lines.append(f'         when {number} => return Store_Text (Tree, "{literal}");')
        lines.extend([
            f'         when others => raise Decoder_Error with "unknown {name} numeric value";',
            "      end case;",
            f"   end Decode_Enum_{name};",
            "",
        ])

    for message in messages:
        repeated = [field for field in message.fields if field.repeated]
        needs_child = any(
            field.type_name in message_map
            or (field.repeated and
                (field.type_name in enum_map
                 or (field.type_name in SCALARS
                     and field.type_name not in ("string", "bytes"))))
            for field in message.fields
        )
        needs_value = any(
            not field.repeated or field.type_name in message_map
            for field in message.fields
        )
        lines.extend([
            f"   procedure {decoder_name(message.name)}",
            "     (Tree : in out Syntax_Tree; Stream : in out Reader; Result : out Value_Id)",
            "   is",
            "      Members      : Member_Vectors.Vector;",
            "      Field_Number : Positive;",
            "      Encoding     : Wire_Type;",
        ])
        if needs_child:
            lines.append("      Child         : Reader;")
        if needs_value:
            lines.append("      Value         : Value_Id;")
        for field in repeated:
            lines.append(f"      Repeated_{ada_name(field.name)} : Element_Vectors.Vector;")
        lines.extend([
            "   begin",
            "      Result := Begin_Object (Tree);",
            "      while not At_End (Stream) loop",
            "         Read_Key (Stream, Field_Number, Encoding);",
            "         case Field_Number is",
        ])
        for field in message.fields:
            is_message = field.type_name in message_map
            is_enum = field.type_name in enum_map
            expected = (
                "Length_Delimited" if is_message else
                "Varint" if is_enum else WIRE_TYPES[field.type_name]
            )
            lines.append(f"            when {field.number} =>")
            if field.repeated:
                vector = f"Repeated_{ada_name(field.name)}"
                packable = is_enum or (field.type_name in SCALARS and field.type_name not in ("string", "bytes"))
                if packable:
                    lines.append(f"               if Encoding = {expected} then")
                    if is_enum:
                        value = f"Decode_Enum_{ada_name(field.type_name)} (Tree, Stream)"
                    else:
                        value = scalar_decoder(field.type_name)
                    if field.type_name == "uint32":
                        lines.extend([
                            "                  declare",
                            "                     Number : constant Interfaces.Unsigned_64 := Read_Varint (Stream);",
                            "                  begin",
                            "                     if Number > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last) then",
                            '                        raise Decoder_Error with "uint32 value is out of range";',
                            "                     end if;",
                            f"                     {vector}.Append (Store_Unsigned (Tree, Number));",
                            "                  end;",
                        ])
                    else:
                        lines.append(f"                  {vector}.Append ({value});")
                    lines.append("               elsif Encoding = Length_Delimited then")
                    lines.append("                  Read_Embedded (Stream, Child);")
                    lines.append("                  while not At_End (Child) loop")
                    if is_enum:
                        packed_value = f"Decode_Enum_{ada_name(field.type_name)} (Tree, Child)"
                    else:
                        packed_value = scalar_decoder(field.type_name, "Child")
                    if field.type_name == "uint32":
                        lines.extend([
                            "                     declare",
                            "                        Number : constant Interfaces.Unsigned_64 := Read_Varint (Child);",
                            "                     begin",
                            "                        if Number > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last) then",
                            '                           raise Decoder_Error with "uint32 value is out of range";',
                            "                        end if;",
                            f"                        {vector}.Append (Store_Unsigned (Tree, Number));",
                            "                     end;",
                        ])
                    else:
                        lines.append(f"                     {vector}.Append ({packed_value});")
                    lines.extend([
                        "                  end loop;",
                        "               else",
                        f'                  raise Decoder_Error with "invalid wire type for {message.name}.{field.name}";',
                        "               end if;",
                    ])
                else:
                    lines.extend([
                        f"               if Encoding /= {expected} then",
                        f'                  raise Decoder_Error with "invalid wire type for {message.name}.{field.name}";',
                        "               end if;",
                    ])
                    if is_message:
                        lines.extend([
                            "               Read_Embedded (Stream, Child);",
                            f"               {decoder_name(field.type_name)} (Tree, Child, Value);",
                            f"               {vector}.Append (Value);",
                        ])
                    else:
                        lines.append(f"               {vector}.Append ({scalar_decoder(field.type_name)});")
                continue

            lines.extend([
                f"               if Encoding /= {expected} then",
                f'                  raise Decoder_Error with "invalid wire type for {message.name}.{field.name}";',
                "               end if;",
            ])
            if is_message:
                lines.extend([
                    "               Read_Embedded (Stream, Child);",
                    f"               {decoder_name(field.type_name)} (Tree, Child, Value);",
                ])
            elif is_enum:
                lines.append(f"               Value := Decode_Enum_{ada_name(field.type_name)} (Tree, Stream);")
            elif field.type_name == "uint32":
                lines.extend([
                    "               declare",
                    "                  Number : constant Interfaces.Unsigned_64 := Read_Varint (Stream);",
                    "               begin",
                    "                  if Number > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last) then",
                    '                     raise Decoder_Error with "uint32 value is out of range";',
                    "                  end if;",
                    "                  Value := Store_Unsigned (Tree, Number);",
                    "               end;",
                ])
            else:
                lines.append(f"               Value := {scalar_decoder(field.type_name)};")
            if field.oneof is not None:
                for sibling in message.fields:
                    if sibling.oneof == field.oneof and sibling is not field:
                        lines.append(
                            f'               Clear_Member (Members, "{sibling.json_name}");'
                        )
            lines.append(f'               Set_Member (Members, "{field.json_name}", Value);')
        lines.extend([
            "            when others =>",
            "               Skip_Field (Stream, Field_Number, Encoding);",
            "         end case;",
            "      end loop;",
        ])
        for field in repeated:
            vector = f"Repeated_{ada_name(field.name)}"
            lines.extend([
                f"      if not {vector}.Is_Empty then",
                f'         Set_Member (Members, "{field.json_name}", Make_Array (Tree, {vector}));',
                "      end if;",
            ])
        lines.extend([
            "      Finish_Object (Tree, Result, Members);",
            f"   end {decoder_name(message.name)};",
            "",
        ])

    lines.extend([
        "   procedure Load",
        "     (Tree : in out Syntax_Tree; Data : System.Address; Length : Natural)",
        "   is",
        "      Stream : Reader;",
        "   begin",
        "      Initialize (Stream, Data, Length);",
        f"      {decoder_name('ParseResult')} (Tree, Stream, Tree.Root);",
        "      if not At_End (Stream) then",
        '         raise Decoder_Error with "trailing protobuf data";',
        "      end if;",
        "   end Load;",
        "",
        f"end Flyology.Postgres.SQL.Decoder_V{major};",
        "",
    ])
    return "\n".join(lines)


def generate_spec(major: int, messages: list[Message], enums: list[Enum]) -> str:
    message_map = {item.name: item for item in messages}
    enum_map = {item.name: item for item in enums}
    node = message_map["Node"]
    repeated: OrderedDict[str, Field] = OrderedDict()
    optionals: OrderedDict[str, Field] = OrderedDict()
    for message in messages:
        for field in message.fields:
            if field.repeated:
                repeated[sequence_name(field, message_map, enum_map)] = field
            else:
                optionals[optional_name(field, message_map, enum_map)] = field

    lines = [
        "--  Generated by tools/generate_ada.py.  Do not edit.",
        "--  References and sequences are valid only with their owning Syntax_Tree.",
        "--  Views are shallow, owned Ada records; recursive edges remain references.",
        'pragma Style_Checks ("M160");',
        "with Ada.Strings.Unbounded;",
        "with Interfaces;",
        "",
        f"package Flyology.Postgres.SQL.V{major} is",
        "",
        "   subtype Text is Ada.Strings.Unbounded.Unbounded_String;",
        "",
    ]
    for enum in enums:
        literals = [enum_literal(enum, value) for value, _ in enum.values]
        lines.append(f"   type {ada_name(enum.name)} is")
        lines.append("     (" + ",\n      ".join(literals) + ");")
        lines.append("")

    for message in messages:
        lines.append(f"   type {reference_name(message.name)} is private;")
    lines.append("")
    for name in repeated:
        lines.append(f"   type {name} is private;")
    lines.append("")

    for name, field in optionals.items():
        target = field_type(field, message_map, enum_map)
        lines.extend([
            f"   type {name} (Present : Standard.Boolean := False) is record",
            "      case Present is",
            "         when True =>",
            f"            Value : {target};",
            "         when False =>",
            "            null;",
            "      end case;",
            "   end record;",
            "",
        ])

    for message in messages:
        view = message_name(message.name)
        if not message.fields:
            lines.extend([f"   type {view} is null record;", ""])
            continue
        lines.append(f"   type {view} is record")
        for field in message.fields:
            component = accessor_name(field)
            target = (
                sequence_name(field, message_map, enum_map)
                if field.repeated
                else optional_name(field, message_map, enum_map)
            )
            lines.append(f"      {component} : {target};")
        lines.extend(["   end record;", ""])

    kinds = ["Node_" + message_name(field.type_name) for field in node.fields]
    lines.append("   type Node_Kind is")
    lines.append("     (" + ",\n      ".join(kinds) + ");")
    lines.extend([
        "",
        "   function Root (Tree : Syntax_Tree) return Parse_Result_Reference",
        f"     with Pre => Is_Valid (Tree) and then Version (Tree) = PostgreSQL_{major};",
        "   function Kind (Tree : Syntax_Tree; Item : Node_Reference) return Node_Kind;",
        "",
    ])
    for field in node.fields:
        target = message_name(field.type_name)
        lines.append(
            f"   function As_{target} (Tree : Syntax_Tree; Item : Node_Reference) return {target}_Reference"
        )
        lines.append(f"     with Pre => Kind (Tree, Item) = Node_{target};")
    lines.append("")

    for seq_name, field in repeated.items():
        target = field_type(field, message_map, enum_map)
        lines.append(f"   function Length (Tree : Syntax_Tree; Items : {seq_name}) return Natural;")
        lines.append(
            f"   function Element (Tree : Syntax_Tree; Items : {seq_name}; Index : Positive) return {target}"
        )
        lines.append("     with Pre => Index <= Length (Tree, Items);")
        lines.append("")

    for message in messages:
        view = message_name(message.name)
        reference = reference_name(message.name)
        lines.append(f"   function View (Tree : Syntax_Tree; Item : {reference}) return {view};")
    lines.extend([
        "",
        "   function Statements",
        "     (Tree : Syntax_Tree; Item : Parse_Result_Reference) return Sequence_Of_Raw_Stmt;",
        "   function Statement",
        "     (Tree : Syntax_Tree; Item : Raw_Stmt_Reference) return Node_Reference",
        "     with Pre => View (Tree, Item).Statement.Present;",
        "",
    ])

    lines.append("private")
    lines.append("")
    for message in messages:
        lines.append(
            f"   type {reference_name(message.name)} is record Value : Value_Id := No_Value; end record;"
        )
    for name in repeated:
        lines.append(
            f"   type {name} is record Value : Value_Id := No_Value; end record;"
        )
    lines.extend(["", f"end Flyology.Postgres.SQL.V{major};", ""])
    return "\n".join(lines)


def generate_body(major: int, messages: list[Message], enums: list[Enum]) -> str:
    message_map = {item.name: item for item in messages}
    enum_map = {item.name: item for item in enums}
    node = message_map["Node"]
    repeated: OrderedDict[str, Field] = OrderedDict()
    for message in messages:
        for field in message.fields:
            if field.repeated:
                repeated[sequence_name(field, message_map, enum_map)] = field

    lines = [
        "--  Generated by tools/generate_ada.py.  Do not edit.",
        'pragma Style_Checks ("M160");',
        "with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;",
        "with Flyology.Postgres.SQL.Internals;",
        "",
        f"package body Flyology.Postgres.SQL.V{major} is",
        "",
    ]

    for enum in enums:
        enum_name = ada_name(enum.name)
        lines.extend([
            f"   function Decode_{enum_name}",
            f"     (Tree : Syntax_Tree; Value : Value_Id) return {enum_name}",
            "   is",
            "      Text_Value : constant String := Internals.String_Data (Tree, Value);",
            "   begin",
        ])
        for index, (literal, _) in enumerate(enum.values):
            prefix = "if" if index == 0 else "elsif"
            lines.append(f'      {prefix} Text_Value = "{literal}" then')
            lines.append(f"         return {enum_literal(enum, literal)};")
        lines.extend([
            "      else",
            f'         raise Constraint_Error with "unknown {enum_name} value: " & Text_Value;',
            "      end if;",
            f"   end Decode_{enum_name};",
            "",
        ])

    lines.extend([
        "   function Root (Tree : Syntax_Tree) return Parse_Result_Reference is",
        "     (Value => Internals.Root (Tree));",
        "",
        "   function Kind (Tree : Syntax_Tree; Item : Node_Reference) return Node_Kind is",
        "      Name : constant String := Internals.Only_Field_Name (Tree, Item.Value);",
        "   begin",
    ])
    for index, field in enumerate(node.fields):
        prefix = "if" if index == 0 else "elsif"
        target = message_name(field.type_name)
        json_name = field.json_name
        lines.append(f'      {prefix} Name = "{json_name}" then')
        lines.append(f"         return Node_{target};")
    lines.extend([
        "      else",
        "         raise Constraint_Error with \"unknown PostgreSQL node kind: \" & Name;",
        "      end if;",
        "   end Kind;",
        "",
    ])
    for field in node.fields:
        target = message_name(field.type_name)
        lines.extend([
            f"   function As_{target}",
            f"     (Tree : Syntax_Tree; Item : Node_Reference) return {target}_Reference is",
            "     (Value => Internals.Only_Field_Value (Tree, Item.Value));",
            "",
        ])

    for seq_name, field in repeated.items():
        target = field_type(field, message_map, enum_map)
        lines.extend([
            f"   function Length (Tree : Syntax_Tree; Items : {seq_name}) return Natural is",
            "     (Internals.Length (Tree, Internals.To_Sequence (Tree, Items.Value)));",
            "",
            f"   function Element (Tree : Syntax_Tree; Items : {seq_name}; Index : Positive) return {target} is",
        ])
        value_expr = "Internals.Element (Tree, Internals.To_Sequence (Tree, Items.Value), Index)"
        if field.type_name in SCALARS:
            lines.append(f"     ({scalar_expression(field, value_expr)});")
        elif field.type_name in message_map:
            lines.append(f"     (Value => {value_expr});")
        else:
            lines.append(f"     (Decode_{ada_name(field.type_name)} (Tree, {value_expr}));")
        lines.append("")

    for message in messages:
        view = message_name(message.name)
        reference = reference_name(message.name)
        lines.append(f"   function View (Tree : Syntax_Tree; Item : {reference}) return {view} is")
        if not message.fields:
            lines.extend(["     (null record);", ""])
            continue
        lines.append("     (")
        for field in message.fields:
            component = accessor_name(field)
            field_expr = f'Internals.Field (Tree, Item.Value, "{field.json_name}")'
            comma = "," if field is not message.fields[-1] else ");"
            if field.repeated:
                lines.extend([
                    f"      {component} =>",
                    "        (Value =>",
                    f'           (if Internals.Has_Field (Tree, Item.Value, "{field.json_name}")',
                    f"            then {field_expr}",
                    f"            else No_Value)){comma}",
                ])
                continue

            lines.extend([
                f"      {component} =>",
                f'        (if Internals.Has_Field (Tree, Item.Value, "{field.json_name}") then',
                "            (Present => True,",
            ])
            if field.type_name in SCALARS:
                value = scalar_expression(field, field_expr)
            elif field.type_name in message_map:
                value = f"(Value => {field_expr})"
            else:
                value = f"Decode_{ada_name(field.type_name)} (Tree, {field_expr})"
            lines.extend([
                f"             Value   => {value})",
                f"         else (Present => False)){comma}",
            ])
        lines.append("")

    lines.extend([
        "   function Statements",
        "     (Tree : Syntax_Tree; Item : Parse_Result_Reference) return Sequence_Of_Raw_Stmt is",
        "     (View (Tree, Item).Statements);",
        "",
        "   function Statement",
        "     (Tree : Syntax_Tree; Item : Raw_Stmt_Reference) return Node_Reference is",
        "     (View (Tree, Item).Statement.Value);",
        "",
    ])
    lines.extend([f"end Flyology.Postgres.SQL.V{major};", ""])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--major", type=int, required=True)
    parser.add_argument("--proto", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    messages, enums = parse_proto(args.proto)
    selected_messages, selected_enums = reachable_schema(messages, enums)
    args.output.mkdir(parents=True, exist_ok=True)
    stem = f"flyology-postgres-sql-v{args.major}"
    generated = {
        args.output / f"{stem}.ads": generate_spec(
            args.major, selected_messages, selected_enums
        ),
        args.output / f"{stem}.adb": generate_body(
            args.major, selected_messages, selected_enums
        ),
        args.output / f"flyology-postgres-sql-decoder_v{args.major}.ads":
            generate_decoder_spec(args.major),
        args.output / f"flyology-postgres-sql-decoder_v{args.major}.adb":
            generate_decoder_body(args.major, selected_messages, selected_enums),
    }
    for path, contents in generated.items():
        if args.check:
            if not path.exists() or path.read_text() != contents:
                raise SystemExit(f"generated file is stale: {path}")
        else:
            path.write_text(contents)
    print(
        f"{'verified' if args.check else 'generated'} PostgreSQL {args.major}: "
        f"{len(selected_messages)} messages, {len(selected_enums)} enums"
    )


if __name__ == "__main__":
    main()
