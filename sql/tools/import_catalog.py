#!/usr/bin/env python3
"""Import PostgreSQL catalog type definitions from an official source archive."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import tarfile
from pathlib import Path


VERSIONS = (14, 15, 16, 17, 18)
CATALOG_FILES = ("pg_type.dat", "pg_type.h", "pg_range.dat")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def published_digest(path: Path) -> str:
    fields = path.read_text().split()
    if not fields or len(fields[0]) != 64:
        raise ValueError(f"invalid PostgreSQL SHA-256 file: {path}")
    return fields[0].lower()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--major", type=int, choices=VERSIONS, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sha256", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()

    if int(args.release.split(".", 1)[0]) != args.major:
        raise ValueError("release and major version do not agree")
    actual = digest(args.archive)
    expected = published_digest(args.sha256)
    if actual != expected:
        raise ValueError(f"archive SHA-256 mismatch: expected {expected}, got {actual}")

    destination = args.destination.resolve()
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    prefix = f"postgresql-{args.release}/src/include/catalog/"
    with tarfile.open(args.archive, "r:bz2") as archive:
        for name in CATALOG_FILES:
            member = archive.getmember(prefix + name)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"could not read {member.name}")
            (destination / name).write_bytes(source.read())

    (destination / "UPSTREAM.toml").write_text(
        f'''postgresql_major = {args.major}
postgresql_release = "{args.release}"
archive = "postgresql-{args.release}.tar.bz2"
archive_sha256 = "{actual}"
sha256_verified_against = "https://ftp.postgresql.org/pub/source/v{args.release}/postgresql-{args.release}.tar.bz2.sha256"
source = "https://ftp.postgresql.org/pub/source/v{args.release}/"
files = ["src/include/catalog/pg_type.dat", "src/include/catalog/pg_type.h", "src/include/catalog/pg_range.dat"]
'''
    )


if __name__ == "__main__":
    main()
