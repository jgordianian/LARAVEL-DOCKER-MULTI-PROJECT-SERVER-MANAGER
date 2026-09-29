#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app.environment import probe_environment, write_snapshot  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Read-only host/container and Jupyter environment probe")
    parser.add_argument("--platform-root", default="/opt/vllm-ai-platform")
    parser.add_argument("--output")
    parser.add_argument("--test-pytorch", action="store_true")
    args = parser.parse_args()

    snapshot = probe_environment(platform_root=Path(args.platform_root), test_pytorch=args.test_pytorch)
    if args.output:
        write_snapshot(snapshot, Path(args.output))
    else:
        print(json.dumps(snapshot, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
