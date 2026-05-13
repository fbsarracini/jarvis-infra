# Jarvis Infrastructure

Home server K3s cluster para desenvolvimento e experimentação com LLMs/RAG.

## Hardware
- Acer Nitro 5
- NVIDIA GeForce GTX 1060 (6GB VRAM — comporta modelos até ~7B em Q4, ex: mistral:7b-q4 ~4GB)
- Ubuntu Server 24.04 LTS

## Stack
- K3s (Kubernetes)
- Docker + NVIDIA Container Runtime
- Helm 3

## Estrutura
```
kubernetes/
├── namespaces/     # Definições de namespaces
├── system/         # (TODO) Infraestrutura (ingress, monitoring)
├── llm/            # (TODO) Ollama, vector DBs, RAG stack
└── apps/           # (TODO) Aplicações auxiliares
```

## Pré-requisitos

- Ubuntu Server 24.04 LTS instalado
- Drivers NVIDIA instalados e funcionando (`nvidia-smi` deve retornar sem erro)
- Acesso sudo

## Instalação Inicial

```bash
# Tornar os scripts executáveis
chmod +x scripts/*.sh

# 1. Instalar dependências do sistema (Docker, K3s, Helm, k9s)
./scripts/install-dependencies.sh

# Relogin necessário após instalação do Docker (grupo docker)
# ou execute: newgrp docker

# 2. Setup do cluster (namespaces, NVIDIA runtime, device plugin, metrics-server)
./scripts/setup-cluster.sh

# 3. Validar instalação
./scripts/validate-cluster.sh

# 4. Verificar manualmente
kubectl get nodes
kubectl top nodes
```

## Namespaces

- `system` - Infraestrutura core
- `llm` - Stack LLM/RAG
- `monitoring` - Prometheus, Grafana
- `apps` - Aplicações gerais
