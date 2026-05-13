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
kubernetes/
├── namespaces/     # Definições de namespaces
├── system/         # Infraestrutura (ingress, monitoring)
├── llm/            # Ollama, vector DBs, RAG stack
└── apps/           # Aplicações auxiliares

## Instalação Inicial

```bash
# 1. Instalar dependências do sistema
./scripts/install-dependencies.sh

# 2. Setup do cluster
./scripts/setup-cluster.sh

# 3. Verificar
kubectl get nodes
helm version
```

## Namespaces

- `system` - Infraestrutura core
- `llm` - Stack LLM/RAG
- `monitoring` - Prometheus, Grafana
- `apps` - Aplicações gerais
