# Jarvis Infrastructure

> Prefere ler em português? [README em pt-BR disponível aqui.](README.pt-BR.md)

A ready-to-use K3s cluster setup for running LLMs on your homelab with NVIDIA GPU support. Get Ollama and a full RAG stack running on your own hardware in minutes.

## ⚠️ Scope & Limitations

This project is a **homelab setup template** — designed to help you spin up a local LLM cluster on your own hardware with minimal friction.
It is intentionally simple: plain shell scripts, single-node K3s, and public images.

It is **not** designed for:
- Production workloads or multi-tenant environments
- High availability or disaster recovery
- Security hardening (no Vault, no Network Policies, no image signing)
- Custom or private Docker registries

> **Security is out of scope.** Securing your homelab is your responsibility. The tips at the bottom of this file are a starting point — not a security baseline.

Contributions and suggestions are welcome — just keep the scope in mind.

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
- **Make** — task runner for all operations

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
├── validate-cluster.sh       # Validates the cluster setup
├── versions.env.sample       # Template for versions.env (copy before running scripts)
└── versions.env              # Local overrides (gitignored)

Makefile                      # Task runner — run `make help` to see all targets
```

## Prerequisites

- Ubuntu Server 24.04 LTS
- NVIDIA drivers installed and working (`nvidia-smi` must return without errors)
- `sudo` access
- `make` (`sudo apt install make`)

## Setup

```bash
# See all available commands
make help

# 1. Copy versions.env.sample → versions.env (edit if you want different versions)
make init

# 2. Install system dependencies (Docker, K3s, Helm, k9s)
make install

# Re-login required after Docker installation (docker group)
# or run: newgrp docker

# 3. Set up the cluster (namespaces, NVIDIA runtime, device plugin, metrics-server, ingress)
make setup

# 4. Validate the installation
make validate

# Or run all steps in sequence:
make all
```

### Useful day-to-day commands

```bash
make status          # Node status and resource usage
make pods            # All pods across all namespaces
make gpu-status      # GPU capacity on the cluster node
```

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| `system` | Core infrastructure |
| `llm` | LLM/RAG stack |
| `monitoring` | Prometheus, Grafana |
| `apps` | General applications |

## Contributing

Contributions and bug reports are welcome. Please keep the [scope](#️-scope--limitations) in mind.

### Reporting Issues

1. Check [existing issues](https://github.com/fabiosobottka/jarvis-infra/issues) to avoid duplicates.
2. Open a new issue and include:
   - **Description** — what you expected vs. what happened
   - **Steps to reproduce** — minimal commands or config to trigger the problem
   - **Environment** — GPU model, VRAM, OS version, K3s version (`k3s --version`)
   - **Logs** — relevant output from `make validate`, `kubectl describe`, or `journalctl -u k3s`

### Suggesting Changes

Open an issue before submitting a PR for non-trivial changes. This avoids wasted effort if the change is out of scope.

---

## Known Risks

Most component versions are pinned in `scripts/versions.env` to avoid unexpected breakage. Two external dependencies cannot be fully pinned:

| Risk | Description | Mitigation |
|------|-------------|------------|
| NVIDIA apt endpoints | GPG key and apt list URLs in `setup-cluster.sh` are controlled by NVIDIA — if they change, the toolkit installation breaks | Check [NVIDIA Container Toolkit docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) if the install step fails |

## Ingress (NGINX)

Routes external HTTP/HTTPS traffic to services inside the cluster based on hostname and path rules.

```
[Browser / curl]
      │
      │  HTTP :30080  /  HTTPS :30443
      ▼
[NGINX Ingress Controller]
      ├── host: app1.jarvis.local  →  Service app1:80
      ├── host: app2.jarvis.local  →  Service app2:80
      └── host: test.jarvis.local  →  Service hello-world:80
```

**Why NodePort instead of LoadBalancer?**
Without MetalLB or a cloud provider, `LoadBalancer` services stay in `<pending>` indefinitely. NodePort exposes fixed ports directly on the node (30080/30443) with no external dependencies. All requests must explicitly include the port (e.g. `curl http://app.jarvis.local:30080`).

### Installation

```bash
# Install (version controlled via scripts/versions.env)
make ingress-install

# Upgrade after changing values.yaml or bumping version in versions.env
make ingress-upgrade
```

### Verify

```bash
make ingress-status
```

### Testing

```bash
# Deploy hello-world test resources
make ingress-test-deploy

# Add hostname (replace <NODE_IP> with output of: kubectl get nodes -o wide)
echo "<NODE_IP> test.jarvis.local" | sudo tee -a /etc/hosts

# Test
curl http://test.jarvis.local:30080

# Clean up
make ingress-test-clean
```

### Creating Ingress Resources

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: apps           # must match the Service namespace
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx   # required
  rules:
    - host: my-app.jarvis.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

After applying, add the hostname to `/etc/hosts` and access it on port `:30080`.

### Troubleshooting

| Symptom | Likely cause | Check |
|---------|-------------|-------|
| Controller pod not running | Port conflict or insufficient resources | `kubectl describe pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx` |
| `curl` returns 404 | No Ingress rule matches the request | `kubectl describe ingress <name> -n <namespace>` |
| `curl` connection refused | Wrong port or `/etc/hosts` entry missing | `kubectl get svc -n ingress-nginx ingress-nginx-controller` |

### Useful Commands

```bash
make ingress-status   # Pods, services, and all Ingress resources
make ingress-logs     # Stream controller logs
make ingress-upgrade  # Upgrade after changing values.yaml or version
```

## Security Tips

> These tips are a starting point to reduce obvious exposure — not a security baseline. Securing a homelab is your responsibility.

A few low-effort steps that make a meaningful difference:

- **Firewall (UFW):** SSH (22), K3s API (6443), and Kubelet (10250) listen on all interfaces by default. Restrict them to your local subnet. See [UFW documentation](https://help.ubuntu.com/community/UFW).
- **SSH keys only:** Disable password-based SSH login and use key authentication. Make sure your public key is in `~/.ssh/authorized_keys` before disabling passwords — editing `sshd_config` manually is safer than running `sed` on it blindly, as syntax varies between distros and OpenSSH versions.
- **OS updates:** Enable `unattended-upgrades` for security patches. Bump K3s version in `scripts/versions.env` and re-run `make install` periodically.
- **Kubeconfig:** Run `chmod 600 ~/.kube/config`. Never commit or share it — it grants full cluster admin access.
