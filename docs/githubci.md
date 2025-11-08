# CI/CD Best Practices for Laravel Apps with Podman & K3s

This guide provides a modern, best-practice workflow for automatically building, testing, and deploying Laravel 11+ applications to your K3s homelab using Podman and GitHub Actions.

---

## Core Principles

This workflow is built on several modern cloud-native principles:
- **Multi-Stage Builds:** Creates lean, secure production images by separating build-time tools from the final runtime environment.
- **Podman-Native CI:** Uses Podman directly in the CI/CD pipeline for consistency with modern container ecosystems.
- **Declarative Manifests:** Manages all Kubernetes resources (`Deployment`, `Service`, `Ingress`, `ConfigMap`) as version-controlled YAML files.
- **Isolate Environments:** Uses dedicated Kubernetes namespaces for each application to provide strong security and resource isolation.
- **Health Checks:** Implements liveness and readiness probes to ensure true zero-downtime deployments.

---

## Recommended Repository Structure

Organize your Laravel application repository as follows:

```
your-laravel-app/
├── Containerfile                # Defines the multi-stage container build
├── .github/workflows/           # GitHub Actions CI/CD automation
│   └── deploy.yml
├── k8s/                         # All Kubernetes manifests
│   ├── 00-namespace.yaml
│   ├── 01-configmap.yaml
│   ├── 02-deployment.yaml
│   ├── 03-service.yaml
│   └── 04-ingress.yaml
└── src/                         # Your Laravel application source code
```

---

## Step 1: The Multi-Stage `Containerfile`

Create a file named `Containerfile` (the Podman-preferred name for a Dockerfile) in your repository root. This file uses two stages to build a lean, production-ready image.

```Containerfile
# --- Stage 1: The Builder ---
# Use the official Composer image to install PHP dependencies
FROM composer:2.7 as builder

WORKDIR /app

# Copy only the necessary files to leverage build cache
COPY src/composer.json src/composer.lock ./

# Install production dependencies
RUN composer install --no-interaction --no-plugins --no-scripts --no-dev --prefer-dist --optimize-autoloader


# --- Stage 2: The Final Production Image ---
# Start from the official PHP 8.4 Apache image
FROM php:8.4-apache

# Set the working directory
WORKDIR /var/www/html

# Install required PHP extensions for Laravel
RUN docker-php-ext-install pdo pdo_mysql

# Enable Apache's mod_rewrite for Laravel's routing
RUN a2enmod rewrite

# Copy the entire application source code
COPY src/ .

# Copy the pre-installed vendor directory from the builder stage
COPY --from=builder /app/vendor/ ./vendor/

# Set correct ownership and permissions for the web server
# The 'apache' user is created by the base image
RUN chown -R www-data:www-data /var/www/html && 
    chmod -R 775 /var/www/html/storage

# Expose port 80
EXPOSE 80
```

---

## Step 2: Kubernetes Manifests (`k8s/`)

Create a `k8s` directory and add the following YAML files. Replace `my-laravel-app` and `app.yourdomain.com` with your application's details.

#### `00-namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-laravel-app
```

#### `01-configmap.yaml`
This `ConfigMap` holds your Laravel environment variables. **Do not put sensitive secrets here.** Use GitHub Secrets for database passwords, etc., and inject them into the deployment.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-laravel-app-config
  namespace: my-laravel-app
data:
  # This content will become the .env file inside the container
  .env: |
    APP_NAME="My Laravel App"
    APP_ENV=production
    APP_DEBUG=false
    APP_URL=https://app.yourdomain.com
    LOG_CHANNEL=stderr
    DB_CONNECTION=mysql
    DB_HOST=mysql.database.svc.cluster.local # Assumes MySQL is in 'database' namespace
    DB_PORT=3306
    DB_DATABASE=laravel_db
    DB_USERNAME=laravel_user
```

#### `02-deployment.yaml`
This is the core deployment file. Note the `livenessProbe`, `readinessProbe`, and how it mounts the `ConfigMap`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-laravel-app
  namespace: my-laravel-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-laravel-app
  template:
    metadata:
      labels:
        app: my-laravel-app
    spec:
      containers:
      - name: app
        # The image tag will be replaced by the CI/CD pipeline
        image: ghcr.io/your-github-user/your-repo-name:latest
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: my-laravel-app-config
        # Inject sensitive secrets directly from Kubernetes secrets
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret # The secret created by database.sh
              key: MYSQL_ROOT_PASSWORD
              namespace: database
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /api/health # Create a simple /api/health route in Laravel
            port: 80
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/health
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 30
```

#### `03-service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-laravel-app-service
  namespace: my-laravel-app
spec:
  selector:
    app: my-laravel-app
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

#### `04-ingress.yaml`
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-laravel-app-ingress
  namespace: my-laravel-app
  annotations:
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  tls:
  - hosts:
    - app.yourdomain.com
    secretName: my-laravel-app-tls
  rules:
  - host: app.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-laravel-app-service
            port:
              number: 80
```

---

## Step 3: The GitHub Actions Workflow (`deploy.yml`)

This workflow uses Podman to build and push the image, then uses `kubectl` over SSH to apply the manifests.

```yaml
name: Build and Deploy Laravel App

on:
  push:
    branches: [ main ]
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  K8S_NAMESPACE: my-laravel-app # Match the namespace in your YAML files
  K8S_DEPLOYMENT: my-laravel-app # Match the deployment name

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
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

    - name: Build and push container image
      run: |
        podman build -t ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }} -f Containerfile .
        podman push ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}

    - name: Deploy to Homelab
      uses: appleboy/ssh-action@v1.0.3
      with:
        host: ${{ secrets.HOMELAB_HOST }}
        username: ${{ secrets.HOMELAB_USER }}
        key: ${{ secrets.HOMELAB_SSH_KEY }}
        script: |
          # Set the context to the correct user's config
          export KUBECONFIG=/home/${{ secrets.HOMELAB_USER }}/.kube/config
          
          # Apply all manifests in the k8s directory
          # This creates/updates the namespace, configmap, service, and ingress
          kubectl apply -f k8s/
          
          # Patch the deployment to use the new image SHA
          # This triggers a zero-downtime rolling update
          kubectl set image deployment/${{ env.K8S_DEPLOYMENT }} 
            -n ${{ env.K8S_NAMESPACE }} 
            app=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
            
          # Wait for the rollout to complete successfully
          kubectl rollout status deployment/${{ env.K8S_DEPLOYMENT }} -n ${{ env.K8S_NAMESPACE }} --timeout=120s
```

---

## Step 4: GitHub Secrets

Navigate to your repository's **Settings > Secrets and variables > Actions** and add the following secrets:

- `HOMELAB_HOST`: The Tailscale IP address of your orchestrator node.
- `HOMELAB_USER`: The username you use to SSH into the orchestrator node.
- `HOMELAB_SSH_KEY`: The **private** key from the `~/.ssh/github-actions` pair generated by `orchestrator.sh`.

The `GITHUB_TOKEN` is automatically provided by GitHub Actions and has the necessary permissions to push to `ghcr.io`.

---

## Step 5: Initial Deployment

The first deployment must be done manually from your orchestrator node to create all the resources.

1.  Clone your repository to the orchestrator node.
2.  Navigate into the repository directory.
3.  Run `kubectl apply -f k8s/`.

After this initial setup, every `git push` to the `main` branch will trigger the GitHub Actions workflow and automatically deploy your changes.