# Jupyter and JupyterLab Integration

Jupyter is an optional development and diagnostic client of the existing AI Platform. It is not a vLLM dependency, production API, business control plane, model registry or Omnivis orchestrator.

```text
Omnivis VPS -- HTTPS/mTLS --> AI Gateway --> private vLLM --> GPU
                                  ^
                                  |
provider Jupyter / local Jupyter -+  diagnostics and development only
```

Stopping or restarting Jupyter does not stop or restart the Gateway or vLLM. Model lifecycle operations never restart Jupyter. The platform does not expose raw vLLM merely to support notebooks.

## Detection and preservation

The root manager runs `scripts/environment_probe.py` during hardware refresh, status and diagnostics. The probe is read-only and uses several signals rather than one provider variable:

- container marker files, cgroups, PID 1 and virtualization detection;
- allowlisted provider environment-variable **names** and sanitized image metadata;
- Vast.ai marker paths and hostname/container hints;
- Jupyter/JupyterLab executables, process identity and runtime-file existence;
- Python, CUDA, NVIDIA GPU and optional PyTorch information;
- local listening ports and Jupyter ports explicitly declared by its process;
- Docker CLI/daemon, systemd, root, `CAP_SYS_ADMIN`, firewall and LUKS prerequisites.

It classifies `FULL_VM`, `BARE_METAL`, `DOCKER_CONTAINER`, `VAST_AI_CONTAINER` or `OTHER_MARKETPLACE_CONTAINER`. An image such as `vastai/base-image-cuda-12.8.1-auto/jupyter`, a Vast provider marker or multiple matching container signals classifies existing Jupyter as `PROVIDER_MANAGED`.

The detector does not retain environment values, process command lines or Jupyter runtime-file contents. Those sources may contain tokens. Image references have URL credentials and query strings removed before storage.

For provider-managed Jupyter the policy is:

```text
DETECT -> PRESERVE -> INTEGRATE DIAGNOSTICS -> REUSE SAFELY
```

The manager does not reinstall Jupyter, overwrite configuration, change startup/authentication/TLS/proxy settings, restart its process, invent an external port or place it behind the AI reverse proxy. Vast.ai access continues through the provider UI or **Open** action.

## Python and runtime isolation

The Gateway and vLLM use either their Docker environments or two dedicated native virtual environments under `/opt/vllm-ai-platform/native`. No vLLM dependency is installed into the provider Jupyter Python environment. CUDA or PyTorch diagnostics never install or upgrade PyTorch.

If an administrator explicitly installs Jupyter on a trusted `FULL_VM` or `BARE_METAL` system, menu option 12 creates `/opt/vllm-ai-platform/jupyter-venv`. It does not create a public listener, systemd unit or reverse-proxy rule. Installation is refused when Jupyter already exists or the system is a container/marketplace worker.

Launch that optional environment manually as a non-root user, bound to loopback, and use an SSH tunnel or separately reviewed secure proxy:

```bash
/opt/vllm-ai-platform/jupyter-venv/bin/jupyter lab \
  --no-browser \
  --ip=127.0.0.1 \
  --notebook-dir=/opt/vllm-ai-platform/notebooks
```

Jupyter's own authentication must remain enabled. Never expose an unauthenticated listener to the Internet.

## Vast.ai and marketplace runtimes

The environment snapshot reports capabilities independently. It does not assume that a marketplace container has systemd, UFW/nftables administration, a Docker daemon, `CAP_SYS_ADMIN`, device mapper or LUKS. Missing capabilities are reported as unavailable and do not cause Jupyter detection to modify or fail the provider environment.

The manager prefers its existing Docker deployment when a usable Docker daemon and Compose are available. If they are absent but the provider exposes a compatible NVIDIA GPU and Python, the installer offers native mode. Native mode launches the secured Gateway and Model Manager independently of Jupyter, uses isolated virtual environments, and binds every new listener to loopback. It does not make Jupyter the production API or control plane.

Provider Jupyter continues on its original listener (commonly internal port `8080`). Native web uses `18080`, Gateway uses `8000`, controller uses `8090`, Redis uses `16379`, and managed vLLM processes use `19000-19999`; all native listeners are private by default. Notebooks can call `http://127.0.0.1:8000/v1` with a restricted AI Platform API key. They must not call the raw model ports.

The manager's optional Cloudflare Tunnel workflow publishes only native web `18080` and, when selected, Gateway `8000`. It does not add Jupyter `8080` to the tunnel, alter the provider Jupyter token/certificate, or publish controller, Redis, or raw vLLM listeners.

Host mutations such as NVIDIA Container Toolkit repair are refused from detected provider/marketplace containers. Provider CUDA and GPU configuration remain authoritative.

## Manager menu and diagnostics

Open `22) Manage vLLM / AI Platform`, then `20) Jupyter Integration`, or run:

```bash
sudo ./laravel-server-manager.sh ai-jupyter
```

The menu provides:

1. Jupyter status;
2. complete sanitized environment information;
3. read-only CUDA/GPU test;
4. PyTorch GPU test when PyTorch already exists;
5. authenticated Gateway and vLLM inference test;
6. vLLM API test notebook generation;
7. bounded GPU/Gateway benchmark notebook generation;
8. mock tool-calling notebook generation;
9. synthetic embeddings/RAG notebook generation;
10. provider access guidance;
11. security diagnostics;
12. explicit isolated installation on trusted normal hosts only.

Full diagnostics are also available through:

```bash
sudo ./laravel-server-manager.sh ai-diagnostics
cd /opt/vllm-ai-platform
docker compose exec -T controller python -m app.cli jupyter-diagnostics
```

In native mode, use:

```bash
sudo ./laravel-server-manager.sh ai-diagnostics
cd /opt/vllm-ai-platform
native/platform-venv/bin/python -m app.cli jupyter-diagnostics
```

The Admin Panel's **Jupyter integration** page reads the same sanitized snapshot and notebook inventory. It cannot start, stop, reinstall or reconfigure Jupyter.

## CUDA and PyTorch diagnostics

The CUDA test reads GPU name, total/used/free VRAM, utilization, temperature and power where `nvidia-smi` supports them. It changes no clock, voltage, power limit or driver setting.

The default environment probe only checks whether PyTorch is installed. The explicit PyTorch test imports the existing package and reports:

```python
torch.cuda.is_available()
torch.cuda.device_count()
torch.cuda.get_device_name(...)
```

Missing PyTorch is reported as `NOT AVAILABLE`; no package is installed to make a test pass.

## Generated notebooks

Generated notebooks live under:

```text
/opt/vllm-ai-platform/notebooks/
  diagnostics/vllm-api-<UTC timestamp>.ipynb
  benchmarks/gpu-benchmark-<UTC timestamp>.ipynb
  examples/tool-calling-<UTC timestamp>.ipynb
  examples/embeddings-rag-<UTC timestamp>.ipynb
```

Names are version-safe and existing files are never overwritten. When a running Jupyter user is discoverable, the generated file and its dedicated category directory are assigned to that user. Notebook storage is mounted read-only into the web panel only for inventory display.

All examples call the secured Gateway base `https://AI_DOMAIN/v1`. They never launch a model or maintain a second registry. The API notebook checks models, chat, streaming, latency and TTFT. The benchmark uses a short matrix operation only when adequate free VRAM is visible and limits Gateway requests to five, default one. It performs no thermal/power stress. The tool notebook uses mock `get_weather_test`, `calculator_test` and `echo_test` schemas and never executes a returned call automatically. The embeddings notebook uses synthetic sentences only.

## Credential handling

Generated notebooks contain no real credentials. Configure the base URL and optionally the diagnostic key at runtime:

```bash
export OMNIVIS_AI_BASE_URL="https://ai.example.com/v1"
export OMNIVIS_CODING_API_KEY="<restricted-diagnostic-key>"
export OMNIVIS_TEST_MODEL="omnivis-general"
```

If the key variable is absent, the notebook uses hidden `getpass` input and keeps the value only in kernel memory. Do not save executed notebook output containing private prompts or responses. Use a dedicated account with explicit model, endpoint, scope, CIDR, expiry and conservative quotas.

Never pass the following to a notebook:

- Jupyter provider token or password;
- Hugging Face token;
- encryption master/model keys or KMS credentials;
- mTLS or worker private keys;
- Omnivis production credentials or database connection strings.

The environment snapshot and diagnostics never print these values.

## Omnivis data separation

Jupyter on the AI server receives no automatic access to the Omnivis, CRM, WhatsApp, contacts or collaborators databases, customer data or complete private RAG repository. The example RAG workflow is synthetic. Any later development-data connection is a separate, explicitly authorized integration and must not reuse production credentials.

## GPU capacity safety

Notebooks query models through the authoritative Model Manager/Gateway. They do not start an uncontrolled second vLLM process or load another large model. Before the optional matrix diagnostic, the notebook checks free VRAM and skips if less than 512 MiB is visible. Use the existing Models page and activation plan for all model switching and GPU allocation.

## Troubleshooting without provider modification

- **Jupyter exists but is not detected:** run Environment Information and confirm the executable/process is visible to the manager namespace. Do not reinstall it as a workaround.
- **Provider access fails:** use the Vast.ai/provider UI and verify its port mapping/authentication. The platform deliberately does not infer external URLs or tokens.
- **CUDA visible, PyTorch GPU unavailable:** inspect the provider's existing Python/CUDA compatibility. Do not upgrade provider PyTorch automatically.
- **Gateway test returns 401/403:** use a dedicated active API key and verify its CIDR, endpoint, model, scopes and quotas.
- **No models listed:** activate an authorized model through the existing Model Manager.
- **Responses/tool tests fail:** verify the selected model, vLLM route and parser with coding diagnostics; support is never emulated.
- **Docker/systemd/LUKS unavailable:** this is expected on many marketplace containers. Use `ai-install-native` when the GPU/Python checks pass; host-only toolkit, firewall and encryption actions remain disabled and provider Jupyter remains unchanged.
- **Notebook not writable:** run status to detect the Jupyter process user, then generate a new notebook; do not recursively change ownership of provider directories.

Provider-side Jupyter UI access cannot be validated from the AI Platform itself and must be tested through the provider console after deployment.
