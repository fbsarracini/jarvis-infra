# Jarvis Infrastructure

K3s cluster running on a home server for LLM/RAG development and experimentation.

## Hardware Compatibility

Tested with an **NVIDIA GeForce GTX 1060 (6GB VRAM)**, but compatible with any NVIDIA GPU supported by the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html).

| VRAM | Capability |
|------|------------|
| 4GB  | Small models (~3B Q4) |
| 6GB  | Up to ~7B Q4 (e.g. `mistral:7b-q4` ~4GB) |
| 8GB  | Up to ~13B Q4 |
| 16GB+ | 30B+ models |

**OS:** Ubuntu Server 22.04 / 24.04 LTS (or any Debian-based distro with NVIDIA driver support)

## Stack

- **K3s** — lightweight Kubernetes
- **Docker** + NVIDIA Container Runtime
- **Helm 3**

## Repository Structure

```
kubernetes/
├── namespaces/   # Namespace definitions
├── system/       # Core infrastructure (ingress, monitoring)
├── llm/          # Ollama, vector DBs, RAG stack
└── apps/         # Auxiliary applications

scripts/
├── install-dependencies.sh   # Installs Docker, K3s, Helm, k9s
├── setup-cluster.sh          # Configures namespaces, NVIDIA runtime, device plugin
└── validate-cluster.sh       # Validates the cluster setup
```

## Prerequisites

- Ubuntu Server 24.04 LTS
- NVIDIA drivers installed and working (`nvidia-smi` must return without errors)
- `sudo` access

## Setup

```bash
# Make scripts executable
chmod +x scripts/*.sh

# 1. Install system dependencies (Docker, K3s, Helm, k9s)
./scripts/install-dependencies.sh

# Re-login required after Docker installation (docker group)
# or run: newgrp docker

# 2. Set up the cluster (namespaces, NVIDIA runtime, device plugin, metrics-server)
./scripts/setup-cluster.sh

# 3. Validate the installation
./scripts/validate-cluster.sh

# 4. Quick sanity check
kubectl get nodes
kubectl top nodes
```

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| `system` | Core infrastructure |
| `llm` | LLM/RAG stack |
| `monitoring` | Prometheus, Grafana |
| `apps` | General applications |
