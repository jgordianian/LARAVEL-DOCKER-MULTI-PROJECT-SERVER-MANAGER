#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tarfile
from pathlib import Path, PurePosixPath


def validate_member(member: tarfile.TarInfo) -> None:
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe archive path: {member.name}")
    if member.isdev() or member.isfifo():
        raise ValueError(f"unsupported archive entry: {member.name}")
    if member.issym() or member.islnk():
        raise ValueError(f"archive links are not supported: {member.name}")


def inspect(archive: Path) -> dict:
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            validate_member(member)
        try:
            manifest_file = bundle.extractfile("manifest.json")
        except KeyError:
            manifest_file = None
        if manifest_file is None:
            raise ValueError("backup manifest is missing")
        manifest = json.load(manifest_file)
        if manifest.get("format") != "vllm-ai-platform-backup" or manifest.get("schema_version") != 1:
            raise ValueError("unsupported backup format or schema")
        return manifest


def extract(archive: Path, destination: Path) -> None:
    inspect(archive)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            validate_member(member)
            target = (destination / member.name).resolve()
            if destination.resolve() != target and destination.resolve() not in target.parents:
                raise ValueError(f"archive entry escapes destination: {member.name}")
            bundle.extract(member, destination)


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    item = sub.add_parser("inspect"); item.add_argument("archive")
    item = sub.add_parser("extract"); item.add_argument("archive"); item.add_argument("destination")
    item = sub.add_parser("checksum"); item.add_argument("archive")
    args = parser.parse_args()
    archive = Path(args.archive)
    if args.command == "inspect":
        print(json.dumps(inspect(archive), indent=2, sort_keys=True))
    elif args.command == "extract":
        extract(archive, Path(args.destination))
    else:
        print(checksum(archive))


if __name__ == "__main__":
    main()

