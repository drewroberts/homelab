# ArgoCD Setup Guide

ArgoCD is 100% Free and Open Source (Apache 2.0 License). It is a Cloud Native Computing Foundation (CNCF) graduated project, which is the gold standard for open source in the Kubernetes world.

This guide will help you transition from a "Push-based" CI/CD workflow (where GitHub Actions runs `kubectl apply`) to a "Pull-based" GitOps workflow using ArgoCD.

## 1. Installation

We will install ArgoCD into its own namespace using the official manifests.

```bash
# 1. Create the namespace
kubectl create namespace argocd

# 2. Install ArgoCD (Stable version)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to be ready:
```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

## 2. Accessing the UI

### Get the Initial Password
ArgoCD generates a random password for the `admin` user during installation.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

### Option A: Access via Port Forwarding (Simplest)
To access the dashboard without exposing it to the internet yet:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Now visit `https://localhost:8080` in your browser.
- **Username**: `admin`
- **Password**: (The one you retrieved above)

### Option B: Access via Traefik (Production)
Since your cluster uses Traefik with Let's Encrypt (configured in `orchestrator.sh`), you can expose ArgoCD securely.

**Important**: By default, ArgoCD uses self-signed TLS internally. To make it work smoothly with Traefik, we should disable internal TLS (Traefik handles the SSL termination).

1. **Patch ArgoCD to run in insecure mode**:
   ```bash
   kubectl -n argocd patch deployment argocd-server --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'
   ```

2. **Create the Ingress**:
   Save this as `argocd-ingress.yaml` and apply it (`kubectl apply -f argocd-ingress.yaml`).

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: argocd-server-ingress
     namespace: argocd
     annotations:
       # Use the Let's Encrypt resolver defined in orchestrator.sh
       traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
   spec:
     rules:
     - host: argocd.drewroberts.com  # REPLACE THIS with your actual domain
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: argocd-server
               port:
                 number: 80
   ```

## 3. The GitOps Workflow

In this model, your GitHub Actions pipeline **does not** touch your cluster.

1.  **Code Change**: You push code to GitHub.
2.  **CI Pipeline**: GitHub Actions builds the Docker image and pushes it to a registry (e.g., GHCR).
3.  **Config Update**: GitHub Actions (or you manually) updates the `deployment.yaml` in your git repo to point to the new image tag (e.g., `myapp:v1.0.1`).
4.  **ArgoCD Sync**: ArgoCD sees the change in the git repo and updates the cluster to match.

## 4. Deploying Your First App

Let's say you have a repository `github.com/drewroberts/homelab-apps` containing a folder `my-laravel-app` with your Kubernetes YAMLs (`deployment.yaml`, `service.yaml`, etc.).

You create an **Application** resource in Kubernetes to tell ArgoCD to manage it.

Create `application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-laravel-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/drewroberts/homelab-apps.git
    targetRevision: HEAD
    path: my-laravel-app
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true      # Delete resources that are removed from git
      selfHeal: true   # Fix cluster if someone manually changes something
```

Apply it:
```bash
kubectl apply -f application.yaml
```

## 5. Connecting Private Repositories

If your repository is private, you need to give ArgoCD access.

1.  **Generate SSH Keys**: `ssh-keygen -t ed25519 -C "argocd"`.
2.  **Add Public Key to GitHub**: Go to Repo Settings -> Deploy Keys -> Add Key.
3.  **Add Private Key to ArgoCD**:
    - Go to ArgoCD UI -> Settings -> Repositories -> Connect Repo.
    - Select "SSH".
    - Paste the private key.
