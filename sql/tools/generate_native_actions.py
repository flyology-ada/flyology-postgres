#!/usr/bin/env python3
"""Compile PostgreSQL Bison semantic actions into native Ada operations.

Clang supplies a typed AST for the exact generated parser snapshot.  This
tool deliberately emits only the constrained statement/expression vocabulary
used by PostgreSQL's reduction switch and fails when a new construct appears.
That makes an upstream grammar change an explicit generator task rather than
an unnoticed semantic approximation.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


PASSTHROUGH = {"ImplicitCastExpr", "ParenExpr", "ConstantExpr"}
ACTION_CHUNK_COUNT = 14
HELPER_CHUNK_COUNT = 3
SUPPORTED_MAJORS = (14, 15, 16, 17, 18)
#  These helpers manipulate PostgreSQL's version-dependent anonymous unions.
#  The generic Clang-AST lowering cannot preserve that lvalue identity through
#  the flattened dynamic builder, so Native.Semantics implements them against
#  the normalized builder field paths.
HANDWRITTEN_HELPERS = {"doNegate", "doNegateFloat"}


def children(node: dict) -> list[dict]:
    return node.get("inner", [])


def walk(node: dict):
    yield node
    for child in children(node):
        yield from walk(child)


def clang_ast_path(vendor: Path, source_path: Path) -> tuple[dict, str]:
    postgres = vendor / "src" / "postgres"
    command = [
        "clang", "-std=gnu99", "-fsyntax-only",
        f"-I{vendor}", f"-I{vendor / 'vendor'}",
        f"-I{vendor / 'src' / 'include'}",
        f"-I{postgres / 'include'}",
        "-Xclang", "-ast-dump=json", str(source_path),
    ]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(result.stdout), source_path.read_text()


def clang_ast(vendor: Path) -> tuple[dict, str]:
    return clang_ast_path(
        vendor, vendor / "src" / "postgres" / "src_backend_parser_gram.c"
    )


def semantic_switch(root: dict) -> dict:
    parser = next(
        node for node in walk(root)
        if node.get("kind") == "FunctionDecl"
        and node.get("name") == "base_yyparse"
        and any(child.get("kind") == "CompoundStmt" for child in children(node))
    )
    candidates = []
    for node in walk(parser):
        if node.get("kind") == "SwitchStmt":
            count = sum(item.get("kind") == "CaseStmt" for item in walk(node))
            candidates.append((count, node))
    if not candidates or max(item[0] for item in candidates) < 100:
        raise ValueError("Bison semantic reduction switch was not found")
    return max(candidates, key=lambda item: item[0])[1]


def constant_value(node: dict) -> int:
    for item in walk(node):
        if item.get("kind") == "ConstantExpr" and "value" in item:
            return int(item["value"], 0)
    for item in walk(node):
        if item.get("kind") in {"IntegerLiteral", "CharacterLiteral"}:
            value = item["value"]
            return int(value, 0) if isinstance(value, str) else int(value)
    raise ValueError("integer constant has no literal")


def reduction_cases(switch: dict) -> list[tuple[int, dict]]:
    result = []
    pending = list(reversed(children(switch)))
    while pending:
        node = pending.pop()
        if node.get("kind") == "SwitchStmt":
            continue
        if node.get("kind") != "CaseStmt":
            pending.extend(reversed(children(node)))
            continue
        parts = children(node)
        if len(parts) < 2:
            continue
        body = parts[1]
        if body.get("kind") == "CaseStmt":
            continue
        try:
            rule = constant_value(parts[0])
        except ValueError:
            continue
        result.append((rule, body))
        pending.extend(reversed(children(body)))
    return sorted(result, key=lambda item: item[0])


def referenced_name(node: dict) -> str | None:
    for item in walk(node):
        reference = item.get("referencedDecl", {})
        if reference.get("kind") in {
            "FunctionDecl", "VarDecl", "ParmVarDecl", "EnumConstantDecl"
        }:
            return reference.get("name")
    return None


def point_offset(point: dict) -> tuple[int, int] | None:
    if "expansionLoc" in point:
        point = point["expansionLoc"]
    if "offset" not in point:
        return None
    return point["offset"], point.get("tokLen", 1)


class Emitter:
    def __init__(self, source: str, enums: dict[str, int], major: int):
        self.source = source
        self.enums = enums
        self.major = major
        self.locals: dict[str, int] = {}
        self.local_names: dict[str, int] = {}
        self.unsupported = Counter()
        self.unsupported_examples: dict[str, str] = {}
        self.in_generated_helper = False
        self.loop_labels: list[str] = []
        self.loop_counter = 0

    def unsupported_item(self, name: str, node: dict) -> None:
        self.unsupported[name] += 1
        self.unsupported_examples.setdefault(name, re.sub(r"\s+", " ", self.text(node))[:160])

    def text(self, node: dict) -> str:
        area = node.get("range", {})
        begin = point_offset(area.get("begin", {}))
        end = point_offset(area.get("end", {}))
        if begin is None or end is None:
            return ""
        return self.source[begin[0]:end[0] + end[1]]

    def rhs_reference(self, node: dict) -> str | None:
        if node.get("kind") not in {"MemberExpr", "ArraySubscriptExpr"}:
            return None
        if node.get("kind") == "MemberExpr":
            #  Macro-expanded linitial()/lfirst() expressions still contain
            #  yyvsp text, but the surrounding list navigation is semantic.
            #  Collapsing such a member to Values(N) loses both the selected
            #  list element and its scalar member (for example
            #  intVal(linitial($6)) in CREATE TRIGGER).
            if any(
                item.get("referencedDecl", {}).get("name")
                in {"list_head", "list_nth_cell"}
                for item in walk(node)
            ):
                return None
            member_count = 0
            current = node
            while current.get("kind") == "MemberExpr":
                member_count += 1
                current = children(current)[0]
                while current.get("kind") in PASSTHROUGH and children(current):
                    current = children(current)[0]
            if member_count > 1:
                return None
            #  Only the semantic-union selector immediately above yyvsp is
            #  the stack value.  An enclosing member through a cast or a
            #  conditional still has to be evaluated (for example choosing a
            #  JsonAgg node and then selecting its constructor field).
            if current.get("kind") != "ArraySubscriptExpr":
                return None
        value = re.sub(r"\s+", "", self.text(node))
        match = re.search(r"yyvsp\[\((\d+)\)-\((\d+)\)\]", value)
        if match:
            return f"Values ({int(match.group(1))})"
        match = re.search(r"yylsp\[\((\d+)\)-\((\d+)\)\]", value)
        if match:
            return (
                "Builders.Number (Interfaces.Integer_64 "
                f"(Locations ({int(match.group(1))})))"
            )
        for item in walk(node):
            if item.get("kind") != "ArraySubscriptExpr":
                continue
            parts = children(item)
            if len(parts) != 2:
                continue
            base_name = referenced_name(parts[0])
            literals = [
                int(value["value"], 0)
                for value in walk(parts[1])
                if value.get("kind") == "IntegerLiteral"
            ]
            if not literals:
                continue
            if base_name == "yyvsp":
                return f"Values ({literals[0]})"
            if base_name == "yylsp":
                return (
                    "Builders.Number (Interfaces.Integer_64 "
                    f"(Locations ({literals[0]})))"
                )
        return None

    def call_name(self, node: dict) -> str:
        name = referenced_name(children(node)[0]) if children(node) else None
        if name is None:
            raise ValueError("indirect semantic helper call is unsupported")
        return name

    @staticmethod
    def node_tag_name(node: dict) -> str | None:
        """Return the source NodeTag name retained by clang below IsA()."""
        for item in walk(node):
            reference = item.get("referencedDecl", {})
            name = reference.get("name", "")
            if reference.get("kind") == "EnumConstantDecl" and name.startswith("T_"):
                return name.removeprefix("T_")
        return None

    def node_type_operand(self, node: dict) -> str | None:
        """Return the value whose Node.type member is being inspected."""
        current = node
        while current.get("kind") in PASSTHROUGH and children(current):
            current = children(current)[0]
        if current.get("kind") != "MemberExpr" or current.get("name") != "type":
            return None
        return self.expression(children(current)[0])

    def member_path(self, node: dict) -> tuple[dict, str]:
        names = []
        current = node
        while current.get("kind") == "MemberExpr":
            names.append(current.get("name", ""))
            current = children(current)[0]
            while current.get("kind") in PASSTHROUGH and children(current):
                current = children(current)[0]
        ordered = list(reversed(names))
        if (referenced_name(current) == "yyval" or
                self.rhs_reference(current) is not None):
            ordered = ordered[1:]
        return current, ".".join(ordered)

    def member_target(self, node: dict) -> tuple[str, str]:
        """Return the dynamic object and flattened field path for a C member.

        PostgreSQL embeds structs and unions with `.`, which the dynamic
        builder stores as flattened dotted names.  A later `->` crosses into
        another protobuf object and must instead dereference the accumulated
        field before continuing.
        """
        members: list[tuple[str, bool]] = []
        current = node
        while current.get("kind") == "MemberExpr":
            members.append(
                (current.get("name", ""), bool(current.get("isArrow", False)))
            )
            current = children(current)[0]
            while current.get("kind") in PASSTHROUGH and children(current):
                current = children(current)[0]
        ordered = list(reversed(members))
        if (
            referenced_name(current) == "yyval"
            or self.rhs_reference(current) is not None
        ):
            ordered = ordered[1:]

        target = self.expression(current)
        path: list[str] = []
        for name, is_arrow in ordered:
            if is_arrow and path:
                target = f'Build.Field ({target}, "{".".join(path)}")'
                path = []
            path.append(name)
        return target, ".".join(path)

    def arguments(self, values: list[str]) -> str:
        if not values:
            return "Semantics.No_Arguments"
        return "(" + ", ".join(
            f"{index} => {value}" for index, value in enumerate(values, 1)
        ) + ")"

    def foreach_arguments(self, node: dict) -> tuple[str, str] | None:
        source = self.text(node).lstrip()
        match = re.match(r"foreach\s*\(", source)
        if match is None:
            return None
        start = match.end()
        depth = 0
        comma = None
        for position in range(start, len(source)):
            character = source[position]
            if character == "(":
                depth += 1
            elif character == ")":
                if depth == 0:
                    if comma is None:
                        return None
                    return source[start:comma].strip(), source[comma + 1:position].strip()
                depth -= 1
            elif character == "," and depth == 0 and comma is None:
                comma = position
        return None

    def foreach_list(self, source: str) -> str | None:
        compact = re.sub(r"\s+", "", source)
        match = re.search(r"yyvsp\[\((\d+)\)-\((\d+)\)\]", compact)
        if match:
            return f"Values ({int(match.group(1))})"
        while compact.startswith("(") and compact.endswith(")"):
            compact = compact[1:-1]
        path_parts = compact.split("->")
        if path_parts[0] not in self.local_names:
            return None
        result = f"Locals ({self.local_names[path_parts[0]]})"
        if len(path_parts) > 1:
            result = f'Build.Field ({result}, "{".".join(path_parts[1:])}")'
        return result

    def expression(self, node: dict) -> str:
        source_text = self.text(node).strip()
        make_node = re.fullmatch(
            r"makeNode\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)",
            source_text,
        )
        if make_node is not None:
            return f'Build.New_Object ("{make_node.group(1)}")'
        #  A protobuf semantic-union selector directly denotes the stack
        #  value.  ListCell's ptr/int/oid selectors are different: they must
        #  first preserve the macro-expanded list navigation below them.
        is_cell_selector = (
            node.get("kind") == "MemberExpr"
            and node.get("name") in {"ptr_value", "int_value", "oid_value"}
        )
        special = None if is_cell_selector else self.rhs_reference(node)
        if special is not None:
            return special
        kind = node.get("kind")
        parts = children(node)
        if kind in PASSTHROUGH:
            return self.expression(parts[0]) if parts else "Builders.No_Value"
        if kind == "IntegerLiteral":
            return f"Builders.Number ({node['value']})"
        if kind == "CharacterLiteral":
            return f"Builders.Number ({node['value']})"
        if kind == "StringLiteral":
            raw = node.get("value", "")
            try:
                value = ast.literal_eval (raw)
            except (SyntaxError, ValueError):
                value = raw
            value = value.replace('"', '""')
            return f'Builders.Text ("{value}")'
        if kind == "DeclRefExpr":
            reference = node.get("referencedDecl", {})
            identifier = reference.get("id")
            name = reference.get("name", "")
            if identifier in self.locals:
                return f"Locals ({self.locals[identifier]})"
            if name in self.enums:
                return f"Builders.Number ({self.enums[name]})"
            if name in {"yyval", "yyloc"}:
                return (
                    "Result" if name == "yyval"
                    else "Builders.Number (Interfaces.Integer_64 (Location))"
                )
            if name in {"NIL", "NULL"}:
                return "Builders.No_Value"
            if name == "yynerrs":
                return "Builders.Number (0)"
            if name == "yyscanner":
                return "Builders.No_Value"
            self.unsupported[f"reference:{name}"] += 1
            return "Builders.No_Value"
        if kind == "CStyleCastExpr":
            if parts:
                target_type = node.get("type", {}).get("qualType", "")
                if parts[0].get("kind") == "StmtExpr" and target_type.endswith(" *"):
                    type_name = re.sub(r"\s*\*+$", "", target_type)
                    type_name = type_name.removeprefix("struct ")
                    if type_name not in {"Node", "void"}:
                        return f'Build.New_Object ("{type_name}")'
                if self.text(node).strip() == "makeNode":
                    type_name = node.get("type", {}).get("qualType", "Node *")
                    type_name = re.sub(r"\s*\*+$", "", type_name).removeprefix("struct ")
                    return f'Build.New_Object ("{type_name}")'
                value = self.expression(parts[0])
                if value == "Builders.Number (0)" and "*" in node.get("type", {}).get("qualType", ""):
                    return "Builders.No_Value"
                return value
            return "Builders.No_Value"
        if kind == "MemberExpr":
            name = node.get("name", "")
            base = self.expression(parts[0])
            if name in {"ptr_value", "int_value", "oid_value"}:
                return f"Build.Cell_Element ({base})"
            if name == "parsetree":
                return "Parse_Result"
            target, path = self.member_target(node)
            return target if not path else f'Build.Field ({target}, "{path}")'
        if kind == "CallExpr":
            name = self.call_name(node)
            args = [self.expression(item) for item in parts[1:]]
            if name == "newNode":
                type_name = "Node"
                for item in walk(node):
                    arg_type = item.get("argType", {}).get("qualType")
                    if arg_type:
                        type_name = arg_type.removeprefix("struct ")
                        break
                return f'Build.New_Object ("{type_name}")'
            if name == "palloc" and parts[1:]:
                type_name = "Temporary"
                for item in walk(parts[1]):
                    arg_type = item.get("argType", {}).get("qualType")
                    if arg_type:
                        type_name = arg_type.removeprefix("struct ")
                        break
                return f'Build.New_Object ("__{type_name}")'
            return f"Invoke (Build, \"{name}\", {self.arguments(args)})"
        if kind == "BinaryOperator":
            operator = node.get("opcode", "")
            if operator == "=":
                if parts[0].get("kind") == "MemberExpr":
                    member = parts[0]
                    target, path = self.member_target(member)
                    return (
                        "Semantics.Set_Field (Build, "
                        f"{target}, "
                        f'"{path}", {self.expression(parts[1])})'
                    )
                self.unsupported_item("assignment-expression", node)
                return self.expression(parts[-1])
            if operator in {"==", "!="}:
                left_type = self.node_type_operand(parts[0])
                right_type = self.node_type_operand(parts[1])
                left_tag = self.node_tag_name(parts[0])
                right_tag = self.node_tag_name(parts[1])
                if left_type is not None and right_tag is not None:
                    result = (
                        f'Semantics.Node_Is (Build, {left_type}, "{right_tag}")'
                    )
                    return result if operator == "==" else f'Semantics.Unary ("!", {result})'
                if right_type is not None and left_tag is not None:
                    result = (
                        f'Semantics.Node_Is (Build, {right_type}, "{left_tag}")'
                    )
                    return result if operator == "==" else f'Semantics.Unary ("!", {result})'
            return (
                f'Semantics.Binary ("{operator}", {self.expression(parts[0])}, '
                f"{self.expression(parts[1])})"
            )
        if kind == "ConditionalOperator":
            return (
                f"(if Semantics.Truth ({self.expression(parts[0])}) then "
                f"{self.expression(parts[1])} else {self.expression(parts[2])})"
            )
        if kind == "UnaryOperator":
            operator = node.get("opcode", "")
            if operator == "&" and parts and parts[0].get("kind") == "MemberExpr":
                member = parts[0]
                target, path = self.member_target(member)
                return (
                    f'Builders.Field_Reference ({target}, '
                    f'"{path}")'
                )
            if operator == "*":
                return f"Build.Dereference ({self.expression(parts[0])})"
            return f'Semantics.Unary ("{operator}", {self.expression(parts[0])})'
        if kind == "UnaryExprOrTypeTraitExpr":
            return "Builders.Number (0)"
        if kind == "ArraySubscriptExpr":
            self.unsupported_item("array-subscript", node)
            return "Builders.No_Value"
        if kind in {"CompoundLiteralExpr", "InitListExpr"}:
            values = [self.expression(item) for item in parts]
            return values[-1] if values else "Builders.No_Value"
        if kind == "StmtExpr" and parts:
            body = parts[-1]
            declarations = [
                item for item in walk(body) if item.get("kind") == "VarDecl"
                and item.get("name") == "_result"
            ]
            if declarations and children(declarations[0]):
                return self.expression(children(declarations[0])[-1])
            return "Builders.No_Value"
        if kind == "PredefinedExpr":
            return 'Builders.Text ("generated PostgreSQL grammar")'
        self.unsupported[f"expression:{kind}"] += 1
        return "Builders.No_Value"

    def lvalue(self, node: dict, value: str, indent: str) -> list[str]:
        special = self.rhs_reference(node)
        kind = node.get("kind")
        parts = children(node)
        if kind in PASSTHROUGH and parts:
            return self.lvalue(parts[0], value, indent)
        if kind == "DeclRefExpr":
            reference = node.get("referencedDecl", {})
            identifier = reference.get("id")
            name = reference.get("name", "")
            if identifier in self.locals:
                return [f"{indent}Locals ({self.locals[identifier]}) := {value};"]
            if name == "yyval":
                return [f"{indent}Result := {value};"]
            if name == "yyloc":
                return [f"{indent}Location := Integer (Semantics.Integer_Of ({value}));"]
        if kind == "MemberExpr":
            target, path = self.member_target(node)
            if target == "Result" and not path:
                return [f"{indent}Result := {value};"]
            if node.get("name") == "parsetree":
                return [f"{indent}Parse_Result := {value};"]
            return [
                f'{indent}Build.Set_Field ({target}, '
                f'"{path}", {value});'
            ]
        if kind == "UnaryOperator" and node.get("opcode") == "*":
            return [f"{indent}Build.Assign ({self.expression(parts[0])}, {value});"]
        if special is not None:
            self.unsupported["rhs-assignment"] += 1
            return []
        self.unsupported_item(f"lvalue:{kind}", node)
        return []

    def statement(self, node: dict, indent: str = "               ") -> list[str]:
        kind = node.get("kind")
        parts = children(node)
        if kind == "CompoundStmt":
            result = []
            for item in parts:
                result.extend(self.statement(item, indent))
            return result
        if kind in {"NullStmt", "BreakStmt"}:
            return []
        if kind == "DeclStmt":
            result = []
            for declaration in parts:
                identifier = declaration.get("id", "")
                slot = self.locals.setdefault(identifier, len(self.locals) + 1)
                if declaration.get("name"):
                    self.local_names[declaration["name"]] = slot
                initializers = children(declaration)
                if initializers:
                    result.append(
                        f"{indent}Locals ({slot}) := {self.expression(initializers[-1])};"
                    )
            return result
        if kind == "BinaryOperator" and node.get("opcode") == "=":
            return self.lvalue(parts[0], self.expression(parts[1]), indent)
        if kind == "IfStmt":
            result = [f"{indent}if Semantics.Truth ({self.expression(parts[0])}) then"]
            result.extend(self.statement(parts[1], indent + "   "))
            if len(parts) > 2:
                result.append(f"{indent}else")
                result.extend(self.statement(parts[2], indent + "   "))
            result.append(f"{indent}end if;")
            return result
        if kind == "CallExpr":
            return [f"{indent}declare", f"{indent}   Ignored : constant Builders.Dynamic_Value :=",
                    f"{indent}     {self.expression(node)};", f"{indent}begin", f"{indent}   null;", f"{indent}end;"]
        if kind == "ParenExpr" and parts:
            return self.statement(parts[0], indent)
        if kind == "CompoundAssignOperator":
            operator = node.get("opcode", "")[:-1]
            value = (
                f'Semantics.Binary ("{operator}", {self.expression(parts[0])}, '
                f"{self.expression(parts[1])})"
            )
            return self.lvalue(parts[0], value, indent)
        if kind == "UnaryOperator" and node.get("opcode") in {"++", "--"}:
            operator = "+" if node.get("opcode") == "++" else "-"
            value = (
                f'Semantics.Binary ("{operator}", {self.expression(parts[0])}, '
                "Builders.Number (1))"
            )
            return self.lvalue(parts[0], value, indent)
        if kind == "CStyleCastExpr" and node.get("type", {}).get("qualType") == "void":
            return []
        if kind == "DoStmt":
            messages = [
                item for item in walk(node)
                if item.get("kind") == "CallExpr" and referenced_name(children(item)[0]) == "errmsg"
            ]
            if messages and len(children(messages[0])) > 1:
                arguments = [
                    self.expression(item) for item in children(messages[0])[1:]
                ]
                message = arguments[0]
                if len(arguments) > 1:
                    message = (
                        'Invoke (Build, "psprintf", '
                        f"{self.arguments(arguments)})"
                    )
                positions = [
                    item for item in walk(node)
                    if item.get("kind") == "CallExpr"
                    and referenced_name(children(item)[0])
                    in {"parser_errposition", "scanner_errposition"}
                ]
                #  The pinned PostgreSQL 14 through 17 C oracles do not
                #  preserve parser_errposition from grammar helper functions.
                #  PostgreSQL 18 does, while direct reduction actions preserve
                #  it in every supported major.
                positioned = positions and (
                    not self.in_generated_helper or self.major >= 18
                )
                if positioned and len(children(positions[0])) > 1:
                    position = self.expression(children(positions[0])[1])
                    return [
                        f"{indent}Error_Location.all := Integer (Semantics.Integer_Of ({position}));",
                        f"{indent}raise Action_Catalog.Positioned_Error with Semantics.Text_Of ({message});",
                    ]
                return [
                    f"{indent}raise Action_Catalog.Unpositioned_Error with Semantics.Text_Of ({message});"
                ]
            if self.text(node).lstrip().startswith("elog"):
                return [f'{indent}raise Semantics.Parser_Error with "internal parser error";']
            self.unsupported_item("do-statement", node)
            return []
        if kind == "ContinueStmt":
            if not self.loop_labels:
                self.unsupported_item("continue-outside-loop", node)
                return []
            return [f"{indent}goto {self.loop_labels[-1]};"]
        if kind == "ReturnStmt":
            value = self.expression(parts[0]) if parts else "Builders.No_Value"
            return [f"{indent}return {value};"]
        if kind == "ForStmt" and self.text(node).lstrip().startswith("foreach"):
            arguments = self.foreach_arguments(node)
            if arguments is None:
                self.unsupported_item("foreach-macro", node)
                return []
            cell_name, list_source = arguments
            if cell_name not in self.local_names:
                self.unsupported_item("foreach-cell", node)
                return []
            slot = self.local_names[cell_name]
            list_value = self.foreach_list(list_source)
            if list_value is None:
                self.unsupported_item("foreach-list", node)
                return []
            declaration = next(
                (item for item in walk(parts[0]) if item.get("kind") == "VarDecl"),
                None,
            )
            if declaration is not None:
                self.locals[declaration.get("id", "")] = slot
            self.loop_counter += 1
            label = f"Continue_Loop_{self.loop_counter}"
            result = [
                f"{indent}declare",
                f"{indent}   Loop_List : constant Builders.Dynamic_Value := {list_value};",
                f"{indent}begin",
                f"{indent}   for Loop_Index in 1 .. Build.Length (Loop_List) loop",
                f"{indent}      Locals ({slot}) := Build.Cell (Loop_List, Loop_Index);",
            ]
            self.loop_labels.append(label)
            result.extend(self.statement(parts[-1], indent + "      "))
            self.loop_labels.pop()
            result.extend([
                f"{indent}      <<{label}>>",
                f"{indent}      null;",
                f"{indent}   end loop;",
                f"{indent}end;",
            ])
            return result
        if kind == "SwitchStmt" and "ROLESPEC_CSTRING" in self.text(node):
            condition = self.expression(parts[0])
            return [
                f"{indent}if Semantics.Integer_Of ({condition}) =",
                f"{indent}  {self.enums['ROLESPEC_CSTRING']}",
                f"{indent}then",
                f'{indent}   Result := Build.Field (Values (1), "rolename");',
                f"{indent}else",
                f'{indent}   raise Semantics.Parser_Error with "reserved role name";',
                f"{indent}end if;",
            ]
        if kind == "SwitchStmt" and "list_length" in self.text(node):
            if not self.in_generated_helper:
                return [
                    f"{indent}case Build.Length (Values (2)) is",
                    f"{indent}   when 1 =>",
                    f'{indent}      Build.Set_Field (Result, "catalogname", Builders.No_Value);',
                    f'{indent}      Build.Set_Field (Result, "schemaname", Values (1));',
                    f'{indent}      Build.Set_Field (Result, "relname",',
                    f'{indent}        Build.Field (Build.Element (Values (2), 1), "sval"));',
                    f"{indent}   when 2 =>",
                    f'{indent}      Build.Set_Field (Result, "catalogname", Values (1));',
                    f'{indent}      Build.Set_Field (Result, "schemaname",',
                    f'{indent}        Build.Field (Build.Element (Values (2), 1), "sval"));',
                    f'{indent}      Build.Set_Field (Result, "relname",',
                    f'{indent}        Build.Field (Build.Element (Values (2), 2), "sval"));',
                    f"{indent}   when others =>",
                    f'{indent}      raise Semantics.Parser_Error with "improper qualified name";',
                    f"{indent}end case;",
                ]
            qualified = "list_length(namelist)" in self.text(node)
            names = f"Locals ({2 if qualified else 1})"
            target = f"Locals ({5 if qualified else 4})"
            name = "Locals (1)"
            if qualified:
                return [
                f"{indent}case Build.Length ({names}) is",
                f"{indent}   when 1 =>",
                f'{indent}      Build.Set_Field ({target}, "catalogname", Builders.No_Value);',
                f'{indent}      Build.Set_Field ({target}, "schemaname", {name});',
                f'{indent}      Build.Set_Field ({target}, "relname",',
                f'{indent}        Build.Field (Build.Element ({names}, 1), "sval"));',
                f"{indent}   when 2 =>",
                f'{indent}      Build.Set_Field ({target}, "catalogname", {name});',
                f'{indent}      Build.Set_Field ({target}, "schemaname",',
                f'{indent}        Build.Field (Build.Element ({names}, 1), "sval"));',
                f'{indent}      Build.Set_Field ({target}, "relname",',
                f'{indent}        Build.Field (Build.Element ({names}, 2), "sval"));',
                f"{indent}   when others =>",
                f'{indent}      raise Semantics.Parser_Error with "improper qualified name";',
                f"{indent}end case;",
                ]
            return [
                f"{indent}case Build.Length ({names}) is",
                f"{indent}   when 1 =>",
                f'{indent}      Build.Set_Field ({target}, "catalogname", Builders.No_Value);',
                f'{indent}      Build.Set_Field ({target}, "schemaname", Builders.No_Value);',
                f'{indent}      Build.Set_Field ({target}, "relname",',
                f'{indent}        Build.Field (Build.Element ({names}, 1), "sval"));',
                f"{indent}   when 2 =>",
                f'{indent}      Build.Set_Field ({target}, "catalogname", Builders.No_Value);',
                f'{indent}      Build.Set_Field ({target}, "schemaname",',
                f'{indent}        Build.Field (Build.Element ({names}, 1), "sval"));',
                f'{indent}      Build.Set_Field ({target}, "relname",',
                f'{indent}        Build.Field (Build.Element ({names}, 2), "sval"));',
                f"{indent}   when 3 =>",
                f'{indent}      Build.Set_Field ({target}, "catalogname",',
                f'{indent}        Build.Field (Build.Element ({names}, 1), "sval"));',
                f'{indent}      Build.Set_Field ({target}, "schemaname",',
                f'{indent}        Build.Field (Build.Element ({names}, 2), "sval"));',
                f'{indent}      Build.Set_Field ({target}, "relname",',
                f'{indent}        Build.Field (Build.Element ({names}, 3), "sval"));',
                f"{indent}   when others =>",
                f'{indent}      raise Semantics.Parser_Error with "improper qualified name";',
                f"{indent}end case;",
            ]
        if kind == "SwitchStmt" and "makeFloatConst" in self.text(node):
            return [
                f'{indent}if Build.Object_Type (Locals (1)) = "Float" then',
                f'{indent}   Locals (3) := Invoke (Build, "makeFloatConst",',
                f'{indent}     (1 => Build.Field (Locals (1), "fval"), 2 => Locals (2)));',
                f'{indent}elsif Build.Object_Type (Locals (1)) = "Integer" then',
                f'{indent}   Locals (3) := Invoke (Build, "makeIntConst",',
                f'{indent}     (1 => Build.Field (Locals (1), "ival"), 2 => Locals (2)));',
                f'{indent}else',
                f'{indent}   raise Semantics.Parser_Error with "invalid A_Const source";',
                f'{indent}end if;',
            ]
        if kind in {"ForStmt", "SwitchStmt", "UnaryOperator"}:
            self.unsupported_item(f"statement:{kind}", node)
            return []
        self.unsupported[f"statement:{kind}"] += 1
        return []

    def case(self, rule: int, body: dict) -> list[str]:
        self.locals = {}
        self.local_names = {}
        self.loop_labels = []
        self.in_generated_helper = False
        statements = [
            re.sub(r"\bBuild\b", "Build_Access", line)
            for line in self.statement(body)
        ]
        if self.locals:
            return [
                f"         when {rule} =>",
                "            declare",
                f"               Locals : Builders.Semantic_Array (1 .. {len(self.locals)}) :=",
                "                 (others => Builders.No_Value);",
                "            begin",
                *statements,
                "            end;",
            ]
        return [f"         when {rule} =>", *(statements or ["            null;"])]

    def helper(self, index: int, function: dict) -> list[str]:
        self.locals = {}
        self.local_names = {}
        self.loop_labels = []
        parameters = [
            item for item in children(function) if item.get("kind") == "ParmVarDecl"
        ]
        for parameter in parameters:
            slot = len(self.locals) + 1
            self.locals[parameter.get("id", "")] = slot
            self.local_names[parameter.get("name", "")] = slot
        body = next(
            item for item in children(function) if item.get("kind") == "CompoundStmt"
        )
        self.in_generated_helper = True
        statements = self.statement(body, "      ")
        lines = [
            f"   function Helper_{index}",
            "     (Build : not null access Builders.Builder;",
            "      Arguments : Builders.Semantic_Array) return Builders.Dynamic_Value",
            "   is",
            f"      Locals : Builders.Semantic_Array (1 .. {len(self.locals)}) :=",
            "        (others => Builders.No_Value);",
            "   begin",
        ]
        for position, parameter in enumerate(parameters, 1):
            slot = self.locals[parameter.get("id", "")]
            lines.append(f"      Locals ({slot}) := Arguments (Arguments'First + {position - 1});")
        lines.extend(statements)
        lines.extend(["      return Builders.No_Value;", f"   end Helper_{index};", ""])
        return lines


def enum_values(root: dict) -> dict[str, int]:
    result = {}
    for declaration in walk(root):
        if declaration.get("kind") != "EnumDecl":
            continue
        value = -1
        for node in children(declaration):
            if node.get("kind") != "EnumConstantDecl":
                continue
            try:
                value = constant_value(node)
            except ValueError:
                value += 1
            result[node["name"]] = value
    return result


def local_helper_functions(root: dict, switch: dict) -> list[dict]:
    definitions = {}
    for node in walk(root):
        if node.get("kind") != "FunctionDecl" or not any(
            item.get("kind") == "CompoundStmt" for item in children(node)
        ):
            continue
        begin = node.get("range", {}).get("begin", {})
        if "includedFrom" in begin:
            continue
        definitions[node.get("name", "")] = node

    pending = {
        referenced_name(children(node)[0])
        for node in walk(switch)
        if node.get("kind") == "CallExpr" and children(node)
    }
    selected = set()
    while pending:
        name = pending.pop()
        if not name or name in selected or name not in definitions:
            continue
        if name in {"base_yyparse"}:
            continue
        selected.add(name)
        for node in walk(definitions[name]):
            if node.get("kind") == "CallExpr" and children(node):
                called = referenced_name(children(node)[0])
                if called in definitions and called not in selected:
                    pending.add(called)
    return [definitions[name] for name in sorted(selected)]


def called_functions(nodes: list[dict]) -> set[str]:
    return {
        referenced_name(children(node)[0])
        for root in nodes
        for node in walk(root)
        if node.get("kind") == "CallExpr" and children(node)
    } - {None}


def selected_definitions(root: dict, initial: set[str]) -> list[dict]:
    definitions = {
        node.get("name", ""): node
        for node in walk(root)
        if node.get("kind") == "FunctionDecl"
        and any(item.get("kind") == "CompoundStmt" for item in children(node))
        and "includedFrom" not in node.get("range", {}).get("begin", {})
    }
    pending = set(initial)
    selected = set()
    while pending:
        name = pending.pop()
        if name in selected or name not in definitions:
            continue
        selected.add(name)
        pending.update(called_functions([definitions[name]]) - selected)
    return [definitions[name] for name in sorted(selected)]


def wrap_ada(lines: list[str], width: int = 118) -> list[str]:
    result = []
    for original in lines:
        line = original
        continuation = len(line) - len(line.lstrip()) + 3
        while len(line) > width:
            quoted = False
            split = -1
            for index, character in enumerate(line[:width + 1]):
                if character == '"':
                    quoted = not quoted
                elif character.isspace() and not quoted:
                    split = index
            if split <= continuation:
                break
            result.append(line[:split].rstrip())
            line = " " * continuation + line[split:].lstrip()
        result.append(line)
    return result


def generate_spec(major: int) -> str:
    return f"""--  Generated by tools/generate_native_actions.py.  Do not edit.
with Flyology.Postgres.SQL.Native.Builders;

package Flyology.Postgres.SQL.Native.Actions_V{major} is

   procedure Reduce
     (Build        : aliased in out Builders.Builder;
      Rule         : Positive;
      Values       : Builders.Semantic_Array;
      Locations    : Builders.Location_Array;
      Result       : in out Builders.Dynamic_Value;
      Location     : in out Integer;
      Error_Location : not null access Integer;
      Parse_Result : in out Builders.Dynamic_Value);

end Flyology.Postgres.SQL.Native.Actions_V{major};
"""


def reduce_parameters() -> list[str]:
    return [
        "     (Build        : aliased in out Builders.Builder;",
        "      Rule         : Positive;",
        "      Values       : Builders.Semantic_Array;",
        "      Locations    : Builders.Location_Array;",
        "      Result       : in out Builders.Dynamic_Value;",
        "      Location     : in out Integer;",
        "      Error_Location : not null access Integer;",
        "      Parse_Result : in out Builders.Dynamic_Value)",
    ]


def line_balanced_chunks(
    cases: list[tuple[int, list[str]]], count: int
) -> list[list[tuple[int, list[str]]]]:
    """Split ordered cases into a stable number of contiguous, line-balanced chunks."""
    def weight(rule_case: tuple[int, list[str]]) -> int:
        return len(wrap_ada(rule_case[1]))

    count = min(count, len(cases))
    result: list[list[tuple[int, list[str]]]] = []
    remaining_lines = sum(weight(rule_case) for rule_case in cases)
    remaining_cases = list(cases)
    for chunk_index in range(count):
        chunks_left = count - chunk_index
        if chunks_left == 1:
            result.append(remaining_cases)
            break
        target = remaining_lines / chunks_left
        chunk: list[tuple[int, list[str]]] = []
        chunk_lines = 0
        while len(remaining_cases) > chunks_left - 1:
            candidate_lines = weight(remaining_cases[0])
            if (chunk
                    and abs(chunk_lines - target)
                    <= abs(chunk_lines + candidate_lines - target)):
                break
            rule_case = remaining_cases.pop(0)
            chunk.append(rule_case)
            chunk_lines += candidate_lines
        result.append(chunk)
        remaining_lines -= chunk_lines
    return result


@dataclass
class Version_Model:
    major: int
    cases: list[tuple[int, str]]
    helpers: list[tuple[str, str]]
    unsupported: Counter
    examples: dict[str, str]


def encode_model(model: Version_Model) -> str:
    return json.dumps({
        "major": model.major,
        "cases": model.cases,
        "helpers": model.helpers,
        "unsupported": dict(model.unsupported),
        "examples": model.examples,
    })


def decode_model(contents: str) -> Version_Model:
    item = json.loads(contents)
    return Version_Model(
        item["major"],
        [(rule, body) for rule, body in item["cases"]],
        [(name, body) for name, body in item["helpers"]],
        Counter(item["unsupported"]),
        item["examples"],
    )


def compile_version_process(major: int, vendor: Path) -> Version_Model:
    result = subprocess.run(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "--worker-major", str(major),
            "--vendor", str(vendor),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"PostgreSQL {major} semantic action worker failed:\n{result.stderr}"
        )
    return decode_model(result.stdout)


def canonicalize_labels(lines: list[str]) -> str:
    names: dict[str, str] = {}
    pattern = re.compile(r"(?:Continue|Exit)_Loop_\d+")

    def replace(match: re.Match) -> str:
        name = match.group(0)
        if name not in names:
            prefix = name[:name.rfind("_") + 1]
            names[name] = f"{prefix}CANON_{len(names) + 1}"
        return names[name]

    return "\n".join(pattern.sub(replace, line) for line in lines)


def render_body(body: str, identifier: int) -> list[str]:
    suffix = f"H{identifier:016X}"
    return [
        re.sub(r"CANON_(\d+)", rf"{suffix}_\1", line).replace(
            "Invoke (", "Version_Invoke ("
        )
        for line in body.splitlines()
    ]


def helper_case(emitter: Emitter, index: int, helper: dict) -> str:
    lines = emitter.helper(index, helper)
    is_line = lines.index("   is")
    begin_line = lines.index("   begin", is_line)
    end_line = next(
        position for position, line in enumerate(lines)
        if line.startswith("   end Helper_")
    )
    result = ["            declare"]
    result.extend(" " * 9 + line for line in lines[is_line + 1:begin_line])
    result.append("            begin")
    result.extend(" " * 9 + line for line in lines[begin_line + 1:end_line])
    result.append("            end;")
    return canonicalize_labels(result)


def compile_version(major: int, vendor: Path) -> Version_Model:
    root, source = clang_ast(vendor)
    emitter = Emitter(source, enum_values(root), major)
    switch = semantic_switch(root)
    cases = reduction_cases(switch)
    helpers = local_helper_functions(root, switch)
    external_path = vendor / "src" / "postgres" / "src_backend_nodes_makefuncs.c"
    external_root, external_source = clang_ast_path(vendor, external_path)
    external_helpers = selected_definitions(
        external_root, called_functions([switch, *helpers])
    )
    external_emitter = Emitter(external_source, enum_values(external_root), major)
    external_emitter.loop_counter = 1_000
    helper_entries = [(helper, emitter) for helper in helpers]
    helper_entries.extend((helper, external_emitter) for helper in external_helpers)
    unsupported = emitter.unsupported + external_emitter.unsupported
    examples = dict(emitter.unsupported_examples)
    examples.update(external_emitter.unsupported_examples)
    emitted_cases = [
        (rule, canonicalize_labels(emitter.case(rule, body)[1:]))
        for rule, body in cases
    ]
    emitted_helpers = [
        (helper.get("name", ""), helper_case(helper_emitter, index, helper))
        for index, (helper, helper_emitter) in enumerate(helper_entries, 1)
        if helper.get("name", "") not in HANDWRITTEN_HELPERS
    ]
    return Version_Model(
        major, emitted_cases, emitted_helpers, unsupported, examples
    )


def body_identifier(body: str) -> int:
    return int.from_bytes(hashlib.sha256(body.encode()).digest()[:8], "big")


def catalog_bodies(models: list[Version_Model], attribute: str) -> dict[int, str]:
    result: dict[int, str] = {}
    for model in models:
        entries = getattr(model, attribute)
        for entry in entries:
            body = entry[-1]
            identifier = body_identifier(body)
            if identifier == 0:
                raise ValueError("generated catalog identifier is reserved")
            if identifier in result and result[identifier] != body:
                raise ValueError(
                    f"SHA-256 catalog identifier collision at {identifier:016X}"
                )
            result[identifier] = body
    return result


def ada_identifier(identifier: int) -> str:
    return f"16#{identifier:016X}#"


def callback_declaration(indent: str = "   ") -> list[str]:
    return [
        f"{indent}type Invoke_Access is not null access function",
        f"{indent}  (Build : not null access Builders.Builder; Name : String;",
        f"{indent}   Arguments : Builders.Semantic_Array;",
        f"{indent}   Error_Location : not null access Integer)",
        f"{indent}   return Builders.Dynamic_Value;",
    ]


def catalog_parameters(
    kind: str, id_type: str, callback_type: str = "Invoke_Access"
) -> list[str]:
    return [
        f"     ({kind:<12} : {id_type};",
        "      Build        : aliased in out Builders.Builder;",
        "      Values       : Builders.Semantic_Array;",
        "      Locations    : Builders.Location_Array;",
        "      Result       : in out Builders.Dynamic_Value;",
        "      Location     : in out Integer;",
        "      Error_Location : not null access Integer;",
        "      Parse_Result : in out Builders.Dynamic_Value;",
        f"      Callback     : {callback_type})",
    ]


def generate_action_chunk(
    number: int, entries: list[tuple[int, list[str]]]
) -> tuple[str, str]:
    unit = f"Flyology.Postgres.SQL.Native.Action_Catalog_Chunk_{number:02}"
    parameters = catalog_parameters(
        "Action", "Action_Catalog.Action_Id", "Action_Catalog.Invoke_Access"
    )
    spec = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "with Flyology.Postgres.SQL.Native.Action_Catalog;",
        "",
        f"private package {unit} is",
        "",
        "   procedure Reduce",
        *parameters[:-1],
        parameters[-1] + ";",
        "",
        f"end {unit};",
        "",
    ]
    body = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Interfaces;",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "with Flyology.Postgres.SQL.Native.Semantics;",
        "",
        f"package body {unit} is",
        "",
        "   pragma Style_Checks (Off);",
        "   use type Interfaces.Integer_64;",
        "",
        "   procedure Reduce",
        *parameters,
        "   is",
        "      Build_Access : constant not null access Builders.Builder :=",
        "        Build'Unchecked_Access;",
        "",
        "      function Version_Invoke",
        "        (Build : not null access Builders.Builder; Name : String;",
        "         Arguments : Builders.Semantic_Array) return Builders.Dynamic_Value",
        "      is",
        "      begin",
        "         return Callback.all (Build, Name, Arguments, Error_Location);",
        "      end Version_Invoke;",
        "   begin",
        "      case Action is",
    ]
    for _identifier, lines in entries:
        body.extend(lines)
    body.extend([
        "         when others => null;",
        "      end case;",
        "   end Reduce;",
        "",
        f"end {unit};",
        "",
    ])
    return "\n".join(wrap_ada(spec)), "\n".join(wrap_ada(body))


def generate_action_catalog(bodies: dict[int, str]) -> dict[str, str]:
    entries = [
        (identifier, [f"         when {ada_identifier(identifier)} =>",
                      *render_body(body, identifier)])
        for identifier, body in sorted(bodies.items())
    ]
    chunks = line_balanced_chunks(entries, ACTION_CHUNK_COUNT)
    unit = "Flyology.Postgres.SQL.Native.Action_Catalog"
    spec_lines = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Interfaces;",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "",
        f"private package {unit} is",
        "",
        "   Positioned_Error : exception;",
        "   Unpositioned_Error : exception;",
        "",
        "   subtype Action_Id is Interfaces.Unsigned_64;",
        "   No_Action : constant Action_Id := 0;",
        "",
        *callback_declaration(),
        "",
        "   procedure Reduce",
        *catalog_parameters("Action", "Action_Id")[:-1],
        catalog_parameters("Action", "Action_Id")[-1] + ";",
        "",
        f"end {unit};",
        "",
    ]
    body_lines = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
    ]
    body_lines.extend(
        f"with Flyology.Postgres.SQL.Native.Action_Catalog_Chunk_{number:02};"
        for number in range(1, len(chunks) + 1)
    )
    body_lines.extend([
        "",
        f"package body {unit} is",
        "",
        "   procedure Reduce",
        *catalog_parameters("Action", "Action_Id"),
        "   is",
        "   begin",
        "      case Action is",
    ])
    lower = chunks[0][0][0]
    for number, chunk in enumerate(chunks, 1):
        upper = chunk[-1][0]
        body_lines.extend([
            f"         when {ada_identifier(lower)} .. {ada_identifier(upper)} =>",
            f"            Action_Catalog_Chunk_{number:02}.Reduce",
            "              (Action, Build, Values, Locations, Result, Location, Error_Location, Parse_Result, Callback);",
        ])
        lower = upper + 1
    body_lines.extend([
        "         when others => null;",
        "      end case;",
        "   end Reduce;",
        "",
        f"end {unit};",
        "",
    ])
    files = {
        "flyology-postgres-sql-native-action_catalog.ads": "\n".join(wrap_ada(spec_lines)),
        "flyology-postgres-sql-native-action_catalog.adb": "\n".join(wrap_ada(body_lines)),
    }
    for number, chunk in enumerate(chunks, 1):
        chunk_spec, chunk_body = generate_action_chunk(number, chunk)
        base = f"flyology-postgres-sql-native-action_catalog_chunk_{number:02}"
        files[f"{base}.ads"] = chunk_spec
        files[f"{base}.adb"] = chunk_body
    return files


def helper_parameters(id_type: str) -> list[str]:
    return [
        f"     (Helper    : {id_type};",
        "      Build     : not null access Builders.Builder;",
        "      Arguments : Builders.Semantic_Array;",
        "      Error_Location : not null access Integer;",
        "      Callback  : Action_Catalog.Invoke_Access)",
    ]


def generate_helper_chunk(
    number: int, entries: list[tuple[int, list[str]]]
) -> tuple[str, str]:
    unit = f"Flyology.Postgres.SQL.Native.Action_Helper_Catalog_Chunk_{number:02}"
    parameters = helper_parameters("Action_Helper_Catalog.Helper_Id")
    spec = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "with Flyology.Postgres.SQL.Native.Action_Catalog;",
        "with Flyology.Postgres.SQL.Native.Action_Helper_Catalog;",
        "",
        f"private package {unit} is",
        "",
        "   function Execute",
        *parameters[:-1],
        parameters[-1] + " return Builders.Dynamic_Value;",
        "",
        f"end {unit};",
        "",
    ]
    body = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Interfaces;",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "with Flyology.Postgres.SQL.Native.Semantics;",
        "",
        f"package body {unit} is",
        "",
        "   pragma Style_Checks (Off);",
        "   use type Interfaces.Integer_64;",
        "",
        "   function Execute",
        *parameters,
        "      return Builders.Dynamic_Value",
        "   is",
        "      function Version_Invoke",
        "        (Build : not null access Builders.Builder; Name : String;",
        "         Arguments : Builders.Semantic_Array) return Builders.Dynamic_Value",
        "      is",
        "      begin",
        "         return Callback.all (Build, Name, Arguments, Error_Location);",
        "      end Version_Invoke;",
        "   begin",
        "      case Helper is",
    ]
    for _identifier, lines in entries:
        body.extend(lines)
    body.extend([
        "         when others => return Builders.No_Value;",
        "      end case;",
        "   end Execute;",
        "",
        f"end {unit};",
        "",
    ])
    return "\n".join(wrap_ada(spec)), "\n".join(wrap_ada(body))


def generate_helper_catalog(bodies: dict[int, str]) -> dict[str, str]:
    entries = [
        (identifier, [f"         when {ada_identifier(identifier)} =>",
                      *render_body(body, identifier)])
        for identifier, body in sorted(bodies.items())
    ]
    chunks = line_balanced_chunks(entries, HELPER_CHUNK_COUNT)
    unit = "Flyology.Postgres.SQL.Native.Action_Helper_Catalog"
    parameters = helper_parameters("Helper_Id")
    spec_lines = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Interfaces;",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "with Flyology.Postgres.SQL.Native.Action_Catalog;",
        "",
        f"private package {unit} is",
        "",
        "   subtype Helper_Id is Interfaces.Unsigned_64;",
        "",
        "   function Execute",
        *parameters[:-1],
        parameters[-1] + " return Builders.Dynamic_Value;",
        "",
        f"end {unit};",
        "",
    ]
    body_lines = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
    ]
    body_lines.extend(
        f"with Flyology.Postgres.SQL.Native.Action_Helper_Catalog_Chunk_{number:02};"
        for number in range(1, len(chunks) + 1)
    )
    body_lines.extend([
        "",
        f"package body {unit} is",
        "",
        "   function Execute",
        *parameters,
        "      return Builders.Dynamic_Value",
        "   is",
        "   begin",
        "      case Helper is",
    ])
    lower = chunks[0][0][0]
    for number, chunk in enumerate(chunks, 1):
        upper = chunk[-1][0]
        body_lines.extend([
            f"         when {ada_identifier(lower)} .. {ada_identifier(upper)} =>",
            f"            return Action_Helper_Catalog_Chunk_{number:02}.Execute",
            "              (Helper, Build, Arguments, Error_Location, Callback);",
        ])
        lower = upper + 1
    body_lines.extend([
        "         when others => return Builders.No_Value;",
        "      end case;",
        "   end Execute;",
        "",
        f"end {unit};",
        "",
    ])
    files = {
        "flyology-postgres-sql-native-action_helper_catalog.ads": "\n".join(wrap_ada(spec_lines)),
        "flyology-postgres-sql-native-action_helper_catalog.adb": "\n".join(wrap_ada(body_lines)),
    }
    for number, chunk in enumerate(chunks, 1):
        chunk_spec, chunk_body = generate_helper_chunk(number, chunk)
        base = f"flyology-postgres-sql-native-action_helper_catalog_chunk_{number:02}"
        files[f"{base}.ads"] = chunk_spec
        files[f"{base}.adb"] = chunk_body
    return files


def generate_version_files(model: Version_Model) -> dict[str, str]:
    major = model.major
    unit = f"Flyology.Postgres.SQL.Native.Actions_V{major}"
    max_rule = max(rule for rule, _body in model.cases)
    body_lines = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Action_Catalog;",
        f"with Flyology.Postgres.SQL.Native.Actions_V{major}_Support;",
        "",
        f"package body {unit} is",
        "",
        "   use type Action_Catalog.Action_Id;",
        "",
        "   type Action_Table is array (Positive range <>) of Action_Catalog.Action_Id;",
        f"   Actions : constant Action_Table (1 .. {max_rule}) :=",
        "     (",
    ]
    body_lines.extend(
        f"      {rule} => {ada_identifier(body_identifier(body))},"
        for rule, body in model.cases
    )
    body_lines.extend([
        "      others => Action_Catalog.No_Action);",
        "",
        "   procedure Reduce",
        *reduce_parameters(),
        "   is",
        "   begin",
        "      if Rule in Actions'Range then",
        "         declare",
        "            Action : constant Action_Catalog.Action_Id := Actions (Rule);",
        "         begin",
        "            if Action /= Action_Catalog.No_Action then",
        "               Action_Catalog.Reduce",
        f"                 (Action, Build, Values, Locations, Result, Location, Error_Location, Parse_Result, Actions_V{major}_Support.Invoke'Access);",
        "            end if;",
        "         end;",
        "      end if;",
        "   end Reduce;",
        "",
        f"end {unit};",
        "",
    ])

    support = f"Flyology.Postgres.SQL.Native.Actions_V{major}_Support"
    support_spec = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Builders;",
        "",
        f"private package {support} is",
        "",
        "   function Invoke",
        "     (Build : not null access Builders.Builder; Name : String;",
        "      Arguments : Builders.Semantic_Array;",
        "      Error_Location : not null access Integer)",
        "      return Builders.Dynamic_Value;",
        "",
        f"end {support};",
        "",
    ]
    support_body = [
        "--  Generated by tools/generate_native_actions.py.  Do not edit.",
        "with Flyology.Postgres.SQL.Native.Action_Helper_Catalog;",
        "with Flyology.Postgres.SQL.Native.Semantics;",
        "",
        f"package body {support} is",
        "",
        "   function Invoke",
        "     (Build : not null access Builders.Builder; Name : String;",
        "      Arguments : Builders.Semantic_Array;",
        "      Error_Location : not null access Integer)",
        "      return Builders.Dynamic_Value",
        "   is",
        "   begin",
    ]
    for index, (name, body) in enumerate(model.helpers):
        keyword = "if" if index == 0 else "elsif"
        support_body.extend([
            f'      {keyword} Name = "{name}" then',
            "         return Action_Helper_Catalog.Execute",
            f"           ({ada_identifier(body_identifier(body))}, Build, Arguments, Error_Location, Invoke'Access);",
        ])
    if model.helpers:
        support_body.extend([
            "      else",
            "         return Semantics.Invoke (Build, Name, Arguments);",
            "      end if;",
        ])
    else:
        support_body.append("      return Semantics.Invoke (Build, Name, Arguments);")
    support_body.extend([
        "   end Invoke;",
        "",
        f"end {support};",
        "",
    ])
    return {
        f"flyology-postgres-sql-native-actions_v{major}.ads": generate_spec(major),
        f"flyology-postgres-sql-native-actions_v{major}.adb": "\n".join(wrap_ada(body_lines)),
        f"flyology-postgres-sql-native-actions_v{major}_support.ads": "\n".join(wrap_ada(support_spec)),
        f"flyology-postgres-sql-native-actions_v{major}_support.adb": "\n".join(wrap_ada(support_body)),
    }


def report_audit(models: list[Version_Model]) -> None:
    for model in models:
        print(f"PostgreSQL {model.major}:")
        print("\n".join(
            f"{count:6} {name}" for name, count in model.unsupported.most_common()
        ))
        for name, example in model.examples.items():
            print(f"example {name}: {example}")
        print(f"unsupported constructs: {sum(model.unsupported.values())}")
    action_count = sum(len(model.cases) for model in models)
    helper_count = sum(len(model.helpers) for model in models)
    scope = "shared catalog" if len(models) > 1 else "catalog input"
    print(
        f"{scope}: {len(catalog_bodies(models, 'cases'))} action bodies "
        f"from {action_count} occurrences; "
        f"{len(catalog_bodies(models, 'helpers'))} helper bodies "
        f"from {helper_count} occurrences"
    )


def stale_generated_paths(
    output: Path, majors: tuple[int, ...], include_global: bool
) -> set[Path]:
    result = {
        path for major in majors
        for path in output.glob(
            f"flyology-postgres-sql-native-actions_v{major}_chunk_*"
        ) if path.suffix in {".ads", ".adb"}
    }
    if include_global:
        for pattern in (
            "flyology-postgres-sql-native-action_catalog_chunk_*",
            "flyology-postgres-sql-native-action_helper_catalog_chunk_*",
        ):
            result.update(
                path for path in output.glob(pattern)
                if path.suffix in {".ads", ".adb"}
            )
    return result


def apply_or_check(
    output: Path, files: dict[str, str], check: bool,
    majors: tuple[int, ...], include_global: bool
) -> None:
    expected = {output / name: contents for name, contents in files.items()}
    stale = stale_generated_paths(output, majors, include_global) - set(expected)
    if check:
        changed = [
            path for path, contents in expected.items()
            if not path.exists() or path.read_text() != contents
        ]
        changed.extend(sorted(stale))
        if changed:
            raise SystemExit(
                "generated files are stale: "
                + ", ".join(str(path) for path in changed)
            )
        return
    for path in stale:
        path.unlink()
    for path, contents in expected.items():
        if not path.exists() or path.read_text() != contents:
            path.write_text(contents)


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--major", type=int)
    mode.add_argument("--all", action="store_true", dest="all_versions")
    mode.add_argument("--worker-major", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--vendor", type=Path)
    parser.add_argument("--vendor-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--audit", action="store_true")
    args = parser.parse_args()

    if args.worker_major is not None:
        if args.vendor is None:
            parser.error("--worker-major requires --vendor")
        print(encode_model(compile_version(args.worker_major, args.vendor.resolve())))
        return
    if args.output is None:
        parser.error("--output is required")

    if args.all_versions:
        if args.vendor_root is None or args.vendor is not None:
            parser.error("--all requires --vendor-root and does not accept --vendor")
        vendor_root = args.vendor_root.resolve()
        with ThreadPoolExecutor(max_workers=len(SUPPORTED_MAJORS)) as executor:
            futures = {
                major: executor.submit(
                    compile_version_process,
                    major,
                    vendor_root / f"v{major}" / "vendor",
                )
                for major in SUPPORTED_MAJORS
            }
            models = [futures[major].result() for major in SUPPORTED_MAJORS]
        files = generate_action_catalog(catalog_bodies(models, "cases"))
        files.update(generate_helper_catalog(catalog_bodies(models, "helpers")))
        for model in models:
            files.update(generate_version_files(model))
        include_global = True
        majors = SUPPORTED_MAJORS
    else:
        if args.major not in SUPPORTED_MAJORS:
            parser.error(f"--major must be one of {SUPPORTED_MAJORS}")
        if args.vendor is None or args.vendor_root is not None:
            parser.error("--major requires --vendor and does not accept --vendor-root")
        if not args.check:
            parser.error("partial generation is unsafe; use --all for regeneration")
        models = [compile_version(args.major, args.vendor.resolve())]
        catalog_bodies(models, "cases")
        catalog_bodies(models, "helpers")
        files = generate_version_files(models[0])
        include_global = False
        majors = (args.major,)

    if args.audit:
        report_audit(models)
    unsupported = sum(
        (model.unsupported for model in models), Counter()
    )
    if unsupported:
        details = ", ".join(
            f"{name}={count}" for name, count in unsupported.most_common(12)
        )
        raise SystemExit(f"semantic action compiler is incomplete: {details}")
    apply_or_check(args.output, files, args.check, majors, include_global)
    scope = "all native PostgreSQL actions" if args.all_versions else f"native PostgreSQL {args.major} actions"
    print(f"{'verified' if args.check else 'generated'} {scope}")


if __name__ == "__main__":
    main()
