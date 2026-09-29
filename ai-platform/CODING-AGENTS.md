# Private Coding Agents and IDE Clients

This guide connects approved development machines to the existing AI Gateway. It does not expose vLLM, add a second gateway, or run developer commands on the VPS.

```text
Codex / VS Code / Continue
        | HTTPS + coding API key
        v
existing AI Gateway (/v1)
        | auth, CIDR, endpoint/model scopes, quotas, audit, usage
        v
existing model router -> private vLLM coding model

Repository files, Git, terminal, tests and builds stay in the local IDE/client workspace.
```

The model reasons, generates code and selects tools. The coding client owns repository access, path boundaries, edits, Git, terminal execution, tests and confirmation prompts. The public Gateway has no shell endpoint, and vLLM receives no host or developer-workstation filesystem mount.

## 1. Register and install a coding model

Use the existing root manager:

1. Open `22) Manage vLLM / AI Platform`.
2. Open `9) Manage models`.
3. Choose `2) Install a current stable model (guided)` and select `Qwen 2.5 Coder 7B AWQ`, or choose `3) Add arbitrary Hugging Face model`.
4. Use the stable public alias `omnivis-coder`.
5. Verify the model's actual capabilities and configure only its documented tool-call parser/chat template. Do not copy a parser from another model family.
6. Download the model, inspect its compatibility plan, then activate it.

The curated entry is a starting point, not a hardware guarantee. It uses an 8,192-token context and AWQ weights to make smaller GPU evaluation practical. Revalidate the exact revision, architecture, vLLM image, parser, VRAM estimate and output quality before production use.

Equivalent controller commands:

```bash
cd /opt/vllm-ai-platform

docker compose exec -T controller python -m app.cli models add \
  --model-id Qwen/Qwen2.5-Coder-7B-Instruct-AWQ \
  --revision 8e8ed243bbe6f9a5aff549a0924562fc719b2b8a \
  --alias omnivis-coder \
  --capabilities general,chat,completions,responses,coding,agentic,reasoning,tool_calling \
  --estimated-weight-gb 5 \
  --quantization awq \
  --max-model-len 8192 \
  --tool-calling \
  --tool-call-parser hermes \
  --performance-profile BALANCED

docker compose exec -T controller python -m app.cli models download omnivis-coder
docker compose exec -T controller python -m app.cli models plan omnivis-coder
docker compose exec -T controller python -m app.cli models activate omnivis-coder
```

Prefer a reviewed immutable Hugging Face commit in place of `main` for reproducible deployments. If the selected model does not truly support the Responses API and tool calling, remove those capabilities; the platform must not advertise compatibility that was not validated.

An optional embedding alias such as `omnivis-embed` uses the same Model Manager and `/v1/embeddings` route. It can remain downloaded but inactive when VRAM cannot safely hold both models.

## 2. Responses API and tool calling

The Gateway supports both:

- `POST /v1/chat/completions`
- `POST /v1/responses`

It preserves compatible `tools`, `tool_choice`, returned tool calls, structured-output fields and streaming events. It does not emulate unsupported vLLM/model behavior. A model must include the `responses` capability, be configured for tool calling when tools are sent, and have the correct parser/template for that model.

After activation, the controller probes the private runtime OpenAPI document and stores which routes were actually advertised. The Models page and `coding-diagnostics` distinguish:

- configured support;
- runtime-verified support;
- configured but not yet verified;
- unsupported by the active runtime.

Run:

```bash
sudo ./laravel-server-manager.sh ai-diagnostics
cd /opt/vllm-ai-platform
docker compose exec -T controller python -m app.cli coding-diagnostics
```

If `/v1/responses` is not verified, Codex Responses mode is not ready. Fix the pinned vLLM/model/parser combination or use a client workflow that the verified Chat Completions route supports. Do not add a fake translation layer.

## 3. Create an isolated Coding Agent identity

Open `https://AI_DOMAIN/admin/service-accounts` and create:

```text
Name: Jonah Development
Purpose: Coding Agent
Allowed models: omnivis-coder
Scopes: models,chat,responses,tools,coding
Allowed endpoints: /v1/models,/v1/chat/completions,/v1/responses
```

Then configure conservative requests/minute, tokens/minute, monthly tokens and concurrent requests. Purpose is administrative metadata; actual authorization comes from all of the model, scope, endpoint, CIDR and quota rules.

At `/admin/security`, add a `service_account` CIDR rule for the developer's stable public IP or VPN subnet. At `/admin/api-keys`, create a key owned by `Jonah Development` with:

- model `omnivis-coder` explicitly listed;
- scopes `models,chat,responses,tools,coding`;
- the same three endpoints explicitly listed;
- developer/VPN CIDRs;
- an expiry and workload-appropriate quotas.

Copy the complete `ovai_live_...` value once into the workstation's secret store or environment. Never place it in source control, examples, shell history, screenshots or IDE workspace settings.

Create a separate production account and key, for example:

```text
Omnivis Production -> omnivis-general -> models,chat -> production CIDRs
Jonah Development  -> omnivis-coder   -> models,chat,responses,tools,coding -> developer/VPN CIDRs
```

Do not leave `Allowed models` blank for either identity: blank retains the legacy “all models subject to other policy” behavior. Do not reuse an Omnivis production key in an IDE.

## 4. Verify from the development machine

Set placeholders locally:

```bash
export OMNIVIS_AI_BASE_URL="https://ai.example.com/v1"
export OMNIVIS_CODING_API_KEY="ovai_live_REPLACE_WITH_ONE_TIME_SECRET"
```

PowerShell:

```powershell
$env:OMNIVIS_AI_BASE_URL = "https://ai.example.com/v1"
$env:OMNIVIS_CODING_API_KEY = "ovai_live_REPLACE_WITH_ONE_TIME_SECRET"
```

Validate model visibility:

```bash
curl "$OMNIVIS_AI_BASE_URL/models" \
  -H "Authorization: Bearer $OMNIVIS_CODING_API_KEY"
```

Only explicitly authorized, active, ready models should appear. Test Chat Completions:

```bash
curl "$OMNIVIS_AI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $OMNIVIS_CODING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"omnivis-coder","messages":[{"role":"user","content":"Reply with one sentence."}]}'
```

Test Responses only when diagnostics verify it:

```bash
curl "$OMNIVIS_AI_BASE_URL/responses" \
  -H "Authorization: Bearer $OMNIVIS_CODING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"omnivis-coder","input":"Explain the current directory architecture briefly."}'
```

## 5. Codex-compatible configuration

Current Codex custom providers use the Responses wire API. Put the provider in the user-level `~/.codex/config.toml`, not a repository file:

```toml
model = "omnivis-coder"
model_provider = "omnivis_gateway"

[model_providers.omnivis_gateway]
name = "Omnivis Private vLLM Gateway"
base_url = "https://ai.example.com/v1"
env_key = "OMNIVIS_CODING_API_KEY"
wire_api = "responses"
```

Export `OMNIVIS_CODING_API_KEY` before starting Codex from the repository directory. The alias must exactly match the Gateway alias; the client never needs a vLLM container name, port, Docker hostname or Hugging Face ID.

This format follows the official [Codex configuration reference](https://developers.openai.com/codex/config-reference), which defines custom provider `base_url`, `env_key` and the `responses` wire API. vLLM's [Codex integration guide](https://docs.vllm.ai/en/latest/serving/integrations/codex/) also requires a Responses-capable model with correct tool calling.

Codex executes its local tools according to the client's sandbox and approval policy. Connecting it to this Gateway does not give the server access to the repository.

## 6. VS Code and Continue

Continue uses an OpenAI-compatible model block. Store the key in Continue's secret mechanism, not directly in `config.yaml`:

```yaml
name: Omnivis Private Coding
version: 1.0.0
schema: v1

models:
  - name: Omnivis Coder
    provider: openai
    model: omnivis-coder
    apiBase: https://ai.example.com/v1
    apiKey: ${{ secrets.OMNIVIS_CODING_API_KEY }}
    roles:
      - chat
      - edit
      - apply
    capabilities:
      - tool_use
    defaultCompletionOptions:
      contextLength: 8192
      maxTokens: 4096
```

Remove `tool_use` and do not use Agent mode unless model tool calling has been tested through the Gateway. Continue's current YAML roles and OpenAI-compatible `apiBase` are documented in its [configuration reference](https://docs.continue.dev/reference). A separate `omnivis-embed` block can use role `embed`; it does not need to remain active with the coding model on a constrained GPU.

Other VS Code coding extensions should use:

```text
Provider: OpenAI-compatible
Base URL: https://ai.example.com/v1
API key: workstation secret/environment
Model: omnivis-coder
```

Enable Chat, Edit, Apply or Agent features only when that client/model combination supports them. Generic Chat Completions clients do not automatically become agentic merely because the model has a `coding` badge.

## 7. Coding modes and repository context

- Chat mode: explanations and questions; no automatic file edits.
- Edit mode: targeted edits selected by the developer.
- Agent mode: multi-step search, read, edit, terminal/test and correction loops through local tools.

The client should select relevant context instead of uploading the whole repository on every turn. Prefer lexical/semantic search, repository maps, relevant files, Git diff, summaries and optional embeddings. Prompt/source-code logging remains off in the platform by default; client-side telemetry is controlled separately by the chosen client.

## 8. Tool security policy

| Class | Default | Examples |
| --- | --- | --- |
| Read-only | Auto allow inside the authorized workspace | `list_files`, `search_code`, `read_file`, `git status`, `git diff`, `git log` |
| Normal development | Confirm initially; optionally allow narrowly | `edit_file`, `apply_patch`, `run_tests`, `run_linter`, `run_formatter`, `run_build` |
| Sensitive | Confirm every operation | package installs, migrations, `git commit`, `git push`, network access |
| High-risk | Deny by default | destructive filesystem commands, database deletion, production deploy, credential changes, force push |

Recommended Git policy:

- automatic/read-only: `git status`, `git diff`, `git log`;
- explicit confirmation: `git commit`, `git push`;
- deny by default: `git reset --hard`, `git push --force`, branch deletion.

Limit every local agent to the intended repository/workspace. If a future server-side execution service is added, it is a separate security project: run non-root in an isolated container, canonicalize paths, block traversal and symlink escapes, restrict environment/secrets/network, cap time/output, allowlist commands, audit execution and never expose a public generic shell route.

## 9. MCP

Approved filesystem, Git, GitHub, documentation or development-database MCP servers may be configured in the coding client. Do not auto-connect arbitrary MCP servers. MCP authorization and execution stay in the client/tool environment unless a separately secured platform integration is deliberately designed.

Never connect the coding identity automatically to the Omnivis production database. Development databases and credentials require a separate, explicit integration with their own access policy.

## 10. Low-VRAM switching

Both `omnivis-general` and `omnivis-coder` may remain downloaded while only one is active. Use:

```bash
cd /opt/vllm-ai-platform
docker compose exec -T controller python -m app.cli models plan omnivis-coder
docker compose exec -T controller python -m app.cli models switch omnivis-coder
```

Or use the Models page / manager option `Plan/safely switch active model for limited VRAM`. The plan displays estimated required VRAM, current safe capacity, capacity after stopping conflicts and the exact active aliases affected. The switch:

1. stops only active models on overlapping GPU assignments;
2. preserves their registry records, weights and independent performance profiles;
3. activates and readiness-checks the target;
4. attempts to restore previously active models if target activation fails;
5. audits the operation and any rollback error.

To return to general inference, plan/switch to `omnivis-general`. On multiple GPUs, assign non-overlapping GPU indexes and validate each plan; safe models can remain active simultaneously. Future GPU upgrades are detected by the existing hardware snapshot system and do not require reinstalling the coding feature.

## 11. Usage and audit

The existing accounting records the service account, API key ID/prefix, alias, endpoint, input/output/total tokens, source IP, latency, request ID, streaming flag and status. The Usage page labels production and coding workloads by service-account purpose. Complete keys and prompt/source bodies are not recorded.

## 12. Troubleshooting

- `401 invalid_api_key`: confirm the one-time key was copied exactly and has not expired or been rotated/revoked.
- `403 ip_access_denied`: confirm the workstation's public/VPN address matches every configured global, service-account and key CIDR layer.
- `403 model_access_denied`: explicitly add `omnivis-coder` to both the service account and key.
- `403 scope_denied`: coding models require `coding`; requests containing tools also require `tools`; the route still requires its normal `chat` or `responses` scope.
- `403 endpoint_access_denied`: add the exact `/v1/...` route to both the account and key endpoint lists.
- `400 endpoint_not_supported`: the model lacks the endpoint capability or the active runtime probe verified that the route is absent.
- tools are plain text or malformed: verify the exact model parser/chat template and inspect sanitized vLLM logs; never select a parser by guesswork.
- Codex connects but cannot act: verify `/v1/responses`, streaming and tool calling in diagnostics. Codex currently expects Responses wire mode.
- Continue Agent mode is unavailable: verify `tool_use`, model tool configuration and Gateway `tools` scope; use Chat/Edit mode until validated.
- `429`: inspect key and service-account rate/token/monthly/concurrency quotas.
- activation is blocked: reduce context/sequences, choose an appropriate quantization/profile, assign another GPU, or use the explicit capacity switch.
- model is absent from `/v1/models`: it must be active/ready and authorized for the key's model, endpoint and coding scopes.

Never troubleshoot by publishing the private vLLM port or disabling Gateway authentication.
