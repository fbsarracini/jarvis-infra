#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/versions.env"

echo "=== Jarvis Cluster Validation ==="
echo ""

if ! command -v kubectl &>/dev/null; then
    echo "kubectl not found. Run install-dependencies.sh first."
    exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# checks
PASSED=0
FAILED=0

check() {
    if eval "$2" &>/dev/null; then
        echo -e "${GREEN} $1${NC}"
        ((PASSED++))
    else
        echo -e "${RED} $1${NC}"
        ((FAILED++))
    fi
}

check_optional() {
    if eval "$2" &>/dev/null; then
        echo -e "${GREEN} $1${NC}"
    else
        echo -e "${YELLOW} $1 (optional)${NC}"
    fi
}

check_gpu() {
    if eval "$2" &>/dev/null; then
        echo -e "${GREEN} $1${NC}"
        ((PASSED++))
    else
        echo -e "${RED} $1${NC}"
        ((FAILED++))
        if [ -n "$3" ]; then
            echo -e "${YELLOW}   Diagnostics:${NC}"
            eval "$3" 2>&1 | sed 's/^/     /'
        fi
    fi
}

echo "Base System:"
check "Docker installed" "command -v docker"
check "K3s installed" "command -v kubectl"
check "Helm installed" "command -v helm"
check "jq installed" "command -v jq"
check_optional "k9s installed" "command -v k9s"
check "NVIDIA drivers" "nvidia-smi"
echo ""

echo "K3s Cluster:"
check "Cluster responding" "kubectl get nodes"
check "Node ready" "kubectl get nodes | grep -q Ready"
check "Metrics-server running" "kubectl top nodes"
echo ""

echo "GPU on Cluster:"
check_gpu "NVIDIA runtime in K3s containerd" \
    "sudo grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl" \
    "echo 'Run: scripts/setup-cluster.sh to reconfigure the nvidia runtime in containerd'"
check_gpu "NVIDIA Device Plugin installed" \
    "kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset" \
    "echo 'Run: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml'"
check_gpu "NVIDIA Device Plugin pods running" \
    "kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds --field-selector=status.phase=Running | grep -q Running" \
    "kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds; echo '---'; kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=20"
check_gpu "GPU detected on node" \
    "kubectl get nodes -o json | jq -e '.items[0].status.capacity[\"nvidia.com/gpu\"]'" \
    "kubectl get nodes -o json | jq '.items[0].status.capacity'"
echo ""

echo "Namespaces:"
check "Namespace 'system' exists" "kubectl get ns system"
check "Namespace 'llm' exists" "kubectl get ns llm"
check "Namespace 'monitoring' exists" "kubectl get ns monitoring"
check "Namespace 'apps' exists" "kubectl get ns apps"
echo ""

echo "Helm Repositories:"
check "Repo 'bitnami' configured" "helm repo list | grep -q bitnami"
check "Repo 'jetstack' configured" "helm repo list | grep -q jetstack"
check "Repo 'prometheus-community' configured" "helm repo list | grep -q prometheus-community"
echo ""

echo "======================================"
echo "Summary:"
echo -e "${GREEN} Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED} Failed: $FAILED${NC}"
else
    echo -e "${GREEN} All checks passed!${NC}"
fi
echo "======================================"

exit $FAILED
