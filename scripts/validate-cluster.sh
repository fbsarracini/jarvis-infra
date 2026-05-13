#!/bin/bash

echo "=== Jarvis Cluster Validation ==="
echo ""

if ! command -v kubectl &>/dev/null; then
    echo "kubectl nao encontrado. Execute install-dependencies.sh primeiro."
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
        echo -e "${YELLOW} $1 (opcional)${NC}"
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
            echo -e "${YELLOW}   Diagnostico:${NC}"
            eval "$3" 2>&1 | sed 's/^/     /'
        fi
    fi
}

echo "Sistema Base:"
check "Docker instalado" "command -v docker"
check "K3s instalado" "command -v kubectl"
check "Helm instalado" "command -v helm"
check "jq instalado" "command -v jq"
check_optional "k9s instalado" "command -v k9s"
check "NVIDIA drivers" "nvidia-smi"
echo ""

echo "Cluster K3s:"
check "Cluster respondendo" "kubectl get nodes"
check "Node ready" "kubectl get nodes | grep -q Ready"
check "Metrics-server funcionando" "kubectl top nodes"
echo ""

echo "GPU no Cluster:"
check_gpu "NVIDIA runtime no containerd do K3s" \
    "sudo grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl" \
    "echo 'Execute: scripts/setup-cluster.sh para reconfigurar o runtime nvidia no containerd'"
check_gpu "NVIDIA Device Plugin instalado" \
    "kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset" \
    "echo 'Execute: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml'"
check_gpu "NVIDIA Device Plugin pods rodando" \
    "kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds --field-selector=status.phase=Running | grep -q Running" \
    "kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds; echo '---'; kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=20"
check_gpu "GPU detectada no node" \
    "kubectl get nodes -o json | jq -e '.items[0].status.capacity[\"nvidia.com/gpu\"]'" \
    "kubectl get nodes -o json | jq '.items[0].status.capacity'"
echo ""

echo "Namespaces:"
check "Namespace 'system' existe" "kubectl get ns system"
check "Namespace 'llm' existe" "kubectl get ns llm"
check "Namespace 'monitoring' existe" "kubectl get ns monitoring"
check "Namespace 'apps' existe" "kubectl get ns apps"
echo ""

echo "Helm Repositories:"
check "Repo 'bitnami' configurado" "helm repo list | grep -q bitnami"
check "Repo 'jetstack' configurado" "helm repo list | grep -q jetstack"
check "Repo 'prometheus-community' configurado" "helm repo list | grep -q prometheus-community"
echo ""

echo "======================================"
echo "Resumo:"
echo -e "${GREEN} Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED} Failed: $FAILED${NC}"
else
    echo -e "${GREEN} Todos os checks passaram!${NC}"
fi
echo "======================================"

exit $FAILED
