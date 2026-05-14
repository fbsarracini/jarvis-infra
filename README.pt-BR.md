# Jarvis Infrastructure

Um setup de cluster K3s pronto para uso, para rodar LLMs no seu homelab com suporte a GPU NVIDIA. Suba o Ollama e uma stack completa de RAG no seu próprio hardware em minutos.

## ⚠️ Escopo e Limitações

Este projeto é um **template de setup para homelab** — criado para ajudar você a montar um cluster local de LLMs no seu próprio hardware com o mínimo de fricção.
É intencionalmente simples: shell scripts, K3s single-node e imagens públicas.

**Não** é projetado para:
- Workloads de produção ou ambientes multi-tenant
- Alta disponibilidade ou recuperação de desastres
- Hardening de segurança (sem Vault, sem Network Policies, sem assinatura de imagens)
- Registries Docker privados ou customizados

> **Segurança está fora do escopo.** Proteger o seu homelab é sua responsabilidade. As dicas no final deste arquivo são um ponto de partida — não uma baseline de segurança.

Contribuições e sugestões são bem-vindas — apenas tenha o escopo em mente.

## Compatibilidade de Hardware

Testado com **NVIDIA GeForce GTX 1060 (6GB VRAM)**, mas compatível com qualquer GPU NVIDIA suportada pelo [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html).

| VRAM | Capacidade |
|------|------------|
| 4GB  | Modelos pequenos (~3B Q4) |
| 6GB  | Até ~7B Q4 (ex: `mistral:7b-q4` ~4GB) |
| 8GB  | Até ~13B Q4 |
| 16GB+ | Modelos 30B+ |

**SO:** Ubuntu Server 22.04 / 24.04 LTS (ou qualquer distro baseada em Debian com suporte a driver NVIDIA)

## Stack

- **K3s** — Kubernetes leve
- **Docker** + NVIDIA Container Runtime
- **Helm 3**
- **Make** — task runner para todas as operações

## Estrutura do Repositório

```
kubernetes/
├── namespaces/   # Definições de namespaces
├── system/       # Infraestrutura core (ingress, monitoramento)
├── llm/          # Ollama, vector DBs, stack RAG
└── apps/         # Aplicações auxiliares

scripts/
├── install-dependencies.sh   # Instala Docker, K3s, Helm, k9s
├── setup-cluster.sh          # Configura namespaces, NVIDIA runtime, device plugin
├── validate-cluster.sh       # Valida o setup do cluster
├── versions.env.sample       # Template para versions.env (copie antes de rodar os scripts)
└── versions.env              # Overrides locais (gitignored)

Makefile                      # Task runner — rode `make help` para ver todos os targets
```

## Pré-requisitos

- Ubuntu Server 24.04 LTS
- Drivers NVIDIA instalados e funcionando (`nvidia-smi` deve retornar sem erros)
- Acesso `sudo`
- `make` (`sudo apt install make`)

## Setup

```bash
# Veja todos os comandos disponíveis
make help

# 1. Copie versions.env.sample → versions.env (edite se quiser versões diferentes)
make init

# 2. Instale as dependências do sistema (Docker, K3s, Helm, k9s)
make install

# Re-login necessário após a instalação do Docker (grupo docker)
# ou execute: newgrp docker

# 3. Configure o cluster (namespaces, NVIDIA runtime, device plugin, metrics-server, ingress)
make setup

# 4. Valide a instalação
make validate

# Ou rode todas as etapas em sequência:
make all
```

### Comandos úteis no dia a dia

```bash
make status          # Status do node e uso de recursos
make pods            # Todos os pods em todos os namespaces
make gpu-status      # Capacidade de GPU no node do cluster
```

## Namespaces

| Namespace | Finalidade |
|-----------|------------|
| `system` | Infraestrutura core |
| `llm` | Stack LLM/RAG |
| `monitoring` | Prometheus, Grafana |
| `apps` | Aplicações gerais |

## Contribuindo

Contribuições e bug reports são bem-vindos. Tenha o [escopo](#️-escopo-e-limitações) em mente.

### Reportando Problemas

1. Verifique as [issues existentes](https://github.com/fabiosobottka/jarvis-infra/issues) para evitar duplicatas.
2. Abra uma nova issue e inclua:
   - **Descrição** — o que você esperava vs. o que aconteceu
   - **Passos para reproduzir** — comandos ou config mínimos para acionar o problema
   - **Ambiente** — modelo de GPU, VRAM, versão do SO, versão do K3s (`k3s --version`)
   - **Logs** — saída relevante de `make validate`, `kubectl describe` ou `journalctl -u k3s`

### Sugerindo Mudanças

Abra uma issue antes de submeter um PR para mudanças não triviais. Isso evita esforço desperdiçado se a mudança estiver fora do escopo.

---

## Riscos Conhecidos

A maioria das versões dos componentes está fixada em `scripts/versions.env` para evitar quebras inesperadas. Duas dependências externas não podem ser totalmente fixadas:

| Risco | Descrição | Mitigação |
|-------|-----------|-----------|
| Endpoints apt da NVIDIA | A chave GPG e as URLs da lista apt em `setup-cluster.sh` são controladas pela NVIDIA — se mudarem, a instalação do toolkit quebra | Consulte a [documentação do NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) se a etapa de instalação falhar |

## Ingress (NGINX)

Roteia tráfego HTTP/HTTPS externo para serviços dentro do cluster com base em regras de hostname e path.

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

**Por que NodePort em vez de LoadBalancer?**
Sem MetalLB ou um cloud provider, serviços `LoadBalancer` ficam em `<pending>` indefinidamente. NodePort expõe portas fixas diretamente no node (30080/30443) sem dependências externas. Todas as requisições devem incluir explicitamente a porta (ex: `curl http://app.jarvis.local:30080`).

### Instalação

```bash
# Instalar (versão controlada via scripts/versions.env)
make ingress-install

# Atualizar após mudar values.yaml ou bumpar versão em versions.env
make ingress-upgrade
```

### Verificar

```bash
make ingress-status
```

### Testando

```bash
# Deploy dos recursos de teste hello-world
make ingress-test-deploy

# Adicionar hostname (substitua <NODE_IP> pela saída de: kubectl get nodes -o wide)
echo "<NODE_IP> test.jarvis.local" | sudo tee -a /etc/hosts

# Testar
curl http://test.jarvis.local:30080

# Limpar
make ingress-test-clean
```

### Criando Recursos Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: apps           # deve bater com o namespace do Service
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx   # obrigatório
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

Após aplicar, adicione o hostname ao `/etc/hosts` e acesse na porta `:30080`.

### Troubleshooting

| Sintoma | Causa provável | Verificação |
|---------|---------------|-------------|
| Pod do controller não está rodando | Conflito de porta ou recursos insuficientes | `kubectl describe pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx` |
| `curl` retorna 404 | Nenhuma regra Ingress bate com a requisição | `kubectl describe ingress <name> -n <namespace>` |
| `curl` connection refused | Porta errada ou entrada em `/etc/hosts` faltando | `kubectl get svc -n ingress-nginx ingress-nginx-controller` |

### Comandos Úteis

```bash
make ingress-status   # Pods, services e todos os recursos Ingress
make ingress-logs     # Stream dos logs do controller
make ingress-upgrade  # Atualiza após mudar values.yaml ou versão
```

## Dicas de Segurança

> Estas dicas são um ponto de partida para reduzir exposições óbvias — não uma baseline de segurança. Proteger o seu homelab é sua responsabilidade.

Algumas ações simples que fazem diferença:

- **Firewall (UFW):** SSH (22), K3s API (6443) e Kubelet (10250) escutam em todas as interfaces por padrão. Restrinja ao seu subnet local. Veja [documentação do UFW](https://help.ubuntu.com/community/UFW).
- **Somente chaves SSH:** Desative o login SSH por senha e use autenticação por chave. Certifique-se de que sua chave pública está em `~/.ssh/authorized_keys` antes de desativar senhas — edite o `sshd_config` manualmente; usar `sed` nele é arriscado pois a sintaxe varia entre distros e versões do OpenSSH.
- **Atualizações do SO:** Habilite `unattended-upgrades` para patches de segurança. Atualize a versão do K3s em `scripts/versions.env` e reexecute `make install` periodicamente.
- **Kubeconfig:** Execute `chmod 600 ~/.kube/config`. Nunca commite ou compartilhe — concede acesso total de admin ao cluster.
