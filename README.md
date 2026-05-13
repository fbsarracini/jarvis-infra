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
├── validate-cluster.sh       # Validates the cluster setup
├── versions.env.sample       # Template for versions.env (copy before running scripts)
└── versions.env              # Local overrides (gitignored)
```

## Prerequisites

- Ubuntu Server 24.04 LTS
- NVIDIA drivers installed and working (`nvidia-smi` must return without errors)
- `sudo` access

## Setup

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Copy the versions file (gitignored — edit if you want different versions)
cp scripts/versions.env.sample scripts/versions.env

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
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 \
  --namespace ingress-nginx \
  --create-namespace \
  --values kubernetes/system/ingress-nginx/values.yaml
```

Verify:

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

### Testing

```bash
# Deploy hello-world test resources
kubectl apply -f kubernetes/system/ingress-nginx/test-ingress.yaml

# Add hostname (replace 127.0.0.1 with your node IP from: kubectl get nodes -o wide)
echo "127.0.0.1 test.jarvis.local" | sudo tee -a /etc/hosts

# Test
curl http://test.jarvis.local:30080

# Clean up
kubectl delete -f kubernetes/system/ingress-nginx/test-ingress.yaml
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
# Overall status
kubectl get all -n ingress-nginx

# Stream logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

# List all Ingress resources across the cluster
kubectl get ingress -A

# Upgrade after changing values.yaml
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 \
  --namespace ingress-nginx \
  --values kubernetes/system/ingress-nginx/values.yaml
```
