#!/bin/bash
set -e

echo "=== Jarvis Dependencies Installer ==="
echo "This script installs Docker, K3s and essential tools"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Docker
if ! command_exists docker; then
    echo "Installing Docker..."

    # Remove old versions (ignore if they don't exist)
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker repository
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add your user to the docker group
    sudo usermod -aG docker $USER
    echo "Warning: log out and log back in to activate the docker group (newgrp does not work in scripts)"
else
    echo "Docker already installed"
fi

# K3s
if ! command_exists kubectl; then
    echo "Installing K3s..."

    # Install K3s single-node with GPU support via containerd (NVIDIA Container Toolkit)
    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik

    # Configure kubectl
    mkdir -p ~/.kube
    echo "Waiting for k3s.yaml to be generated..."
    until sudo test -f /etc/rancher/k3s/k3s.yaml; do sleep 2; done
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    export KUBECONFIG=~/.kube/config
    echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

    # Wait for K3s to be ready before checking
    echo "Waiting for K3s to initialize..."
    kubectl wait --for=condition=Ready node --all --timeout=60s
    kubectl get nodes
else
    echo "K3s already installed"
fi

# Helm
if ! command_exists helm; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm already installed"
fi

# jq (used in setup and validation scripts)
if ! command_exists jq; then
    echo "Installing jq..."
    sudo apt install -y jq
else
    echo "jq already installed"
fi

# k9s
if ! command_exists k9s; then
    echo "Installing k9s..."
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" | sudo tar xz -C /usr/local/bin k9s
else
    echo "k9s already installed"
fi

echo ""
echo "Installation complete!"
echo "Run: source ~/.bashrc"
