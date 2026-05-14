SHELL := /bin/bash
.DEFAULT_GOAL := help

SCRIPTS_DIR := scripts
KUBERNETES_DIR := kubernetes
VERSIONS_ENV := $(SCRIPTS_DIR)/versions.env

ifneq (,$(wildcard $(VERSIONS_ENV)))
    include $(VERSIONS_ENV)
    export
endif

INGRESS_NGINX_CHART_VERSION ?= 4.15.1
INGRESS_NGINX_VALUES := $(KUBERNETES_DIR)/system/ingress-nginx/values.yaml

# Colors
BOLD  := \033[1m
GREEN := \033[0;32m
CYAN  := \033[0;36m
NC    := \033[0m

##@ Bootstrap

.PHONY: init
init: ## Copy versions.env.sample → versions.env (run once before anything else)
	@if [ -f $(VERSIONS_ENV) ]; then \
		echo "$(VERSIONS_ENV) already exists — skipping"; \
	else \
		cp $(SCRIPTS_DIR)/versions.env.sample $(VERSIONS_ENV); \
		echo "Created $(VERSIONS_ENV) — edit it if you need different versions"; \
	fi

.PHONY: install
install: ## Install system dependencies: Docker, K3s, Helm, k9s
	@chmod +x $(SCRIPTS_DIR)/install-dependencies.sh
	$(SCRIPTS_DIR)/install-dependencies.sh

.PHONY: setup
setup: _require-versions ## Configure the cluster: namespaces, NVIDIA runtime, device plugin, metrics-server, ingress-nginx
	@chmod +x $(SCRIPTS_DIR)/setup-cluster.sh
	$(SCRIPTS_DIR)/setup-cluster.sh

.PHONY: validate
validate: _require-versions ## Validate the full cluster setup
	@chmod +x $(SCRIPTS_DIR)/validate-cluster.sh
	$(SCRIPTS_DIR)/validate-cluster.sh

.PHONY: all
all: install setup validate ## Full bootstrap: install → setup → validate

##@ Cluster Status

.PHONY: status
status: ## Show node status and resource usage
	@echo -e "$(BOLD)Nodes:$(NC)"
	kubectl get nodes -o wide
	@echo ""
	@echo -e "$(BOLD)Resources:$(NC)"
	kubectl top nodes 2>/dev/null || echo "metrics-server not ready — run: make setup"

.PHONY: pods
pods: ## List all pods across all namespaces
	kubectl get pods -A

.PHONY: namespaces
namespaces: ## List all namespaces
	kubectl get namespaces

.PHONY: gpu-status
gpu-status: ## Show GPU capacity registered on the cluster node
	@echo -e "$(BOLD)GPU capacity:$(NC)"
	@kubectl get nodes -o json | jq -r '.items[0].status.capacity | {"CPU": .cpu, "Memory": .memory, "GPU": .["nvidia.com/gpu"]}'

##@ Ingress (NGINX)

.PHONY: ingress-install
ingress-install: ## Install ingress-nginx via Helm (version from versions.env)
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo update
	helm install ingress-nginx ingress-nginx/ingress-nginx \
		--version $(INGRESS_NGINX_CHART_VERSION) \
		--namespace ingress-nginx \
		--create-namespace \
		--values $(INGRESS_NGINX_VALUES)

.PHONY: ingress-upgrade
ingress-upgrade: ## Upgrade ingress-nginx to the version in versions.env
	helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
		--version $(INGRESS_NGINX_CHART_VERSION) \
		--namespace ingress-nginx \
		--values $(INGRESS_NGINX_VALUES)

.PHONY: ingress-status
ingress-status: ## Show ingress-nginx pods, services, and all Ingress resources
	@echo -e "$(BOLD)ingress-nginx resources:$(NC)"
	kubectl get all -n ingress-nginx
	@echo ""
	@echo -e "$(BOLD)Ingress resources (cluster-wide):$(NC)"
	kubectl get ingress -A

.PHONY: ingress-logs
ingress-logs: ## Stream ingress-nginx controller logs
	kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

.PHONY: ingress-test-deploy
ingress-test-deploy: ## Deploy hello-world test Ingress resources
	kubectl apply -f $(KUBERNETES_DIR)/system/ingress-nginx/test-ingress.yaml
	@echo ""
	@echo "Add to /etc/hosts (replace IP with: kubectl get nodes -o wide):"
	@echo "  echo \"<NODE_IP> test.jarvis.local\" | sudo tee -a /etc/hosts"
	@echo ""
	@echo "Then test with: curl http://test.jarvis.local:30080"

.PHONY: ingress-test-clean
ingress-test-clean: ## Remove hello-world test Ingress resources
	kubectl delete -f $(KUBERNETES_DIR)/system/ingress-nginx/test-ingress.yaml

##@ Helpers

.PHONY: _require-versions
_require-versions:
	@if [ ! -f $(VERSIONS_ENV) ]; then \
		echo "Error: $(VERSIONS_ENV) not found. Run: make init"; \
		exit 1; \
	fi

.PHONY: help
help: ## Show this help
	@awk ' \
		/^##@/ { printf "\n$(BOLD)%s$(NC)\n", substr($$0, 5) } \
		/^[a-zA-Z_-]+:.*##/ { \
			target = $$1; sub(/:.*/, "", target); \
			help = $$0; sub(/.*## /, "", help); \
			printf "  $(CYAN)%-22s$(NC) %s\n", target, help \
		} \
	' $(MAKEFILE_LIST)
	@echo ""
