#!/bin/bash
set -e

# Ensures relative paths work regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/versions.env"

echo "=== Jarvis K3s Cluster Setup ==="
echo "Configuring K3s cluster with GPU support"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo "Checking prerequisites..."

if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${RED}Error: nvidia-smi not found. Install NVIDIA drivers before continuing.${NC}"
    exit 1
fi

if ! nvidia-smi &>/dev/null; then
    echo -e "${RED}Error: nvidia-smi failed. NVIDIA driver may not be loaded correctly.${NC}"
    echo "Try: sudo modprobe nvidia && sudo nvidia-smi"
    exit 1
fi

if [ ! -e /dev/nvidia0 ]; then
    echo -e "${RED}Error: /dev/nvidia0 not found. NVIDIA driver may not be initialized.${NC}"
    echo "Try: sudo modprobe nvidia && sudo nvidia-smi"
    exit 1
fi

if ! command_exists kubectl; then
    echo -e "${RED}Error: kubectl not found. K3s is not installed${NC}"
    exit 1
fi

if ! command_exists helm; then
    echo -e "${RED}Error: helm not found. Install with: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
    exit 1
fi

if ! command_exists jq; then
    echo -e "${RED}Error: jq not found. Install with: sudo apt-get install -y jq${NC}"
    exit 1
fi

echo -e "${GREEN}Prerequisites OK${NC}"
echo ""

echo "Checking cluster..."
if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Error: K3s cluster is not responding${NC}"
    echo "Check: sudo systemctl status k3s"
    exit 1
fi

echo -e "${GREEN}K3s cluster online${NC}"
echo ""

# create namespaces
echo "Creating namespaces..."
kubectl apply -f "$REPO_ROOT/kubernetes/namespaces/namespaces.yaml"
echo ""

# configure NVIDIA Container Toolkit for K3s (containerd)
# without this the device plugin cannot expose the GPU to pods
echo "Configuring NVIDIA Container Toolkit for K3s..."
if ! command -v nvidia-ctk &>/dev/null; then
    echo -e "${YELLOW}Warning: nvidia-container-toolkit not found. Installing...${NC}"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update -q
    sudo apt-get install -y "nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
fi

K3S_CONTAINERD_TMPL="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
K3S_CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"

# Uses {{ template "base" . }} to extend the default K3s config without overwriting it.
# This ensures K3s upgrades don't break the config and nvidia is always present.
if sudo test -f "$K3S_CONTAINERD_TMPL" && sudo grep -q "nvidia" "$K3S_CONTAINERD_TMPL" 2>/dev/null; then
    echo -e "${YELLOW}Warning: NVIDIA runtime already configured in K3s containerd${NC}"
else
    # nvidia-ctk automatically detects the correct binary path
    NVIDIA_BINARY=""
    if command -v nvidia-ctk &>/dev/null; then
        TEMP_CONFIG=$(mktemp)
        sudo nvidia-ctk runtime configure --runtime=containerd --config="$TEMP_CONFIG" --set-as-default=false 2>/dev/null || true
        NVIDIA_BINARY=$(grep -oP 'BinaryName = "\K[^"]+' "$TEMP_CONFIG" 2>/dev/null | head -1)
        rm -f "$TEMP_CONFIG"
    fi
    if [ -z "$NVIDIA_BINARY" ]; then
        NVIDIA_BINARY=$(command -v nvidia-container-runtime 2>/dev/null || echo "/usr/bin/nvidia-container-runtime")
    fi
    if [ ! -x "$NVIDIA_BINARY" ]; then
        echo -e "${RED}Error: nvidia-container-runtime not found at '$NVIDIA_BINARY'.${NC}"
        echo "Check: which nvidia-container-runtime"
        exit 1
    fi
    echo "Using runtime: $NVIDIA_BINARY"

    sudo mkdir -p "$(dirname "$K3S_CONTAINERD_TMPL")"
    sed "s|\${NVIDIA_BINARY}|$NVIDIA_BINARY|g" "$REPO_ROOT/configs/containerd/config.toml.tmpl" | sudo tee "$K3S_CONTAINERD_TMPL" > /dev/null
    echo -e "${GREEN}NVIDIA runtime configured in containerd${NC}"
    echo "Restarting K3s to apply configuration..."
    sudo systemctl restart k3s
    echo "Waiting for K3s to come back..."
    kubectl wait --for=condition=Ready node --all --timeout=90s

    # Checks if the template was rendered correctly in config.toml
    if ! sudo grep -q "nvidia" "$K3S_CONTAINERD_CONFIG" 2>/dev/null; then
        echo -e "${RED}Error: nvidia runtime missing from generated config.toml. Template not applied.${NC}"
        echo "Template:"
        sudo cat "$K3S_CONTAINERD_TMPL"
        echo ""
        echo "Generated config.toml:"
        sudo cat "$K3S_CONTAINERD_CONFIG" 2>/dev/null || echo "(file not found)"
        exit 1
    fi
fi
echo ""

echo "Preparing NVIDIA libs for the device plugin..."
sudo mkdir -p /usr/local/nvidia/lib64
NVIDIA_LIB_SRC=$(find /usr/lib /usr/lib64 -name "libnvidia-ml.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "$NVIDIA_LIB_SRC" ]; then
    echo -e "${RED}Error: NVIDIA libs not found in /usr/lib or /usr/lib64${NC}"
    exit 1
fi
sudo cp -P "$NVIDIA_LIB_SRC"/libnvidia*.so* /usr/local/nvidia/lib64/
echo -e "${GREEN}NVIDIA libs copied from $NVIDIA_LIB_SRC to /usr/local/nvidia/lib64${NC}"
echo ""

echo "Creating nvidia RuntimeClass..."
kubectl apply -f "$REPO_ROOT/kubernetes/system/runtimeclass-nvidia.yaml"
echo -e "${GREEN}nvidia RuntimeClass created${NC}"
echo ""

echo "Installing NVIDIA Device Plugin..."
if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null; then
    echo -e "${YELLOW}Warning: NVIDIA Device Plugin already installed${NC}"
else
    # Version: https://github.com/NVIDIA/k8s-device-plugin/releases
    kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
    echo -e "${GREEN}NVIDIA Device Plugin installed${NC}"
fi

# The device plugin detects GPUs via NVML on the host — no need for runtimeClassName nvidia.
# Removes runtimeClassName if it was applied in previous runs.
CURRENT_RUNTIME=$(kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system \
    -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || echo "")
if [ -n "$CURRENT_RUNTIME" ]; then
    echo "Removing runtimeClassName from device plugin..."
    kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/runtimeClassName"}]' 2>/dev/null || true
    echo -e "${GREEN}runtimeClassName removed${NC}"
fi

echo "Configuring NVIDIA libs and device access in the device plugin..."
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='strategic' \
    --patch-file="$REPO_ROOT/kubernetes/system/nvidia-device-plugin-patch.yaml"
echo -e "${GREEN}Device plugin configured with privileged access and NVIDIA libs${NC}"

echo "Restarting device plugin to apply configuration..."
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n kube-system
echo ""

echo "Checking GPU detection (waiting for device plugin to restart)..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=180s

# Waits for kubelet to receive GPU registration from device plugin (may take up to 120s)
GPU_COUNT="0"
for i in $(seq 1 12); do
    GPU_COUNT=$(kubectl get nodes -o json | jq -r '.items[0].status.capacity["nvidia.com/gpu"] // "0"' 2>/dev/null || echo "0")
    if [ "$GPU_COUNT" != "0" ] && [ "$GPU_COUNT" != "null" ] && [ -n "$GPU_COUNT" ]; then
        break
    fi
    echo "   Waiting for kubelet to register GPU... ($i/12)"
    sleep 10
done

if [ "$GPU_COUNT" != "0" ] && [ "$GPU_COUNT" != "null" ] && [ -n "$GPU_COUNT" ]; then
    echo -e "${GREEN}GPU detected: $GPU_COUNT device(s)${NC}"
else
    echo -e "${YELLOW}Warning: GPU not detected in cluster. Check:${NC}"
    echo "   - nvidia-smi (must work on the host)"
    echo "   - kubectl logs -n kube-system -l name=nvidia-device-plugin-ds"
    echo "   - sudo grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
fi
echo ""

# Add Helm repos
echo "Configuring Helm repositories..."
helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
echo -e "${GREEN}Helm repos configured${NC}"
echo ""

echo "Installing metrics-server..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo -e "${YELLOW}Warning: metrics-server already installed${NC}"
else
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

    kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system

    # Patch to accept insecure certificates (local environment)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

    echo -e "${GREEN}metrics-server installed${NC}"
fi
echo ""

echo "Waiting for metrics-server to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system 2>/dev/null || true
echo ""

echo "Installing ingress-nginx..."
if helm list -n ingress-nginx | grep -q ingress-nginx; then
    echo -e "${YELLOW}Warning: ingress-nginx already installed${NC}"
else
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --version "${INGRESS_NGINX_CHART_VERSION}" \
      --namespace ingress-nginx \
      --create-namespace \
      --values "$REPO_ROOT/kubernetes/system/ingress-nginx/values.yaml"
    echo -e "${GREEN}ingress-nginx installed${NC}"
fi
echo ""

# Final summary
echo "======================================"
echo -e "${GREEN}Cluster setup complete!${NC}"
echo "======================================"
echo ""
echo "Cluster Information:"
echo ""
kubectl get nodes -o wide
echo ""
echo "Resources:"
kubectl top nodes 2>/dev/null || echo "Wait a few seconds and run: kubectl top nodes"
echo ""
echo "GPU Status:"
kubectl get nodes -o json | jq -r '.items[0].status.capacity | {"CPU": .cpu, "Memory": .memory, "GPU": .["nvidia.com/gpu"]}'
echo ""
echo "Namespaces:"
kubectl get namespaces
echo ""
echo "======================================"
echo "Next steps:"
echo "  1. Deploy infrastructure: kubectl apply -f kubernetes/system/"
echo "  2. Deploy applications: kubectl apply -f kubernetes/apps/"
echo "  3. Monitor with k9s or: kubectl get pods -A"
echo "======================================"
