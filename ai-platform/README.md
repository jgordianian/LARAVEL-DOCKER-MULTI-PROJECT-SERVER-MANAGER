# vLLM AI Platform Operations Guide

This directory contains the installable AI subsystem for the Laravel Docker Multi-Project Server Manager. The Bash manager orchestrates these assets; it does not generate a second reverse proxy or embed the application source in heredocs.

## Architecture

```text
Internet
   |
   | HTTPS :443
   v
existing laravel-reverse-proxy (Nginx + Certbot)
   |                         |
   | /v1/*                  | /, /admin, /api/*
   v                         v
FastAPI Gateway          Web application
   | auth, policy,           | sessions, CSRF,
   | quotas, routing         | RBAC, chat
   +------------+------------+
                |
       vllm-ai-internal
       (Docker internal)
        |      |       |
        v      v       v
     vLLM A  vLLM B  vLLM C
        |
 PostgreSQL + Redis

Controller -> Docker socket -> managed vLLM containers
```

On a provider CUDA container without Docker, the external contract remains the same while the private implementation changes:

```text
SSH/Vast private access -> 127.0.0.1:8000 Gateway -> 127.0.0.1:19000-19999 vLLM processes
                              |
                              +-> 127.0.0.1:18080 admin/chat
                              +-> SQLite + 127.0.0.1:16379 Redis

provider Jupyter on :8080 is detected and preserved independently
```

The HTTPS proxy is the only service binding public host ports. The Gateway and web application join the existing `laravel-shared` network only so Nginx can reach them. PostgreSQL, Redis, the runtime controller and all vLLM instances use the private `vllm-ai-internal` network and have no published host ports.

The Gateway, rather than vLLM, is the external security boundary. It authenticates requests, resolves the client address only when a proxy-shared secret and a trusted peer are present, enforces layered CIDR rules, authorizes models and scopes, applies rate/token/request/concurrency limits, routes by stable model alias, records usage, and sanitizes errors.

Approved developer IDEs and coding agents use this same Gateway and Model Manager. See the [private coding-agent and IDE guide](./CODING-AGENTS.md) for model registration, isolated developer credentials, Codex/VS Code/Continue configuration, tool policy, Responses compatibility and low-VRAM switching. No coding feature exposes vLLM or a server-side shell.

Provider or locally managed Jupyter environments remain optional, independent diagnostic clients. See the [Jupyter/JupyterLab integration guide](./JUPYTER.md) for Vast.ai detection and preservation, container capability adaptation, secure notebooks and optional isolated normal-VPS installation. The platform never makes vLLM depend on Jupyter.

## Installed layout

```text
/opt/vllm-ai-platform/
  .env                    # root-only credentials and deployment settings
  .ai-platform-meta       # schema/install metadata
  compose.yaml
  app/                    # Gateway, controller, web application
  config/                 # catalog, profiles, vLLM compatibility matrix
  migrations/             # Alembic database migrations
  scripts/                # hardware probe/comparison and safe archives
  database/               # PostgreSQL data
  redis/                  # Redis AOF data
  models/                 # managed model weights
  hf-cache/               # Hugging Face cache
  model-configs/
  generated/
  hardware/               # hardware baseline/change plus sanitized environment snapshot
  notebooks/              # version-safe diagnostics, benchmarks and examples
  state/                  # non-secret optional integration ownership markers
  native/                 # native platform/vLLM virtual environments and supervisor config
  logs/
  secrets/hf_token        # root-only optional Hugging Face token

/var/backups/vllm-ai-platform/
  vllm-ai-platform-*.tar.gz
  vllm-ai-platform-*.tar.gz.sha256
```

Repair and update operations synchronize application assets while explicitly preserving `.env`, secrets, database data, Redis data, model weights, Hugging Face cache, hardware history, native virtual environments, generated configuration and logs.

Notebook workspaces and optional Jupyter virtual environments are also preserved during repair/update. The virtual environment is excluded from normal backups and should be recreated explicitly; generated notebooks are included unless the administrator removes them.

## Docker services

| Service | Purpose | Public port |
| --- | --- | --- |
| `postgres` | Relational platform state | None |
| `redis` | Rate limits, quotas and concurrency counters | None |
| `migrate` | One-shot Alembic migration job | None |
| `gateway` | OpenAI-compatible authenticated API | None; Nginx routes `/v1/` |
| `web` | Administration and chat application | None; Nginx routes web paths |
| `controller` | Model downloads and Docker runtime lifecycle | None |
| `vllm-ai-<alias>` | One private runtime per active model | None |

Application containers drop Linux capabilities, set `no-new-privileges`, use read-only root filesystems where practical, have health checks, and use bounded Docker JSON logs. The controller is deliberately a trusted root-only control-plane component because it needs the Docker socket to create GPU containers. It is private, token-authenticated, and must never be attached to the public proxy network.

## Requirements

- Ubuntu Server 22.04 or a compatible apt-based host.
- Root access.
- Docker and Docker Compose. The existing manager installs them if necessary.
- A DNS `A`/`AAAA` record for the AI domain.
- TCP ports 80 and 443 available through the existing reverse proxy.
- A supported NVIDIA driver for NVIDIA vLLM inference.
- NVIDIA Container Toolkit with a successful Docker GPU validation.
- Enough disk for model weights plus the configured reserve (20 GiB by default).

The installer checks `nvidia-smi` and separately runs a disposable CUDA container. A working host driver does not prove Docker GPU access.

AMD display hardware is detected and reported as ROCm not configured. This release does not pretend the NVIDIA runtime path supports AMD. Gateway, database, administration and chat services still run, while unsafe model activation is blocked.

### Native Vast.ai/container requirements

Native mode is intended for Linux NVIDIA marketplace containers where CUDA is already supplied by the provider but no Docker daemon or systemd is available. It requires root for initial setup, Python 3.10-3.14, `nvidia-smi`, an apt-compatible `redis-server`, and enough storage for the vLLM/PyTorch wheels, model weights and the configured reserve. The installer uses the official `uv pip install vllm==<pinned-version> --torch-backend=auto` flow in `/opt/vllm-ai-platform/native/vllm-venv`; it never installs vLLM or PyTorch into Jupyter's Python.

Native services run as the dedicated `vllmai` account under Supervisor. Gateway `8000`, controller `8090`, web `18080`, Redis `16379`, and model ports `19000-19999` bind only to `127.0.0.1`. No Vast.ai external port, provider proxy, Jupyter token, startup command, firewall or systemd unit is created or changed. Use an SSH tunnel, a provider-approved private port mapping, or the manager's reviewed Cloudflare Tunnel workflow.

SQLite is used for durable application state in native mode. Redis remains mandatory for atomic quotas, rate limits, concurrency leases and login throttling. Backups use SQLite's online backup API and may be restored only into the same runtime mode; Docker/PostgreSQL-to-native conversion is intentionally not automatic.

### GTX 1650 / 4 GiB example

A GTX 1650 can host the control plane, Gateway, administration panel, chat portal, API integration development, and appropriately small/quantized models. It cannot safely load models whose weights, KV cache and runtime overhead exceed its 4 GiB VRAM. Compatibility output is an estimate, not a guarantee; begin with the conservative profile, a short context and low concurrency.

## Exact first installation

Copy or clone the complete repository. Do not copy only the Bash script because the `ai-platform/` assets must remain beside it.

```bash
sudo -i
apt-get update
apt-get install -y git
git clone <YOUR_REPOSITORY_URL> /root/laravel-server-manager
cd /root/laravel-server-manager
chmod 700 laravel-server-manager.sh
./laravel-server-manager.sh
```

Then:

1. Choose `22) Manage vLLM / AI Platform`.
2. Choose `1) Install or repair AI platform`.
3. Enter the dedicated AI DNS name and a Let's Encrypt email.
4. Accept the pinned `vllm/vllm-openai:v0.30.0` default or enter another explicit tag. Never use an unreviewed floating `latest` tag in production.
5. Choose whether the administration panel and chat portal are enabled.
6. Enter an optional Hugging Face token using the hidden prompt. Blank means public-only on first install and preserves an existing token during repair.
7. Let the manager validate Docker GPU access. If validation fails, use the offered NVIDIA Container Toolkit repair after confirming the host driver works.
8. Create the first administrator with a unique password of at least 12 characters using at least three character categories.
9. Optionally register an initial curated model. Registration alone does not download or activate it.
10. Confirm the final Compose, service-health, and HTTPS status.
11. Open `https://AI_DOMAIN/admin`, sign in, and download/activate a small model appropriate for the current GPU.

Installation is idempotent. Re-running it does not reset users, conversations, keys, quotas, audit records, models, weights, database files, Redis state or secrets.

## Native installation on Vast.ai

Use this path when environment diagnostics report `VAST_AI_CONTAINER`, CUDA/GPU visibility is healthy, and Docker is unavailable:

```bash
sudo ./laravel-server-manager.sh ai-install-native
```

The installer:

1. preserves the existing provider Jupyter process and configuration;
2. installs only missing OS prerequisites (`python3-venv`, `redis-server`, or `util-linux`);
3. creates the `vllmai` service account and restricted state directories;
4. installs the control plane into `native/platform-venv`;
5. installs the pinned vLLM package into the separate `native/vllm-venv` using automatic CUDA/PyTorch backend selection;
6. configures SQLite, authenticated Redis and Supervisor;
7. migrates the database, starts Gateway/web/controller, and performs loopback health checks;
8. creates the first administrator without printing the password;
9. leaves model download and activation explicit.

Normal operations use the same commands in both modes:

```bash
sudo ./laravel-server-manager.sh ai-start
sudo ./laravel-server-manager.sh ai-status
sudo ./laravel-server-manager.sh ai-diagnostics
sudo ./laravel-server-manager.sh ai-models list
sudo ./laravel-server-manager.sh ai-stop
```

For private workstation access, forward only the desired loopback listeners, for example `8000` for the API and `18080` for the panel. Do not forward raw model ports. Native mode has no system boot integration inside a marketplace container; after a provider container restart, run `ai-start`. Supervisor restarts failed control-plane processes while the container remains alive, and reconciliation restores only models marked desired/auto-start after capacity validation.

### Custom domain with Cloudflare Tunnel

Choose `21) External domain / Cloudflare Tunnel` from the AI Platform menu, or run `sudo ./laravel-server-manager.sh ai-external`. Create a remotely-managed Cloudflare Tunnel in the dashboard and copy only its connector token; do not run Cloudflare's systemd installer. The manager starts the connector first so Cloudflare can mark it Connected. Then create these Published application routes:

- panel hostname (for example `ia.example.com`) -> `http://localhost:18080`;
- optional API hostname (for example `api.example.com`) -> `http://localhost:8000`;
- final catch-all -> `http_status:404`.

The manager verifies a `cloudflared` version with `--token-file` support, accepts the connector token without terminal echo, stores it at `secrets/cloudflare_tunnel_token` with `0640 root:vllmai`, and never places it in process arguments. It then adds `cloudflared` to the native Supervisor configuration, changes `AI_DOMAIN`, `ALLOWED_ORIGINS`, and `COOKIE_SECURE`, restarts the control plane, and reports connector/public health. The same menu provides status, logs, and a disable action that removes the managed public route locally and returns the platform to loopback/SSH access. The Cloudflare API route still requires a platform API key; the panel retains its own login. Use Cloudflare Access as an additional panel policy when appropriate.

This workflow does not publish Jupyter, Redis, the controller, or raw model ports. A Vast.ai stop/start keeps the connector files, but recycle/destroy removes them when `/workspace` is not a persistent volume; the Cloudflare-side tunnel remains and a replacement connector must then be provisioned.

## NVIDIA Container Toolkit

Menu option `Install or repair NVIDIA Container Toolkit` follows NVIDIA's stable apt repository flow and calls:

```bash
nvidia-ctk runtime configure --runtime=docker
```

Before modification, an existing `/etc/docker/daemon.json` is copied to a timestamped backup. The result is parsed as JSON before Docker is restarted. Existing unrelated daemon settings are preserved by `nvidia-ctk`; invalid output is rolled back. The final proof is a real `docker run --rm --gpus all ... nvidia-smi -L`, never a fabricated success.

Official references:

- [vLLM Docker deployment](https://docs.vllm.ai/en/latest/deployment/docker/)
- [vLLM serve options](https://docs.vllm.ai/en/stable/cli/serve/)
- [NVIDIA Container Toolkit installation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

## Hardware snapshots and change detection

`scripts/hardware_probe.py` records:

- OS and kernel;
- CPU model, logical cores and load;
- installed/available RAM;
- AI filesystem capacity;
- every NVIDIA GPU index, UUID, model, total/used/free VRAM, utilization, temperature, driver, CUDA compatibility, power readings and compute capability where available;
- AMD detection status;
- Docker version and optional real container GPU validation.

The first capture becomes `hardware/baseline.json`. Every later start or explicit analysis writes `hardware/current.json` atomically and produces `hardware/change.json`. Comparison covers CPU cores, RAM, storage, added/removed GPUs, GPU model, total VRAM and driver changes. It classifies upgrades and downgrades and flags configurations requiring model review.

A locked cron task refreshes the non-disruptive host snapshot once per minute, and the admin dashboard refreshes every 30 seconds. The expensive Docker GPU proof remains an explicit diagnostic rather than a polling task.

The same refresh writes `hardware/environment.json` using a read-only environment/Jupyter probe. It classifies normal hosts and marketplace containers, identifies provider-managed Jupyter without reading tokens or runtime-file contents, and reports systemd, Docker-daemon, privilege, firewall and LUKS capability separately. Host-only actions are not inferred merely because the process runs as root inside a container.

The manager never silently applies larger contexts, more concurrency, changed GPU assignments or different tensor parallelism after an upgrade. Review the comparison, deactivate a model, apply/recalculate `AUTO`, validate compatibility, reactivate it, and only then accept the new hardware baseline.

On a downgrade or removed GPU, normal platform services start but model reconciliation is capacity checked. An unsafe model is marked blocked and cannot enter an unbounded OOM restart loop.

## Model lifecycle

Downloaded and active are intentionally separate states:

- A downloaded model consumes disk only.
- An active model has one managed vLLM container (Docker mode) or verified process group (native mode) and consumes GPU/RAM/CPU resources.
- Downloading never activates every model.
- Deactivation removes the runtime container/process while preserving weights and configuration.

The root model manager supports arbitrary compatible Hugging Face IDs, a reviewed JSON catalog, pinned revisions, custom paths below `/opt/vllm-ai-platform/models`, aliases, resume/redownload, compatibility analysis, download status, size, activation/deactivation/restart, GPU assignments, tensor and pipeline parallelism, performance profiles, cloning, default selection, record-only deletion, and explicit weight deletion.

Choose `2) Install a current stable model (guided)` to see numbered, reviewed upstream models with purpose, approximate disk/VRAM, context, and a `FIT`, `TIGHT`, or `TOO LARGE` label calculated from the current GPU snapshot. The same assistant registers an immutable revision, displays the controller's live compatibility analysis, downloads resumably, optionally activates it, and can set its stable alias as the default. Catalog guidance is not a hardware guarantee; activation always repeats the live safety check.

```bash
sudo ./laravel-server-manager.sh ai-models
sudo ./laravel-server-manager.sh ai-models list
sudo ./laravel-server-manager.sh ai-models details omnivis-general
sudo ./laravel-server-manager.sh ai-models compatibility omnivis-general
```

The lower-level CLI runs inside the controller:

```bash
cd /opt/vllm-ai-platform
docker compose exec -T controller python -m app.cli models list
docker compose exec -T controller python -m app.cli models add \
  --model-id Qwen/Qwen3-0.6B \
  --revision main \
  --alias omnivis-general \
  --capabilities chat,completions \
  --estimated-weight-gb 1.4
docker compose exec -T controller python -m app.cli models download omnivis-general
docker compose exec -T controller python -m app.cli models compatibility omnivis-general
docker compose exec -T controller python -m app.cli models activate omnivis-general
```

Use an immutable Hugging Face commit hash for strict production reproducibility. `trust_remote_code` defaults off and must be explicitly accepted. Gated model failures and disk-reserve failures remain visible on the model record without exposing the HF token. Capability metadata supports `general`, `chat`, `agentic`, `coding`, `reasoning`, `tool_calling`, `responses`, `embeddings`, `structured_outputs` and `vision`; endpoint support and actual model behavior must still be verified.

### Capacity controls

Before activation, the controller estimates weight/runtime/KV usage using model size, dtype, context, sequences, selected GPU VRAM, memory-utilization target and estimated allocations of other active models. It validates selected GPU indexes and tensor parallel size. Results are labeled:

- `SAFE`
- `POSSIBLE WITH LIMITATIONS`
- `INCOMPATIBLE`

These are conservative estimates. Actual architecture, quantization, vLLM version and workload can change memory use. Activation still requires a real readiness response from vLLM before the alias becomes routable.

### Stable aliases

Clients call a stable alias such as `omnivis-general`, not a physical GPU or container name. You can download a stronger model later, health-check it, and explicitly change aliases/configuration. Alias changes are audited. Where old and new models fit concurrently, activate the replacement before changing client routing. On a small GPU, the activation plan can explicitly stop conflicting active models and start the selected model without deleting either model. It shows estimated required/current/after-switch capacity and attempts to restore prior models if activation fails.

### Performance profiles

Available modes are `AUTO`, `CONSERVATIVE`, `BALANCED`, `PERFORMANCE`, `MAXIMUM`, and `CUSTOM`. Profiles manage only vLLM software settings; they never change GPU voltage, clocks or power limits.

Applying a profile requires an inactive model, runs current-hardware compatibility validation, and refuses an unsafe result. The Performance page can stop an active model in place, then validate, apply and optionally reactivate it. `MAXIMUM` requires explicit acknowledgement. `AUTO` remains recorded as AUTO while noting the resolved profile, so it can be deliberately recalculated after a hardware change.

Compatibility, Prometheus metrics and sanitized runtime logs render inside authenticated administration pages. In native mode, model processes and their private state/log files run under `NATIVE_SERVICE_USER` even when an authorized root CLI launches the operation.

Version-aware flags are controlled by `config/vllm-compatibility.json`. Unknown extra flags are rejected unless enabled for the pinned image version, and security-sensitive managed flags such as host, port, model, served name, TLS and vLLM API key cannot be overridden.

## OpenAI-compatible API

Base URL:

```text
https://AI_DOMAIN/v1
```

Routes are capability checked:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/completions`
- `POST /v1/embeddings`
- `POST /v1/responses`

Only active, ready and authorized models appear. Unsupported endpoint/model combinations return a structured error rather than silently switching models.

```bash
curl https://ai.example.com/v1/chat/completions \
  -H 'Authorization: Bearer ovai_live_REPLACE_ONCE' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "omnivis-general",
    "messages": [{"role": "user", "content": "Reply briefly."}],
    "stream": true
  }'
```

Every inference response receives `X-Request-ID: req_...`. Errors use:

```json
{
  "error": {
    "type": "model_access_denied",
    "message": "This API key cannot access the requested model.",
    "request_id": "req_..."
  }
}
```

Streaming is relayed without Nginx buffering. Disconnects close the upstream request and release concurrency leases. Prompt bodies are not stored by default.

## API keys, service accounts and policy

API keys use `ovai_live_<id>.<secret>`. The complete value appears exactly once. PostgreSQL stores only a non-secret key ID/prefix and an Argon2 hash of an HMAC-peppered secret. Keys can be rotated, revoked, expired, restricted by model/scope/CIDR, and assigned per-minute, daily, monthly, token, input/output and concurrency limits.

Service accounts are separate from interactive users and can restrict models, scopes, endpoints, custom system messages and owner-level quotas. Purpose (`General API`, `Omnivis Production`, `Coding Agent`, or `Custom`) is administrative metadata, not authorization. Coding/agentic models require the `coding` scope; requests containing tools, reasoning controls, structured-output constraints or images require `tools`, `reasoning`, `structured_outputs` or `vision`, respectively. Separate production and developer credentials are mandatory. The effective limit is the stricter positive limit between an API key and its user/service-account owner. Redis enforces counters and concurrency; PostgreSQL holds durable policy and usage history.

CIDR policies support IPv4 and IPv6 at three layers:

1. global;
2. service account;
3. API key.

When a layer has rules, the request must match that layer and every other configured layer. The Gateway ignores client-supplied forwarding headers unless the direct peer is trusted and Nginx supplies the shared proxy token.

## System prompts and tool calling

Prompt precedence is:

1. a client system/developer message when that service account is explicitly allowed to send one;
2. per-user prompt;
3. per-model prompt;
4. global prompt.

OpenAI-style `tools`, `tool_choice` and returned `tool_calls` pass through unchanged. Enable tool calling only for a compatible model/parser/chat template. The AI platform never receives direct Omnivis SQL credentials.

Recommended Omnivis flow:

```text
user -> Omnivis authorization -> AI Gateway -> model tool request
     -> Omnivis validates permission/confirmation -> Omnivis performs operation
     -> audited tool result -> model final response
```

## Administration panel

`/admin` uses server-side sessions, Argon2 passwords, HttpOnly/Secure/SameSite cookies, CSRF validation, login throttling, server-side RBAC, no public signup, audit logging, ORM queries and restrictive security headers.

It provides working controls for:

- users, roles, enable/disable, password reset, forced password change and session termination;
- per-user model permissions and quotas;
- service accounts, scopes, model policy, custom system messages and quotas;
- one-time API key creation, rotation, revocation, expiry and limits;
- model registration, download, compatibility, activation, restart, default, alias/runtime configuration, internal metrics, sanitized logs, record deletion, explicit weight deletion and errors;
- performance profiles and hardware-change display;
- global/per-service/per-key IP rules;
- usage records, audit events and global prompt settings.

The administration and chat features can be independently disabled in the host manager. Disabled admin/chat routes return unavailable instead of relying only on hidden navigation.

Optional TOTP fields are reserved in the schema, but TOTP enrollment is not enabled in this release. It is not required for initial installation; use a VPN/SSO-capable upstream access layer if mandatory two-factor authentication is required now.

## Chat portal

The root page requires a provisioned account. It includes:

- active permitted model selection;
- private conversation history and search;
- new, rename and delete;
- streaming responses and stop/cancel;
- regenerate and edit/resend;
- Markdown and local code highlighting;
- copy response/code;
- timestamps, empty state and clean errors;
- profile password management and logout.

Markdown is escaped before formatting and no arbitrary HTML is accepted. Conversation queries always constrain by owner ID.

## Backups

The normal backup contains the database dump, application/configuration, secret metadata, aliases, model registry/configuration, prompts, users, key hashes, quotas, conversations, usage, audits and hardware baseline. It excludes PostgreSQL files, Redis files, model weights, HF cache and logs from the configuration copy; the consistent PostgreSQL dump contains durable database state.

```bash
sudo ./laravel-server-manager.sh ai-backup
```

Interactive backup optionally includes model weights; the default is no. Archives are mode `0600`, receive a SHA-256 file, and are validated by the safe archive parser. A daily locked cron job runs at 02:15. `AI_BACKUP_RETENTION_DAYS` defaults to 14.

## Restore and new-VPS migration

Restore validates archive paths, links, manifest format and schema before extraction. It creates a fresh safety backup, stops only AI services/model containers, restores configuration and PostgreSQL, applies migrations, compares current hardware, marks absent model paths as missing, offers Hugging Face redownload, and does not auto-start unsafe models.

Exact new-server migration:

1. On the old VPS, run `sudo ./laravel-server-manager.sh ai-backup`.
2. Copy the `.tar.gz` and `.sha256` to protected storage. Verify `sha256sum -c`.
3. Provision the new Ubuntu/NVIDIA host, install the NVIDIA driver, and copy this complete repository.
4. Before changing DNS, securely copy the existing certificate state separately (the AI backup deliberately does not contain private TLS keys): `mkdir -p /opt/laravel-reverse-proxy/certbot/conf && rsync -aHAX root@OLD_VPS:/opt/laravel-reverse-proxy/certbot/conf/ /opt/laravel-reverse-proxy/certbot/conf/`. Protect this transfer and directory as private-key material. Alternatively, schedule a brief DNS cutover so Certbot can issue on the new host.
5. Run the first-install procedure once on the new VPS with the production AI domain. This creates Docker networks and the base `/opt/vllm-ai-platform`; `--keep-until-expiring` reuses a copied valid certificate.
6. Securely copy the AI archive and checksum to the new VPS.
7. Open menu `22`, choose `18) Restore`, provide the archive, verify the displayed checksum/manifest, and type `RESTORE`.
8. Normally decline model-weight restore unless the archive includes them. Choose redownload for the required Hugging Face aliases.
9. Run hardware compatibility analysis for every required model and reconfigure GPU assignments/tensor parallelism for the new host.
10. Activate models one at a time and confirm readiness.
11. Validate before DNS with `curl --resolve AI_DOMAIN:443:NEW_VPS_IP https://AI_DOMAIN/health` and an authenticated `/v1/models` request.
12. Switch DNS/traffic only after HTTPS, API and chat validation; retain the old VPS until the rollback window closes.

## Upgrading from GTX 1650 to a larger GPU VPS

For an in-place provider upgrade:

```bash
sudo ./laravel-server-manager.sh ai-stop
# perform the provider/driver change and reboot
sudo ./laravel-server-manager.sh ai-hardware
sudo ./laravel-server-manager.sh ai-diagnostics
sudo ./laravel-server-manager.sh ai-start
```

Then:

1. Review `baseline.json` versus `current.json`; do not accept the new baseline yet.
2. Confirm the NVIDIA driver and real Docker GPU test.
3. Run compatibility on every configured model.
4. Deactivate the model before changing GPU, context, concurrency, tensor parallelism or profile.
5. Reapply `AUTO` or a chosen profile. The manager validates the result against current capacity.
6. Activate and test the model.
7. Repeat one model at a time.
8. Accept the new hardware baseline only after production validation.

For a 24 GiB or multi-GPU host, existing small models and aliases remain valid. You may add larger models, assign distinct GPUs to simultaneous instances, or use tensor parallelism across explicitly selected GPUs without reinstalling the platform.

## Updating vLLM

Use menu option `Update pinned platform version`. The manager:

1. shows the current tag;
2. requires another explicit `vllm/vllm-openai:<tag>`;
3. creates a database/configuration backup;
4. synchronizes application assets;
5. pulls the selected pinned vLLM image and validates Compose;
6. builds, migrates, and validates every stored model argument set against the selected version;
7. stops only managed model containers;
8. recreates AI services and strictly reconciles desired models;
9. restores the previous image tag and services when validation/startup fails where practical.

Review the compatibility matrix and upstream release notes before changing versions.

## Rollback

For an application/vLLM update rollback:

```bash
sudo ./laravel-server-manager.sh ai-stop
sudoedit /opt/vllm-ai-platform/.env
# restore the prior VLLM_IMAGE=vllm/vllm-openai:<previous-tag>
cd /opt/vllm-ai-platform
docker compose --env-file .env -f compose.yaml build
docker compose --env-file .env -f compose.yaml run --rm migrate
docker compose --env-file .env -f compose.yaml up -d
sudo /path/to/laravel-server-manager.sh ai-start
```

For a full data/configuration rollback, use menu `18) Restore` and select the safety backup created immediately before the change. The restore process itself creates another pre-restore backup.

For an Nginx failure, the installer restores the saved prior AI vhost and validates Nginx before restart. For NVIDIA runtime changes, restore the timestamped `/etc/docker/daemon.json.before-vllm.*`, validate it with `python3 -m json.tool`, and restart Docker.

## Diagnostics and troubleshooting

```bash
sudo ./laravel-server-manager.sh ai-status
sudo ./laravel-server-manager.sh ai-hardware
sudo ./laravel-server-manager.sh ai-gpu-info
sudo ./laravel-server-manager.sh ai-diagnostics
cd /opt/vllm-ai-platform
docker compose ps
docker compose logs --tail 200 gateway web controller
docker ps --filter label=com.vllm-ai-platform.managed=true
```

Common failures:

- `nvidia-smi` missing: install a supported host driver before the container toolkit.
- Docker GPU test fails: use the toolkit repair and inspect the daemon backup/configuration.
- Model is `INCOMPATIBLE`: reduce context/sequences, choose quantization, use supported CPU offload, stop another model, or assign more VRAM.
- Gated download fails: update `secrets/hf_token` through install/repair and accept the model license on Hugging Face.
- Disk reserve blocks download: free storage or change `AI_DISK_RESERVE_GB` deliberately.
- Model container exits: view `model:<container-name>` in the log menu; relevant CUDA/OOM/error lines are summarized on the model record.
- API 403: check owner/key model scopes and every configured CIDR layer.
- API 429: inspect per-key and owner quotas/concurrency.
- HTTPS issuance fails: confirm DNS and inbound 80/443, then rerun repair.

Diagnostics intentionally omit HF tokens, complete API keys, database/Redis passwords and application secrets.

## Security model

- HTTPS through the existing validated Nginx/Certbot stack.
- No public vLLM, PostgreSQL, Redis or controller ports.
- Dedicated internal Docker network.
- Gateway authentication and authorization before routing.
- Password and API-secret hashing; complete API keys shown once.
- Layered IPv4/IPv6 allowlists.
- Per-user, service-account and key model/scope policy.
- Redis-backed rate, request, token and concurrency enforcement.
- Input/output token and body-size validation.
- Server-side RBAC, CSRF, login throttling and secure cookies.
- CSP, HSTS, frame denial, MIME and referrer protections.
- XSS-safe Markdown.
- ORM parameterization.
- Restricted CORS; no wildcard default.
- Trusted proxy validation plus a shared proxy secret.
- Prompt logging off by default.
- Request IDs and sanitized external errors.
- Bounded container logs and restart attempts.
- Explicit confirmation for destructive weight removal, restore, MAXIMUM mode and uninstall.

API keys protect client access; they do not make arbitrary code in an untrusted container safe. Treat root, the Docker socket, administrator accounts, model `trust_remote_code`, host backups and the AI `.env` as high-trust assets.

## Validation and tests

From the repository:

```bash
bash -n laravel-server-manager.sh
python -m venv .venv
. .venv/bin/activate
pip install -r ai-platform/requirements-dev.txt
cd ai-platform
pytest -q
docker compose --env-file .env -f compose.yaml config
```

Unit/integration tests use SQLite, fake Redis, fake Docker/GPU clients and mock HTTP upstreams, so they do not claim a real GPU success. Hardware comparison tests cover no GPU, AMD detection state, multi-GPU capacity, additions/removals, model/VRAM/driver changes, and CPU/RAM changes. Run the actual container GPU diagnostic and a real model readiness test on the deployment VPS.
