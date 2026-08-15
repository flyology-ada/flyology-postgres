#!/usr/bin/env python3
"""Prepare version-pinned PostgreSQL regression SQL corpora.

The parser backends already record the exact PostgreSQL source release and
archive digest used to generate each version.  This script downloads that
same archive, verifies it, and extracts only src/test/regress/sql/*.sql.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath


MAJORS = (14, 15, 16, 17, 18)
FORMAT_VERSION = 3
TESTS_ROOT = Path(__file__).resolve().parents[1]
SQL_ROOT = TESTS_ROOT.parent
DEFAULT_CACHE = TESTS_ROOT / ".cache" / "postgres-regress"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def metadata(major: int) -> dict[str, object]:
    path = SQL_ROOT / "backends" / f"v{major}" / "vendor" / "UPSTREAM.toml"
    text = path.read_text()

    def value(name: str) -> str:
        match = re.search(
            rf'^{re.escape(name)}\s*=\s*"?([^"\n]+)"?\s*$',
            text,
            re.MULTILINE,
        )
        if match is None:
            raise ValueError(f"{path} does not define {name}")
        return match.group(1)

    result: dict[str, object] = {
        "postgresql_major": int(value("postgresql_major")),
        "postgresql_release": value("postgresql_release"),
        "postgresql_archive_sha256": value("postgresql_archive_sha256"),
    }
    if result["postgresql_major"] != major:
        raise ValueError(f"{path} does not describe PostgreSQL {major}")
    return result


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=destination.parent, prefix=destination.name + ".", delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
        try:
            print(f"downloading {url}", file=sys.stderr)
            with urllib.request.urlopen(url) as response:
                shutil.copyfileobj(response, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    os.replace(temporary_path, destination)


def require_archive(
    release: str, expected_digest: str, archive_root: Path, offline: bool
) -> Path:
    name = f"postgresql-{release}.tar.gz"
    archive = archive_root / name
    if archive.exists() and digest(archive) != expected_digest:
        raise ValueError(f"cached archive has the wrong SHA-256: {archive}")
    if not archive.exists():
        if offline:
            raise FileNotFoundError(f"version-pinned archive is not cached: {archive}")
        download(
            f"https://ftp.postgresql.org/pub/source/v{release}/{name}", archive
        )
        actual_digest = digest(archive)
        if actual_digest != expected_digest:
            archive.unlink(missing_ok=True)
            raise ValueError(
                f"downloaded {name} has SHA-256 {actual_digest}, "
                f"expected {expected_digest}"
            )
    return archive


def existing_corpus_is_current(
    destination: Path, release: str, archive_digest: str
) -> bool:
    manifest_path = destination / "manifest.json"
    if not manifest_path.exists():
        return False
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError):
        return False
    if (
        manifest.get("format_version") != FORMAT_VERSION
        or
        manifest.get("postgresql_release") != release
        or manifest.get("archive_sha256") != archive_digest
    ):
        return False
    files = manifest.get("files")
    if not isinstance(files, list):
        return False
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            return False
        name = item["name"]
        paths_and_digests = (
            (destination / name, item.get("sha256")),
            (
                destination / "statements" / name,
                item.get("candidate_sha256"),
            ),
            (
                destination / "statements" / (name + ".spans"),
                item.get("spans_sha256"),
            ),
        )
        if any(
            not isinstance(expected, str)
            or not path.is_file()
            or digest(path) != expected
            for path, expected in paths_and_digests
        ):
            return False
    return True


def split_sql(data: bytes) -> list[bytes]:
    """Split a psql regression script into conservative SQL candidates.

    PostgreSQL's raw parser does not recover after an expected syntax error,
    and regression scripts also contain psql commands and COPY data.  This
    lexer recognizes SQL quoting/comments, removes line-oriented psql input,
    and returns semicolon-terminated candidates for individual oracle checks.
    The C oracle remains the authority: candidates it rejects are reported but
    never counted as AST coverage.
    """

    candidates: list[bytes] = []
    current = bytearray()
    index = 0
    state = "normal"
    block_depth = 0
    dollar_tag = b""
    line_only_space = True

    def finish() -> bytes:
        value = bytes(current)
        current.clear()
        if value.strip():
            candidates.append(value)
        return value

    while index < len(data):
        value = data[index]

        if state == "line_comment":
            current.append(value)
            index += 1
            if value == 10:
                state = "normal"
                line_only_space = True
            continue

        if state == "block_comment":
            if data[index:index + 2] == b"/*":
                current.extend(b"/*")
                block_depth += 1
                index += 2
            elif data[index:index + 2] == b"*/":
                current.extend(b"*/")
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "normal"
            else:
                current.append(value)
                index += 1
            continue

        if state == "single_quote":
            current.append(value)
            index += 1
            if value == 92 and index < len(data):
                current.append(data[index])
                index += 1
            elif value == 39:
                if index < len(data) and data[index] == 39:
                    current.append(data[index])
                    index += 1
                else:
                    state = "normal"
            continue

        if state == "double_quote":
            current.append(value)
            index += 1
            if value == 34:
                if index < len(data) and data[index] == 34:
                    current.append(data[index])
                    index += 1
                else:
                    state = "normal"
            continue

        if state == "dollar_quote":
            if data[index:index + len(dollar_tag)] == dollar_tag:
                current.extend(dollar_tag)
                index += len(dollar_tag)
                state = "normal"
            else:
                current.append(value)
                index += 1
            continue

        if line_only_space and value == 92:
            # psql commands are line-oriented.  Commands such as \gset also
            # terminate a query buffer that deliberately has no semicolon.
            finish()
            newline = data.find(b"\n", index)
            if newline < 0:
                break
            current.append(10)
            index = newline + 1
            line_only_space = True
            continue

        if data[index:index + 2] == b"--":
            current.extend(b"--")
            index += 2
            state = "line_comment"
            line_only_space = False
            continue
        if data[index:index + 2] == b"/*":
            current.extend(b"/*")
            index += 2
            state = "block_comment"
            block_depth = 1
            line_only_space = False
            continue
        if value == 39:
            current.append(value)
            index += 1
            state = "single_quote"
            line_only_space = False
            continue
        if value == 34:
            current.append(value)
            index += 1
            state = "double_quote"
            line_only_space = False
            continue
        if value == 36:
            end = data.find(b"$", index + 1)
            if end >= 0:
                tag = data[index + 1:end]
                if not tag or (
                    (tag[:1].isalpha() or tag[:1] == b"_")
                    and all(bytes((item,)).isalnum() or item == 95 for item in tag)
                ):
                    dollar_tag = data[index:end + 1]
                    current.extend(dollar_tag)
                    index = end + 1
                    state = "dollar_quote"
                    line_only_space = False
                    continue
        if value == 59:
            current.append(value)
            index += 1
            statement = finish()
            line_only_space = False
            if re.search(rb"(?is)\bCOPY\b.*\bFROM\s+STDIN\b", statement):
                # COPY data is psql input rather than SQL.  Resume after the
                # line containing only the terminator `\.`.
                newline = data.find(b"\n", index)
                index = len(data) if newline < 0 else newline + 1
                while index < len(data):
                    newline = data.find(b"\n", index)
                    end = len(data) if newline < 0 else newline
                    if data[index:end].strip(b" \t\r") == b"\\.":
                        index = len(data) if newline < 0 else newline + 1
                        break
                    index = len(data) if newline < 0 else newline + 1
                line_only_space = True
            continue

        current.append(value)
        index += 1
        if value == 10:
            line_only_space = True
        elif value not in b" \t\r":
            line_only_space = False

    finish()
    return candidates


def extract_corpus(
    archive: Path,
    destination: Path,
    major: int,
    release: str,
    archive_digest: str,
) -> None:
    if existing_corpus_is_current(destination, release, archive_digest):
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f"v{major}.", dir=destination.parent)
    )
    try:
        prefix = PurePosixPath(
            f"postgresql-{release}/src/test/regress/sql"
        )
        extracted: list[dict[str, object]] = []
        statement_root = temporary / "statements"
        statement_root.mkdir()
        with tarfile.open(archive, "r:gz") as source:
            for member in source.getmembers():
                member_path = PurePosixPath(member.name)
                if (
                    not member.isfile()
                    or member_path.parent != prefix
                    or member_path.suffix != ".sql"
                ):
                    continue
                input_file = source.extractfile(member)
                if input_file is None:
                    raise ValueError(f"cannot read {member.name} from {archive}")
                data = input_file.read()
                name = member_path.name
                (temporary / name).write_bytes(data)
                candidates = split_sql(data)
                offset = 0
                spans = []
                bundle = bytearray()
                for candidate in candidates:
                    spans.append((offset, len(candidate)))
                    bundle.extend(candidate)
                    offset += len(candidate)
                candidate_path = statement_root / name
                spans_path = statement_root / (name + ".spans")
                candidate_path.write_bytes(bundle)
                spans_path.write_text(
                    "".join(f"{start} {length}\n" for start, length in spans)
                )
                extracted.append(
                    {
                        "name": name,
                        "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "candidate_count": len(candidates),
                        "candidate_sha256": digest(candidate_path),
                        "spans_sha256": digest(spans_path),
                    }
                )

        extracted.sort(key=lambda item: str(item["name"]))
        if not extracted:
            raise ValueError(f"no regression SQL files found in {archive}")
        (temporary / "files.txt").write_text(
            "".join(f"{item['name']}\n" for item in extracted)
        )
        manifest = {
            "format_version": FORMAT_VERSION,
            "postgresql_major": major,
            "postgresql_release": release,
            "archive": archive.name,
            "archive_sha256": archive_digest,
            "file_count": len(extracted),
            "total_bytes": sum(int(item["bytes"]) for item in extracted),
            "files": extracted,
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(temporary, destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def prepare(major: int, cache: Path, offline: bool) -> None:
    details = metadata(major)
    release = str(details["postgresql_release"])
    archive_digest = str(details["postgresql_archive_sha256"])
    destination = cache / "corpus" / f"v{major}"
    if existing_corpus_is_current(destination, release, archive_digest):
        return
    archive = require_archive(release, archive_digest, cache / "archives", offline)
    extract_corpus(archive, destination, major, release, archive_digest)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--major", type=int, choices=MAJORS, action="append", dest="majors"
    )
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument(
        "--offline", action="store_true", help="fail instead of downloading archives"
    )
    args = parser.parse_args()

    for major in args.majors or MAJORS:
        prepare(major, args.cache, args.offline)
    print((args.cache / "corpus").resolve())


if __name__ == "__main__":
    main()
