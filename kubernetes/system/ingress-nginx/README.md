# NGINX Ingress Controller

Routes external HTTP/HTTPS traffic to services inside the cluster based on hostname and path rules.

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

**Why NodePort instead of LoadBalancer?**  
Without MetalLB or a cloud provider, `LoadBalancer` services stay in `<pending>` indefinitely. NodePort exposes fixed ports directly on the node (30080/30443) with no external dependencies.

## Prerequisites

- Helm 3 (`helm version`)
- `kubectl` configured (`kubectl get nodes`)

## Installation

```bash
# Add the Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install the chart
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values kubernetes/system/ingress-nginx/values.yaml
```

Verify the installation:

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

## Testing

Apply the hello-world resources:

```bash
kubectl apply -f kubernetes/system/ingress-nginx/test-ingress.yaml
```

Add the hostname to `/etc/hosts` (replace with your node IP from `kubectl get nodes -o wide`):

```bash
echo "127.0.0.1 test.jarvis.local" | sudo tee -a /etc/hosts
```

Test:

```bash
curl http://test.jarvis.local:30080
# Expected: NGINX default page HTML
```

Clean up when done:

```bash
kubectl delete -f kubernetes/system/ingress-nginx/test-ingress.yaml
```

## Creating Ingress Resources

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: apps           # must match the Service namespace
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx   # required
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

After applying, add the hostname to `/etc/hosts` and access it on port `:30080`.

## Troubleshooting

| Symptom | Likely cause | Check |
|---------|-------------|-------|
| Controller pod not running | Port conflict or insufficient resources | `kubectl describe pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx` |
| `curl` returns 404 | No Ingress rule matches the request | `kubectl describe ingress <name> -n <namespace>` |
| `curl` connection refused | Wrong port or `/etc/hosts` entry missing | `kubectl get svc -n ingress-nginx ingress-nginx-controller` |

## Useful Commands

```bash
# Overall status
kubectl get all -n ingress-nginx

# Stream logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

# List all Ingress resources across the cluster
kubectl get ingress -A

# Upgrade after changing values.yaml
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values kubernetes/system/ingress-nginx/values.yaml

# Installed chart version
helm list -n ingress-nginx
```
