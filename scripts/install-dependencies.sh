#!/bin/bash
set -e

echo "=== Jarvis Dependencies Installer ==="
echo "Este script instala Docker, K3s e ferramentas essenciais"
echo ""

# Função para verificar se comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Docker
if ! command_exists docker; then
    echo "Instalando Docker..."

    # Remover versões antigas (ignora se não existirem)
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Adicionar repositório Docker
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Instalar Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Adicionar seu usuário ao grupo docker
    sudo usermod -aG docker $USER
    echo "Atencao: faca logout e login novamente para ativar o grupo docker (newgrp nao funciona em scripts)"
else
    echo "Docker ja instalado"
fi

# K3s
if ! command_exists kubectl; then
    echo "Instalando K3s..."

    # Instalar K3s single-node com GPU support via containerd (NVIDIA Container Toolkit)
    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik

    # Configurar kubectl
    mkdir -p ~/.kube
    echo "Aguardando k3s.yaml ser gerado..."
    until sudo test -f /etc/rancher/k3s/k3s.yaml; do sleep 2; done
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    export KUBECONFIG=~/.kube/config
    echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

    # Aguardar K3s ficar ready antes de verificar
    echo "Aguardando K3s inicializar..."
    kubectl wait --for=condition=Ready node --all --timeout=60s
    kubectl get nodes
else
    echo "K3s ja instalado"
fi

# Helm
if ! command_exists helm; then
    echo "Instalando Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm ja instalado"
fi

# jq (usado nos scripts de setup e validação)
if ! command_exists jq; then
    echo "Instalando jq..."
    sudo apt install -y jq
else
    echo "jq ja instalado"
fi

# k9s
if ! command_exists k9s; then
    echo "Instalando k9s..."
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" | sudo tar xz -C /usr/local/bin k9s
else
    echo "k9s ja instalado"
fi

echo ""
echo "Instalacao completa!"
echo "Execute: source ~/.bashrc"
