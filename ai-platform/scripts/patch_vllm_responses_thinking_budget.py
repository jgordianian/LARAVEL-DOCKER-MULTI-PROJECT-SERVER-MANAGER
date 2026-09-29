#!/usr/bin/env python3
"""Add thinking_token_budget to vLLM 0.30's Responses request protocol.

vLLM's sampler supports the budget and Chat Completions exposes it, but the
0.30 ResponsesRequest model does not. This narrow, idempotent compatibility
patch can be removed after the upstream Responses protocol exposes the field.
"""

from __future__ import annotations

import inspect
from pathlib import Path

import vllm.entrypoints.openai.responses.protocol as protocol


def main() -> None:
    path = Path(inspect.getsourcefile(protocol) or "")
    if not path.is_file():
        raise SystemExit("Unable to locate the vLLM Responses protocol")
    source = path.read_text(encoding="utf-8")
    if "thinking_token_budget: ThinkingTokenBudget" in source:
        print(f"vLLM Responses thinking budget already supported: {path}")
        return

    import_old = """from vllm.sampling_params import (\n    RequestOutputKind,\n    SamplingParams,\n    StructuredOutputsParams,\n)"""
    import_new = """from vllm.sampling_params import (\n    RequestOutputKind,\n    SamplingParams,\n    StructuredOutputsParams,\n    ThinkingTokenBudget,\n)"""
    field_old = "    reasoning: Reasoning | None = None\n    include_reasoning: bool = Field("
    field_new = (
        "    reasoning: Reasoning | None = None\n"
        "    thinking_token_budget: ThinkingTokenBudget = None\n"
        "    include_reasoning: bool = Field("
    )
    sampling_old = "            structured_outputs=self.extract_structured_outputs(),\n            logit_bias=self.logit_bias,"
    sampling_new = (
        "            structured_outputs=self.extract_structured_outputs(),\n"
        "            thinking_token_budget=self.thinking_token_budget,\n"
        "            logit_bias=self.logit_bias,"
    )
    replacements = (
        (import_old, import_new, "sampling import"),
        (field_old, field_new, "request field"),
        (sampling_old, sampling_new, "sampling parameter"),
    )
    for old, new, label in replacements:
        if source.count(old) != 1:
            raise SystemExit(f"Refusing to patch unexpected vLLM protocol ({label})")
        source = source.replace(old, new, 1)

    path.write_text(source, encoding="utf-8")
    print(f"Patched vLLM Responses thinking budget support: {path}")


if __name__ == "__main__":
    main()
