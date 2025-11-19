# ArgoCD Setup Guide

ArgoCD is 100% Free and Open Source (Apache 2.0 License). It is a Cloud Native Computing Foundation (CNCF) graduated project, which is the gold standard for open source in the Kubernetes world.

This guide will help you transition from a "Push-based" CI/CD workflow (where GitHub Actions runs `kubectl apply`) to a "Pull-based" GitOps workflow using ArgoCD.

## 1. Installation

**Good news:** ArgoCD is automatically installed and configured by the `orchestrator.sh` script. You do not need to install it manually.

The script performs the following:
- Creates the `argocd` namespace.
- Installs the stable version of ArgoCD.
- Configures it to work with Traefik (SSL termination).
- Creates an Ingress at `https://argocd.drewroberts.com`.

## 2. Accessing the UI

### Get the Initial Password
The `orchestrator.sh` script prints the initial password at the end of its run. If you missed it, you can retrieve it with this command:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

### Access via Browser
Visit `https://argocd.drewroberts.com` (or the domain you configured in the Ingress).
- **Username**: `admin`
- **Password**: (The one you retrieved above)

## 3. The GitOps Workflow

In this model, your GitHub Actions pipeline **does not** touch your cluster.

1.  **Code Change**: You push code to GitHub.
2.  **CI Pipeline**: GitHub Actions builds the container image (using Podman) and pushes it to a registry (e.g., GHCR).
3.  **Config Update**: GitHub Actions (or you manually) updates the `deployment.yaml` in your git repo to point to the new image tag (e.g., `myapp:v1.0.1`).
4. **ArgoCD Sync**: ArgoCD sees the change in the git repo and updates the cluster to match.

## 4. Preparing Your Application Manifests

To support the secure, non-root Podman container setup (UID 1000) defined in the CI/CD guide, your Kubernetes manifests must be configured to match.

**Key Changes Required:**
1.  **Port 8080**: Since non-root users cannot bind to port 80, your container listens on 8080. Your Service must target this port.
2.  **Security Context**: Explicitly tell Kubernetes to run the pod as UID 1000.

### Example `deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-laravel-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-laravel-app
  template:
    metadata:
      labels:
        app: my-laravel-app
    spec:
      # SECURITY: Match the UID 1000 from your Containerfile
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: app
        image: ghcr.io/drewroberts/my-laravel-app:latest
        ports:
        - containerPort: 8080  # Must match the EXPOSE in Containerfile
        readinessProbe:
          httpGet:
            path: /up
            port: 8080
```

### Example `service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-laravel-app
spec:
  selector:
    app: my-laravel-app
  ports:
  - port: 80           # The Service still listens on port 80 internally
    targetPort: 8080   # Forwards traffic to the container's port 8080
```

## 5. Registering a New App

ArgoCD does not automatically know about your GitHub repositories. You must explicitly "register" each application by creating an **Application** resource in Kubernetes. This resource acts as a contract, telling ArgoCD: *"Watch this specific Git repo and sync it to this cluster."*

### The Registration Process
1.  Create a file named `application.yaml` (you can store this in your app repo or a central "fleet" repo).
2.  Edit the `repoURL` and `path` to match your project.
3.  Apply it to the cluster: `kubectl apply -f application.yaml`.

### Sample `application.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-laravel-app   # The name that will appear in the ArgoCD UI
  namespace: argocd
spec:
  project: default
  source:
    # 1. WHICH REPO?
    repoURL: https://github.com/drewroberts/homelab-apps.git
    
    # 2. WHICH BRANCH?
    targetRevision: main
    
    # 3. WHICH FOLDER? (ArgoCD looks for YAMLs here)
    path: my-laravel-app
  destination:
    # 4. WHERE TO DEPLOY?
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true      # If you delete a file in git, delete it in k8s
      selfHeal: true   # If someone manually edits k8s, revert it to match git
```

## 6. Connecting Private Repositories

If your repository is private, you need to give ArgoCD access.

1.  **Generate SSH Keys**: `ssh-keygen -t ed25519 -C "argocd"`.
2.  **Add Public Key to GitHub**: Go to Repo Settings -> Deploy Keys -> Add Key.
3.  **Add Private Key to ArgoCD**:
    - Go to ArgoCD UI -> Settings -> Repositories -> Connect Repo.
    - Select "SSH".
    - Paste the private key.

## 7. Automating Image Updates (CI)

To complete the GitOps loop, your GitHub Actions pipeline needs to:
1.  Build the container image using Podman.
2.  Push it to the registry (GHCR).
3.  **Update the `deployment.yaml` file in your git repository** with the new image tag.
4.  Commit and push the change.

ArgoCD will then detect this commit and sync the cluster.

### Example Workflow (`.github/workflows/deploy.yml`)

```yaml
name: Build and Update Manifest

on:
  push:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-update:
    runs-on: ubuntu-latest
    permissions:
      contents: write # IMPORTANT: Needed to commit back to the repo
      packages: write

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Install Podman
      run: sudo apt-get update && sudo apt-get install -y podman

    - name: Log in to GitHub Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Build and Push Image
      run: |
        IMAGE_TAG=${{ github.sha }}
        FULL_IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${IMAGE_TAG}"
        
        podman build -t $FULL_IMAGE -f Containerfile .
        podman push $FULL_IMAGE

    - name: Update Kubernetes Manifest
      run: |
        IMAGE_TAG=${{ github.sha }}
        FULL_IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${IMAGE_TAG}"
        
        # Update the image line in deployment.yaml
        # This assumes your file is at k8s/deployment.yaml
        sed -i "s|image: .*|image: $FULL_IMAGE|g" k8s/deployment.yaml
        
        # Commit and push the change
        git config --global user.name "GitHub Actions"
        git config --global user.email "actions@github.com"
        
        git add k8s/deployment.yaml
        git commit -m "Update image to $IMAGE_TAG"
        git push
```
