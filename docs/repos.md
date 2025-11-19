# Repository Standards for Homelab Applications

This guide details the required structure and configuration for applications deployed to this homelab. It ensures compatibility with our **Podman-based container runtime**, **ArgoCD GitOps workflow**, and **security policies** (non-root users).

---

## 1. Laravel Application (PHP)

### Repository Structure
```
my-laravel-app/
├── Containerfile                # Podman build definition
├── k8s/                         # Kubernetes manifests for ArgoCD
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── configmap.yaml
└── src/                         # Laravel source code
```

### `Containerfile` (Podman)
**Critical Requirements:**
- Must use a multi-stage build to keep the image small.
- **Security:** Must create and switch to a non-root user with **UID 1000** (matching the host user).
- **Networking:** Must expose port **8080** (since non-root users cannot bind to port 80).

```dockerfile
# --- Stage 1: Builder ---
FROM composer:2.7 as builder
WORKDIR /app
COPY src/composer.json src/composer.lock ./
RUN composer install --no-interaction --no-dev --optimize-autoloader

# --- Stage 2: Production ---
FROM php:8.4-apache

WORKDIR /var/www/html

# Install extensions
RUN docker-php-ext-install pdo pdo_mysql && a2enmod rewrite

# SECURITY: Create non-root user (UID 1000)
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m -s /bin/bash appuser

# Copy code & set permissions
COPY src/ .
COPY --from=builder /app/vendor/ ./vendor/
RUN chown -R appuser:appuser /var/www/html && \
    chmod -R 775 /var/www/html/storage

# Configure Apache to listen on 8080
RUN sed -i 's/80/8080/g' /etc/apache2/ports.conf /etc/apache2/sites-available/*.conf

# Switch to non-root user
USER appuser
EXPOSE 8080
```

### Kubernetes Manifests (`k8s/`)

**`deployment.yaml`**
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
      # SECURITY: Enforce UID 1000
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: app
        image: ghcr.io/drewroberts/my-laravel-app:latest
        ports:
        - containerPort: 8080  # Matches Containerfile EXPOSE
        readinessProbe:
          httpGet:
            path: /up
            port: 8080
```

**`service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-laravel-app
spec:
  selector:
    app: my-laravel-app
  ports:
  - port: 80           # Service listens on standard HTTP port
    targetPort: 8080   # Forwards to container's non-root port
```

---

## 2. React Application (TypeScript + Vite)

### Repository Structure
```
my-react-app/
├── Containerfile                # Podman build definition
├── k8s/                         # Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── package.json
└── src/
```

### `Containerfile` (Podman)
**Critical Requirements:**
- **Multi-stage:** Build the static assets with Node.js, serve them with Nginx.
- **Security:** Run Nginx as non-root (UID 1000).
- **Networking:** Nginx must listen on port **8080**.

```dockerfile
# --- Stage 1: Builder ---
FROM node:20-alpine as builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- Stage 2: Production (Nginx) ---
FROM nginxinc/nginx-unprivileged:alpine

# The 'nginx-unprivileged' image already runs as non-root (UID 101) by default.
# However, to standardize on UID 1000 for our homelab:
USER root
RUN addgroup -g 1000 appuser && \
    adduser -u 1000 -G appuser -D appuser && \
    # Fix permissions for Nginx folders
    chown -R appuser:appuser /var/cache/nginx /var/run /var/log/nginx /etc/nginx/conf.d

# Copy built assets
COPY --from=builder --chown=appuser:appuser /app/dist /usr/share/nginx/html

# Configure Nginx to listen on 8080
RUN sed -i 's/80/8080/g' /etc/nginx/conf.d/default.conf

# Switch to our standard user
USER appuser
EXPOSE 8080
```

### Kubernetes Manifests (`k8s/`)

**`deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-react-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-react-app
  template:
    metadata:
      labels:
        app: my-react-app
    spec:
      # SECURITY: Enforce UID 1000
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: app
        image: ghcr.io/drewroberts/my-react-app:latest
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
```

**`service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-react-app
spec:
  selector:
    app: my-react-app
  ports:
  - port: 80
    targetPort: 8080
```

---

## 3. ArgoCD Integration

For both application types, you need to register them with ArgoCD.

**`application.yaml`** (Apply this to your cluster once)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/drewroberts/my-app-repo.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```
