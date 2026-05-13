#!/bin/bash
set -e

# Garante que caminhos relativos funcionem independente de onde o script é chamado
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Jarvis K3s Cluster Setup ==="
echo "Configurando cluster K3s com suporte GPU"
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função para verificar se comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo "Verificando pre-requisitos..."

if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${RED}Erro: NVIDIA drivers nao instalados. Execute nvidia-smi para confirmar antes de continuar.${NC}"
    exit 1
fi

if ! command_exists kubectl; then
    echo -e "${RED}Erro: kubectl nao encontrado. K3s nao esta instalado${NC}"
    exit 1
fi

if ! command_exists helm; then
    echo -e "${RED}Erro: helm nao encontrado. Instale com: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
    exit 1
fi

echo -e "${GREEN}Pre-requisitos OK${NC}"
echo ""

echo "Verificando cluster..."
if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Erro: cluster K3s nao esta respondendo${NC}"
    echo "Verifique: sudo systemctl status k3s"
    exit 1
fi

echo -e "${GREEN}Cluster K3s online${NC}"
echo ""

# criar namespaces
echo "Criando namespaces..."
kubectl apply -f "$REPO_ROOT/kubernetes/namespaces/namespaces.yaml"
echo ""

# configurar NVIDIA Container Toolkit para K3s (containerd)
# sem isso o device plugin não consegue expor a GPU para os pods
echo "Configurando NVIDIA Container Toolkit para K3s..."
if ! command -v nvidia-ctk &>/dev/null; then
    echo -e "${YELLOW}Aviso: nvidia-container-toolkit nao encontrado. Instalando...${NC}"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt update
    sudo apt install -y nvidia-container-toolkit
fi

K3S_CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
if sudo grep -q "nvidia" "$K3S_CONTAINERD_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}Aviso: NVIDIA runtime ja configurado no containerd do K3s${NC}"
else
    sudo mkdir -p "$(dirname "$K3S_CONTAINERD_CONFIG")"
    sudo nvidia-ctk runtime configure --runtime=containerd --config="$K3S_CONTAINERD_CONFIG"
    echo -e "${GREEN}NVIDIA runtime configurado no containerd${NC}"
    echo "Reiniciando K3s para aplicar configuracao..."
    sudo systemctl restart k3s
    echo "Aguardando K3s voltar..."
    kubectl wait --for=condition=Ready node --all --timeout=90s
fi
echo ""

echo "Instalando NVIDIA Device Plugin..."
if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null; then
    echo -e "${YELLOW}Aviso: NVIDIA Device Plugin ja instalado${NC}"
else
    # Versão: https://github.com/NVIDIA/k8s-device-plugin/releases
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
    echo -e "${GREEN}NVIDIA Device Plugin instalado${NC}"
fi
echo ""

echo "Verificando detecção de GPU..."
kubectl wait --for=condition=available --timeout=30s daemonset/nvidia-device-plugin-daemonset -n kube-system 2>/dev/null || true
GPU_COUNT=$(kubectl get nodes -o json | jq -r '.items[0].status.capacity["nvidia.com/gpu"]' 2>/dev/null || echo "0")

if [ "$GPU_COUNT" != "null" ] && [ "$GPU_COUNT" != "0" ]; then
    echo -e "${GREEN}GPU detectada: $GPU_COUNT device(s)${NC}"
else
    echo -e "${YELLOW}Aviso: GPU nao detectada no cluster. Verifique:${NC}"
    echo "   - nvidia-smi (deve funcionar no host)"
    echo "   - kubectl logs -n kube-system -l name=nvidia-device-plugin-ds"
fi
echo ""

# Adicionar Helm repos
echo "Configurando Helm repositories..."
helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
echo -e "${GREEN}Helm repos configurados${NC}"
echo ""

echo "Instalando metrics-server..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo -e "${YELLOW}Aviso: metrics-server ja instalado${NC}"
else
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    # Patch para aceitar certificados inseguros (ambiente local)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

    echo -e "${GREEN}metrics-server instalado${NC}"
fi
echo ""

echo "Aguardando metrics-server ficar ready..."
kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system 2>/dev/null || true
echo ""

# Resumo final
echo "======================================"
echo -e "${GREEN}Setup do cluster concluido!${NC}"
echo "======================================"
echo ""
echo "Informacoes do Cluster:"
echo ""
kubectl get nodes -o wide
echo ""
echo "Recursos:"
kubectl top nodes 2>/dev/null || echo "Aguarde alguns segundos e execute: kubectl top nodes"
echo ""
echo "GPU Status:"
kubectl get nodes -o json | jq -r '.items[0].status.capacity | {"CPU": .cpu, "Memory": .memory, "GPU": .["nvidia.com/gpu"]}'
echo ""
echo "Namespaces:"
kubectl get namespaces
echo ""
echo "======================================"
echo "Proximos passos:"
echo "  1. Deploy infraestrutura: kubectl apply -f kubernetes/system/"
echo "  2. Deploy aplicacoes: kubectl apply -f kubernetes/apps/"
echo "  3. Monitorar com k9s ou: kubectl get pods -A"
echo "======================================"
