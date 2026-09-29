#!/usr/bin/env python3
"""File the drafted issue bodies under review/filing/ on GitHub.

Usage:
  file_issues.py --dry-run            # validate and print what would be filed
  file_issues.py --file               # create the issues, in ORDER, and write ISSUES.md
  file_issues.py --resolve            # second pass: replace remaining placeholders in
                                      # already-filed issues and in the local documents

Each body file has a header:
  Title: ...
  Labels: bug[, documentation]
  Refs: ID, ID | none
followed by a blank line and the markdown body. Cross-references are written as
{{ISSUE:<ID>}} and are replaced with the issue URL when known. ORDER lists the
filing sequence; referenced issues are filed before the issues that cite them
where possible, and the --resolve pass patches the rest with `gh issue edit`.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "flyology-ada/flyology-postgres"
HERE = Path(__file__).resolve().parent
REVIEW = HERE.parent
ROOT = REVIEW.parent
MAPPING = REVIEW / "ISSUES.json"
ISSUES_MD = REVIEW / "ISSUES.md"

# Filing order: PROTO first (SERVER cites it), then SERVER, then the rest.
ORDER = [
    "PROTO-1", "PROTO-2", "PROTO-3", "PROTO-4", "PROTO-5", "PROTO-6", "PROTO-7",
    "SERVER-1", "SERVER-2", "SERVER-3", "SERVER-4", "SERVER-6", "SERVER-7",
    "SERVER-8", "SERVER-9", "SERVER-11",
    "SCRAM-1", "SCRAM-2", "SCRAM-3",
    "CLIENT-1", "CLIENT-2", "CLIENT-3", "CLIENT-4", "CLIENT-5", "CLIENT-6",
    "LOGICAL-1", "LOGICAL-2", "LOGICAL-3", "LOGICAL-4", "LOGICAL-5",
    "REPL-1", "REPL-2", "REPL-3", "REPL-4", "REPL-5",
    "BACKUP-1", "BACKUP-2", "BACKUP-3", "BACKUP-4", "BACKUP-5", "BACKUP-6", "BACKUP-7",
    "SQL-1", "SQL-2", "SQL-3", "SQL-4", "SQL-5", "SQL-6", "SQL-7", "SQL-8", "SQL-8b", "SQL-9",
    "EXAMPLES-1", "EXAMPLES-2", "EXAMPLES-3", "EXAMPLES-4", "EXAMPLES-5", "EXAMPLES-6",
    "EXAMPLES-7", "EXAMPLES-8", "EXAMPLES-9", "EXAMPLES-10", "EXAMPLES-11",
]
VALID_LABELS = {"bug", "documentation"}
PLACEHOLDER = re.compile(r"\{\{ISSUE:([A-Z]+-[0-9]+b?)\}\}")
INTERNAL_ID = re.compile(r"\b(PROTO|SERVER|SCRAM|LOGICAL|CLIENT|REPL|BACKUP|SQL|EXAMPLES)-[0-9]+b?\b")
FORBIDDEN = re.compile(
    r"(?i)(?<![.\w])(claude|reviewer agent|verifier agent|subagent|scratchpad|FINDINGS\.md|review/|"
    r"tests/repros|sql/tests/repros|examples/repros|Repro_Support|SQL_Repro_Support|"
    r"Example_Repro_Support)\b"
)
REQUIRED_SECTIONS = ["## Summary", "## Problem", "## What should happen",
                     "## Suggested treatment", "## Severity"]


def parse(path: Path) -> dict:
    text = path.read_text()
    head, _, body = text.partition("\n\n")
    fields = {}
    for line in head.splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return {"title": fields.get("Title", ""), "labels": fields.get("Labels", ""),
            "refs": fields.get("Refs", ""), "body": body.strip() + "\n", "path": path}


def validate(item: dict, known: set[str]) -> list[str]:
    problems = []
    if not item["title"] or len(item["title"]) > 130:
        problems.append("title missing or over 130 characters")
    if item["title"].endswith("."):
        problems.append("title ends with a period")
    labels = {l.strip() for l in item["labels"].split(",") if l.strip()}
    if not labels or not labels <= VALID_LABELS:
        problems.append(f"labels invalid: {item['labels']!r}")
    body = item["body"]
    for section in REQUIRED_SECTIONS:
        if section not in body:
            problems.append(f"missing section {section}")
    if "## What happens now" not in body and "## Failure scenario" not in body:
        problems.append("missing What happens now / Failure scenario")
    if "Commit `6f496f5`" not in body:
        problems.append("Problem section does not start with the commit")
    for m in INTERNAL_ID.finditer(item["title"] + "\n" + PLACEHOLDER.sub("", body)):
        problems.append(f"internal id leaked: {m.group(0)}")
    for m in FORBIDDEN.finditer(item["title"] + "\n" + body):
        problems.append(f"forbidden word: {m.group(0)}")
    for m in PLACEHOLDER.finditer(body):
        if m.group(1) not in known:
            problems.append(f"placeholder to unknown finding {m.group(1)}")
    if "—" in body or "—" in item["title"]:
        problems.append("em-dash present")
    return problems


def load_mapping() -> dict:
    if MAPPING.exists():
        return json.loads(MAPPING.read_text())
    return {}


def save_mapping(mapping: dict) -> None:
    MAPPING.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
    lines = ["# Filed issues", "",
             f"Repository: https://github.com/{REPO}. Filed from review commit 6f496f5.", "",
             "| Finding | Issue | Title |", "| --- | --- | --- |"]
    for fid in ORDER:
        if fid in mapping:
            entry = mapping[fid]
            lines.append(f"| {fid} | [#{entry['number']}]({entry['url']}) | {entry['title']} |")
    ISSUES_MD.write_text("\n".join(lines) + "\n")


def substitute(body: str, mapping: dict) -> tuple[str, list[str]]:
    unresolved = []

    def repl(m: re.Match) -> str:
        fid = m.group(1)
        if fid in mapping:
            return mapping[fid]["url"]
        unresolved.append(fid)
        return m.group(0)

    return PLACEHOLDER.sub(repl, body), unresolved


def gh(*args: str) -> str:
    """Run gh, retrying on secondary rate limits or transient failures."""
    import time
    for attempt in range(1, 4):
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        print(f"gh attempt {attempt} failed: {result.stderr.strip()[:300]}", file=sys.stderr)
        time.sleep(90 if "rate limit" in result.stderr.lower() else 20)
    raise RuntimeError("gh failed three times: " + " ".join(args[:3]))


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--file", action="store_true")
    mode.add_argument("--resolve", action="store_true")
    ap.add_argument("--only", nargs="*", help="restrict to these finding ids")
    args = ap.parse_args()

    items = {}
    missing = []
    for fid in ORDER:
        path = HERE / f"{fid}.md"
        if path.exists():
            items[fid] = parse(path)
        else:
            missing.append(fid)
    known = set(ORDER)
    failures = 0
    for fid, item in items.items():
        problems = validate(item, known)
        if problems:
            failures += 1
            print(f"INVALID {fid}: " + "; ".join(problems))
    print(f"{len(items)} bodies present, {len(missing)} missing: {' '.join(missing) or 'none'}; "
          f"{failures} invalid")
    if args.dry_run:
        for fid in ORDER:
            if fid in items:
                item = items[fid]
                print(f"  {fid:<12} [{item['labels']}] {item['title']}")
        return 1 if failures or missing else 0
    if failures or missing:
        print("refusing to file with invalid or missing bodies", file=sys.stderr)
        return 1

    mapping = load_mapping()
    selected = [f for f in ORDER if (not args.only or f in args.only)]

    if args.file:
        for fid in selected:
            if fid in mapping:
                print(f"skip {fid}: already filed as #{mapping[fid]['number']}")
                continue
            item = items[fid]
            body, unresolved = substitute(item["body"], mapping)
            if unresolved:
                # Forward reference: file with a neutral phrase, patch in --resolve.
                body = PLACEHOLDER.sub("(see the related issue filed with this one)", body)
            labels = [l.strip() for l in item["labels"].split(",") if l.strip()]
            cmd = ["issue", "create", "--repo", REPO, "--title", item["title"],
                   "--body", body]
            for label in labels:
                cmd += ["--label", label]
            url = gh(*cmd)
            number = int(url.rstrip("/").rsplit("/", 1)[1])
            mapping[fid] = {"number": number, "url": url, "title": item["title"],
                            "unresolved": unresolved}
            save_mapping(mapping)
            print(f"filed {fid} -> #{number} {url}", flush=True)
            import time
            time.sleep(6)
        return 0

    if args.resolve:
        # Patch forward references inside filed issues.
        for fid, entry in mapping.items():
            if entry.get("unresolved"):
                item = items[fid]
                body, unresolved = substitute(item["body"], mapping)
                if unresolved:
                    print(f"{fid}: still unresolved {unresolved}")
                    continue
                gh("issue", "edit", "--repo", REPO, str(entry["number"]), "--body", body)
                entry["unresolved"] = []
                print(f"patched #{entry['number']} ({fid})")
        save_mapping(mapping)
        # Substitute in the local documents.
        for doc in (REVIEW / "TRIAGE_FOR_CODEX.md",):
            text = doc.read_text()
            numbers = [mapping[f]["number"] for f in ORDER if f in mapping]
            if numbers:
                text = text.replace("{{ISSUE_RANGE}}", f"#{min(numbers)}–#{max(numbers)}")
            text = PLACEHOLDER.sub(lambda m: f"#{mapping[m.group(1)]['number']}"
                                   if m.group(1) in mapping else m.group(0), text)
            doc.write_text(text)
            print(f"substituted in {doc.name}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
