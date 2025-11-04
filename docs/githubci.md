# GitHub CI/CD Setup for Homelab Deployment

This guide covers setting up automated deployments from GitHub repositories to your K3s homelab using Podman, Apache containers, and GitHub Actions.

## Prerequisites

### On Your Orchestrator Node:
- K3s cluster running (via `orchestrator.sh`)
- Tailscale installed and configured
- SSH key pair for GitHub Actions access
- kubectl configured and working

### On GitHub:
- Repository with your website code
- GitHub Container Registry access
- Required secrets configured

## Repository Structure

Each website repository should have this structure:
```
your-website-repo/
├── Dockerfile                 # Apache container definition
├── .github/workflows/         # CI/CD automation
│   └── deploy.yml
├── k8s/                       # Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── src/                       # Your website source
└── apache-config/             # Optional Apache configuration
    └── site.conf
```

## Step 1: Create the Dockerfile

### For Static Sites (HTML/CSS/JS):
```dockerfile
FROM httpd:2.4-alpine

# Copy website files to Apache document root
COPY src/ /usr/local/apache2/htdocs/

# Optional: Copy custom Apache configuration
# COPY apache-config/site.conf /usr/local/apache2/conf/extra/site.conf

# Enable mod_rewrite if needed
RUN sed -i 's/#LoadModule rewrite_module/LoadModule rewrite_module/' /usr/local/apache2/conf/httpd.conf

# Expose port 80
EXPOSE 80

# Apache runs in foreground by default
CMD ["httpd-foreground"]
```

### For PHP Applications:
```dockerfile
FROM php:8.2-apache

# Install PHP extensions as needed
RUN docker-php-ext-install mysqli pdo pdo_mysql

# Enable Apache modules
RUN a2enmod rewrite

# Copy application files
COPY src/ /var/www/html/

# Optional: Copy custom Apache configuration
# COPY apache-config/site.conf /etc/apache2/sites-available/000-default.conf

# Set proper permissions
RUN chown -R www-data:www-data /var/www/html
RUN chmod -R 755 /var/www/html

EXPOSE 80
```

## Step 2: GitHub Secrets Configuration

Navigate to your repository → Settings → Secrets and variables → Actions

Add these secrets:

### Required Secrets:
- `HOMELAB_SSH_KEY` - Private SSH key for connecting to orchestrator
- `HOMELAB_HOST` - Tailscale IP or hostname of orchestrator node
- `HOMELAB_USER` - Username on orchestrator (usually your username)
- `GHCR_TOKEN` - GitHub Personal Access Token with packages:write scope

### Optional Secrets:
- `KUBECTL_CONFIG` - Base64 encoded kubeconfig (alternative to SSH)

## Step 3: GitHub Actions Workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Homelab

on:
  push:
    branches: [ main ]
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GHCR_TOKEN }}

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=ref,event=branch
          type=sha,prefix={{branch}}-
          type=raw,value=latest,enable={{is_default_branch}}

    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Deploy to homelab
      uses: appleboy/ssh-action@v1.0.0
      with:
        host: ${{ secrets.HOMELAB_HOST }}
        username: ${{ secrets.HOMELAB_USER }}
        key: ${{ secrets.HOMELAB_SSH_KEY }}
        script: |
          # Update the deployment with new image
          kubectl set image deployment/${{ github.event.repository.name }} \
            app=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.ref_name }}-${{ github.sha }}
          
          # Wait for rollout to complete
          kubectl rollout status deployment/${{ github.event.repository.name }} --timeout=300s
          
          # Verify deployment
          kubectl get pods -l app=${{ github.event.repository.name }}
```

## Step 4: Kubernetes Manifests

### Deployment (`k8s/deployment.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-website-name
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: your-website-name
  template:
    metadata:
      labels:
        app: your-website-name
    spec:
      containers:
      - name: app
        image: ghcr.io/yourusername/your-repo:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
```

### Service (`k8s/service.yaml`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: your-website-name-service
  namespace: default
spec:
  selector:
    app: your-website-name
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
```

### Ingress (`k8s/ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: your-website-name-ingress
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
  - hosts:
    - yourdomain.com
    secretName: your-website-tls
  rules:
  - host: yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: your-website-name-service
            port:
              number: 80
```

## Step 5: Initial Deployment

### Deploy Kubernetes Resources:
```bash
# SSH to your orchestrator node
ssh user@orchestrator-tailscale-ip

# Apply the manifests
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# Verify deployment
kubectl get pods
kubectl get ingress
```

## Step 6: DNS Configuration

Point your domain to your home IP address:
```
yourdomain.com    A    YOUR_PUBLIC_IP
```

Ensure port forwarding is set up on your router:
- Port 80 → Orchestrator Node IP
- Port 443 → Orchestrator Node IP

## Troubleshooting

### Check Deployment Status:
```bash
kubectl get deployments
kubectl describe deployment your-website-name
kubectl logs -l app=your-website-name
```

### Check Ingress and Certificates:
```bash
kubectl get ingress
kubectl describe ingress your-website-name-ingress
kubectl get certificates
```

### GitHub Actions Debugging:
- Check Actions tab in your repository
- Verify all secrets are properly set
- Ensure Tailscale connectivity to orchestrator
- Check SSH key permissions and format

## Security Best Practices

1. **Use Tailscale**: All management access via VPN only
2. **Minimal Permissions**: GitHub token only needs packages:write
3. **SSH Key Rotation**: Regularly rotate deployment SSH keys
4. **Image Scanning**: Consider adding vulnerability scanning to workflow
5. **Resource Limits**: Always set CPU/memory limits on containers
6. **Non-root Containers**: Run Apache as non-root when possible

## Multiple Website Management

For multiple websites, repeat this process for each repository with:
- Unique deployment/service/ingress names
- Different domain names in ingress rules
- Separate namespaces for organization (optional)

Each website will get its own automated deployment pipeline while sharing the same K3s infrastructure.