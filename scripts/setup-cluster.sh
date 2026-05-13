#!/bin/bash
set -e

# Garante que caminhos relativos funcionem independente de onde o script é chamado
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/versions.env"

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
    echo -e "${RED}Erro: nvidia-smi nao encontrado. Instale os drivers NVIDIA antes de continuar.${NC}"
    exit 1
fi

if ! nvidia-smi &>/dev/null; then
    echo -e "${RED}Erro: nvidia-smi falhou. Driver NVIDIA pode nao estar carregado corretamente.${NC}"
    echo "Tente: sudo modprobe nvidia && sudo nvidia-smi"
    exit 1
fi

if [ ! -e /dev/nvidia0 ]; then
    echo -e "${RED}Erro: /dev/nvidia0 nao encontrado. Driver NVIDIA pode nao estar inicializado.${NC}"
    echo "Tente: sudo modprobe nvidia && sudo nvidia-smi"
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

if ! command_exists jq; then
    echo -e "${RED}Erro: jq nao encontrado. Instale com: sudo apt-get install -y jq${NC}"
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
    sudo apt-get update -q
    sudo apt-get install -y "nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
fi

K3S_CONTAINERD_TMPL="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
K3S_CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"

# Usa {{ template "base" . }} para estender o config padrão do K3s sem sobrescrevê-lo.
# Isso garante que upgrades do K3s não quebrem o config e o nvidia fica sempre presente.
if sudo test -f "$K3S_CONTAINERD_TMPL" && sudo grep -q "nvidia" "$K3S_CONTAINERD_TMPL" 2>/dev/null; then
    echo -e "${YELLOW}Aviso: NVIDIA runtime ja configurado no containerd do K3s${NC}"
else
    # nvidia-ctk detecta o caminho correto do binário automaticamente
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
        echo -e "${RED}Erro: nvidia-container-runtime nao encontrado em '$NVIDIA_BINARY'.${NC}"
        echo "Verifique: which nvidia-container-runtime"
        exit 1
    fi
    echo "Usando runtime: $NVIDIA_BINARY"

    sudo mkdir -p "$(dirname "$K3S_CONTAINERD_TMPL")"
    sed "s|\${NVIDIA_BINARY}|$NVIDIA_BINARY|g" "$REPO_ROOT/configs/containerd/config.toml.tmpl" | sudo tee "$K3S_CONTAINERD_TMPL" > /dev/null
    echo -e "${GREEN}NVIDIA runtime configurado no containerd${NC}"
    echo "Reiniciando K3s para aplicar configuracao..."
    sudo systemctl restart k3s
    echo "Aguardando K3s voltar..."
    kubectl wait --for=condition=Ready node --all --timeout=90s

    # Verifica se o template foi renderizado corretamente no config.toml
    if ! sudo grep -q "nvidia" "$K3S_CONTAINERD_CONFIG" 2>/dev/null; then
        echo -e "${RED}Erro: Runtime nvidia ausente no config.toml gerado. Template nao aplicado.${NC}"
        echo "Template:"
        sudo cat "$K3S_CONTAINERD_TMPL"
        echo ""
        echo "config.toml gerado:"
        sudo cat "$K3S_CONTAINERD_CONFIG" 2>/dev/null || echo "(arquivo nao encontrado)"
        exit 1
    fi
fi
echo ""

echo "Preparando libs NVIDIA para o device plugin..."
sudo mkdir -p /usr/local/nvidia/lib64
NVIDIA_LIB_SRC=$(find /usr/lib /usr/lib64 -name "libnvidia-ml.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "$NVIDIA_LIB_SRC" ]; then
    echo -e "${RED}Erro: libs NVIDIA nao encontradas em /usr/lib ou /usr/lib64${NC}"
    exit 1
fi
sudo cp -P "$NVIDIA_LIB_SRC"/libnvidia*.so* /usr/local/nvidia/lib64/
echo -e "${GREEN}Libs NVIDIA copiadas de $NVIDIA_LIB_SRC para /usr/local/nvidia/lib64${NC}"
echo ""

echo "Criando RuntimeClass nvidia..."
kubectl apply -f "$REPO_ROOT/kubernetes/system/runtimeclass-nvidia.yaml"
echo -e "${GREEN}RuntimeClass nvidia criado${NC}"
echo ""

echo "Instalando NVIDIA Device Plugin..."
if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null; then
    echo -e "${YELLOW}Aviso: NVIDIA Device Plugin ja instalado${NC}"
else
    # Versão: https://github.com/NVIDIA/k8s-device-plugin/releases
    kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
    echo -e "${GREEN}NVIDIA Device Plugin instalado${NC}"
fi

# O device plugin detecta GPUs via NVML no host — não precisa de runtimeClassName nvidia.
# Remove o runtimeClassName caso tenha sido aplicado em runs anteriores.
CURRENT_RUNTIME=$(kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system \
    -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || echo "")
if [ -n "$CURRENT_RUNTIME" ]; then
    echo "Removendo runtimeClassName do device plugin..."
    kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/runtimeClassName"}]' 2>/dev/null || true
    echo -e "${GREEN}runtimeClassName removido${NC}"
fi

echo "Configurando acesso as libs NVIDIA e devices no device plugin..."
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='strategic' \
    --patch-file="$REPO_ROOT/kubernetes/system/nvidia-device-plugin-patch.yaml"
echo -e "${GREEN}Device plugin configurado com acesso privilegiado e libs NVIDIA${NC}"

echo "Reiniciando device plugin para aplicar configuracao..."
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n kube-system
echo ""

echo "Verificando deteccao de GPU (aguardando device plugin reiniciar)..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=180s

# Aguarda o kubelet receber o registro da GPU do device plugin (pode demorar até 120s)
GPU_COUNT="0"
for i in $(seq 1 12); do
    GPU_COUNT=$(kubectl get nodes -o json | jq -r '.items[0].status.capacity["nvidia.com/gpu"] // "0"' 2>/dev/null || echo "0")
    if [ "$GPU_COUNT" != "0" ] && [ "$GPU_COUNT" != "null" ] && [ -n "$GPU_COUNT" ]; then
        break
    fi
    echo "   Aguardando kubelet registrar GPU... ($i/12)"
    sleep 10
done

if [ "$GPU_COUNT" != "0" ] && [ "$GPU_COUNT" != "null" ] && [ -n "$GPU_COUNT" ]; then
    echo -e "${GREEN}GPU detectada: $GPU_COUNT device(s)${NC}"
else
    echo -e "${YELLOW}Aviso: GPU nao detectada no cluster. Verifique:${NC}"
    echo "   - nvidia-smi (deve funcionar no host)"
    echo "   - kubectl logs -n kube-system -l name=nvidia-device-plugin-ds"
    echo "   - sudo grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
fi
echo ""

# Adicionar Helm repos
echo "Configurando Helm repositories..."
helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
echo -e "${GREEN}Helm repos configurados${NC}"
echo ""

echo "Instalando metrics-server..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo -e "${YELLOW}Aviso: metrics-server ja instalado${NC}"
else
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

    kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system

    # Patch para aceitar certificados inseguros (ambiente local)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

    echo -e "${GREEN}metrics-server instalado${NC}"
fi
echo ""

echo "Aguardando metrics-server ficar ready..."
kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system 2>/dev/null || true
echo ""

echo "Instalando ingress-nginx..."
if helm list -n ingress-nginx | grep -q ingress-nginx; then
    echo -e "${YELLOW}Aviso: ingress-nginx ja instalado${NC}"
else
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --version "${INGRESS_NGINX_CHART_VERSION}" \
      --namespace ingress-nginx \
      --create-namespace \
      --values "$REPO_ROOT/kubernetes/system/ingress-nginx/values.yaml"
    echo -e "${GREEN}ingress-nginx instalado${NC}"
fi
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
