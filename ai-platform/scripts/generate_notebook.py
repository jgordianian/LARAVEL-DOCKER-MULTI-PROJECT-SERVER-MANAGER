#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app.notebooks import NOTEBOOK_KINDS, generate_notebook  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a credential-free AI Platform test notebook")
    parser.add_argument("kind", choices=sorted(NOTEBOOK_KINDS))
    parser.add_argument("--output-dir", default="/opt/vllm-ai-platform/notebooks")
    parser.add_argument("--owner")
    args = parser.parse_args()

    target = generate_notebook(args.kind, Path(args.output_dir), args.owner)
    print(json.dumps({"created": str(target), "kind": args.kind, "contains_credentials": False}))


if __name__ == "__main__":
    main()
