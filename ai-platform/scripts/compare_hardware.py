#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.hardware import compare_snapshots  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("previous")
    parser.add_argument("current")
    parser.add_argument("--output")
    args = parser.parse_args()
    result = compare_snapshots(
        json.loads(Path(args.previous).read_text(encoding="utf-8")),
        json.loads(Path(args.current).read_text(encoding="utf-8")),
    )
    body = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(body, encoding="utf-8")
        os.replace(temporary, target)
    else:
        print(body, end="")


if __name__ == "__main__":
    main()

