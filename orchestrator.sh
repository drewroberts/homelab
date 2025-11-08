#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
EMAIL="websites@drewroberts.com"
K3S_CONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
KUBECONFIG_DIR="$HOME/.kube"

# --- Functions ---

log() {
    echo -e "\n\033[1;34m>>> $1\033[0m"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "Please run this script with sudo."
        exit 1
    fi
}

# --- Main Script ---

check_root

log "1. System Preparation and Tool Installation (using yay)"

# 1.1 Disable swap permanently (K3s requirement)
SWAP_ACTIVE=$(swapon --show | wc -l)
SWAP_IN_FSTAB=$(grep -c "swap" /etc/fstab || echo "0")

if [ "$SWAP_ACTIVE" -gt 0 ]; then
    log "Disabling active swap..."
    swapoff -a
fi

if [ "$SWAP_IN_FSTAB" -gt 0 ]; then
    log "Commenting out swap entries in /etc/fstab..."
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
fi

if [ "$SWAP_ACTIVE" -eq 0 ] && [ "$SWAP_IN_FSTAB" -eq 0 ]; then
    log "Swap already disabled and removed from fstab."
elif [ "$SWAP_ACTIVE" -eq 0 ] && [ "$SWAP_IN_FSTAB" -gt 0 ]; then
    log "Swap was inactive but fstab entries have been commented out."
elif [ "$SWAP_ACTIVE" -gt 0 ] && [ "$SWAP_IN_FSTAB" -eq 0 ]; then
    log "Active swap disabled (fstab was already clean)."
else
    log "Swap disabled and fstab entries commented out."
fi

# 1.2 Install necessary packages
PACKAGES="curl git kubectl podman"
MISSING_PACKAGES=()

# Check which packages are missing
for package in $PACKAGES; do
    if ! pacman -Qi "$package" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$package")
    fi
done

# Only install missing packages
if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "Installing missing packages: ${MISSING_PACKAGES[*]}"
    yay -S --noconfirm "${MISSING_PACKAGES[@]}" || { log "FATAL: Package installation failed."; exit 1; }
else
    log "All required packages already installed."
fi

log "2. Installing K3s (Single-Node Server)"

# 2.1 Check if K3s is already installed and running
if systemctl is-active --quiet k3s; then
    log "K3s is already installed and running."
    K3S_VERSION=$(k3s --version 2>/dev/null | head -n1 | awk '{print $3}' || echo "unknown")
    log "Current K3s version: $K3S_VERSION"
    
    # Verify cluster is healthy
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        log "K3s cluster is healthy and ready."
    else
        log "K3s is running but cluster may have issues. Continuing with configuration..."
    fi
else
    log "Installing K3s (Server mode)..."
    curl -sfL https://get.k3s.io | sh -
    
    log "Waiting for K3s to initialize..."
    sleep 10
    kubectl wait --for=condition=Ready node/$(hostname) --timeout=120s || { log "FATAL: K3s node failed to become ready."; exit 1; }
fi

log "3. Configuring Cluster Access for Current User"

# 3.1 Setup Kubeconfig for the user who called the script
CALLING_USER=$(logname)
USER_HOME=$(eval echo ~$CALLING_USER)
USER_KUBECONFIG="$USER_HOME/.kube/config"

# Check if kubeconfig already exists and is valid
if [ -f "$USER_KUBECONFIG" ]; then
    if sudo -u "$CALLING_USER" kubectl --kubeconfig="$USER_KUBECONFIG" cluster-info >/dev/null 2>&1; then
        log "Kubectl access already configured and working for $CALLING_USER"
    else
        log "Existing kubeconfig invalid, updating..."
        mkdir -p "$USER_HOME/.kube"
        cp "$K3S_CONFIG_PATH" "$USER_KUBECONFIG"
        chown -R "$CALLING_USER":"$CALLING_USER" "$USER_HOME/.kube"
        chmod 600 "$USER_KUBECONFIG"
    fi
else
    log "Setting up kubectl access for user: $CALLING_USER"
    mkdir -p "$USER_HOME/.kube"
    cp "$K3S_CONFIG_PATH" "$USER_KUBECONFIG"
    chown -R "$CALLING_USER":"$CALLING_USER" "$USER_HOME/.kube"
    chmod 600 "$USER_KUBECONFIG"
fi

log "4. Configuring Traefik for Let's Encrypt (ACME Resolver)"

# 4.1 Define the Traefik override file content
TRAEFIK_CONFIG=$(cat <<- EOF
# Note: K3s uses HelmChartConfig to override Traefik's default settings.
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |
    # Enable the ACME (Let's Encrypt) feature
    globalArguments:
      - "--certificatesresolvers.letsencrypt.acme.email=${EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
EOF
)

# 4.2 Write the configuration file
TRAEFIK_CONFIG_PATH="/var/lib/rancher/k3s/server/manifests/traefik-config.yaml"
RESTART_NEEDED=false

# Check if Traefik config exists and contains our email
if [ -f "$TRAEFIK_CONFIG_PATH" ] && grep -q "letsencrypt.acme.email=${EMAIL}" "$TRAEFIK_CONFIG_PATH"; then
    log "Traefik configuration already exists and is correct."
else
    log "Writing/updating Traefik configuration to $TRAEFIK_CONFIG_PATH"
    echo "$TRAEFIK_CONFIG" > "$TRAEFIK_CONFIG_PATH"
    RESTART_NEEDED=true
fi

log "5. Applying K3s Configuration Changes"

# 5.1 Only restart K3s if configuration changed
if [ "$RESTART_NEEDED" = true ]; then
    log "Restarting K3s to apply Traefik changes..."
    systemctl restart k3s
    log "Waiting for Traefik configuration to apply..."
    sleep 15
else
    log "No K3s restart needed - configuration unchanged."
fi

log "6. Installing PLG Monitoring Stack (Prometheus, Loki, Grafana)"

# 6.1 Create monitoring namespace
log "Creating monitoring namespace..."
if ! kubectl get namespace monitoring &>/dev/null; then
    kubectl create namespace monitoring
    log "Monitoring namespace created."
else
    log "Monitoring namespace already exists."
fi

# 6.2 Install Prometheus (P in PLG Stack)
log "Installing Prometheus..."
PROMETHEUS_MANIFEST="/var/lib/rancher/k3s/server/manifests/prometheus.yaml"
if [ ! -f "$PROMETHEUS_MANIFEST" ]; then
    cat > "$PROMETHEUS_MANIFEST" << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: monitoring
spec:
  serviceName: prometheus
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        ports:
        - containerPort: 9090
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        volumeMounts:
        - name: prometheus-storage
          mountPath: /prometheus
        - name: prometheus-config
          mountPath: /etc/prometheus
        args:
          - '--config.file=/etc/prometheus/prometheus.yml'
          - '--storage.tsdb.path=/prometheus'
          - '--storage.tsdb.retention.time=30d'
          - '--web.console.libraries=/etc/prometheus/console_libraries'
          - '--web.console.templates=/etc/prometheus/consoles'
      volumes:
      - name: prometheus-config
        configMap:
          name: prometheus-config
  volumeClaimTemplates:
  - metadata:
      name: prometheus-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-service
  namespace: monitoring
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
    - job_name: 'prometheus'
      static_configs:
      - targets: ['localhost:9090']
    - job_name: 'kubernetes-nodes'
      kubernetes_sd_configs:
      - role: node
    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
      - role: pod
EOF
    log "Prometheus manifest created."
else
    log "Prometheus manifest already exists."
fi

# 6.3 Install Loki (L in PLG Stack)
log "Installing Loki..."
LOKI_MANIFEST="/var/lib/rancher/k3s/server/manifests/loki.yaml"
if [ ! -f "$LOKI_MANIFEST" ]; then
    cat > "$LOKI_MANIFEST" << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: monitoring
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:latest
        ports:
        - containerPort: 3100
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        volumeMounts:
        - name: loki-storage
          mountPath: /loki
        - name: loki-config
          mountPath: /etc/loki
        args:
          - '-config.file=/etc/loki/loki.yml'
      volumes:
      - name: loki-config
        configMap:
          name: loki-config
  volumeClaimTemplates:
  - metadata:
      name: loki-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Gi
---
apiVersion: v1
kind: Service
metadata:
  name: loki-service
  namespace: monitoring
spec:
  selector:
    app: loki
  ports:
  - port: 3100
    targetPort: 3100
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: monitoring
data:
  loki.yml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    ingester:
      lifecycler:
        address: 127.0.0.1
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1
    schema_config:
      configs:
      - from: 2020-05-15
        store: boltdb
        object_store: filesystem
        schema: v11
        index:
          prefix: index_
          period: 168h
    storage_config:
      boltdb:
        directory: /loki/index
      filesystem:
        directory: /loki/chunks
    limits_config:
      enforce_metric_name: false
      reject_old_samples: true
      reject_old_samples_max_age: 168h
EOF
    log "Loki manifest created."
else
    log "Loki manifest already exists."
fi

# 6.4 Install Grafana (G in PLG Stack)
log "Installing Grafana..."
GRAFANA_MANIFEST="/var/lib/rancher/k3s/server/manifests/grafana.yaml"
if [ ! -f "$GRAFANA_MANIFEST" ]; then
    cat > "$GRAFANA_MANIFEST" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "homelab123"
        - name: GF_INSTALL_PLUGINS
          value: "grafana-piechart-panel"
        volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana
      volumes:
      - name: grafana-storage
        persistentVolumeClaim:
          claimName: grafana-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: monitoring
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: monitoring
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
  - hosts:
    - monitoring.drewroberts.com
    secretName: grafana-tls
  rules:
  - host: monitoring.drewroberts.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana-service
            port:
              number: 3000
EOF
    log "Grafana manifest created."
else
    log "Grafana manifest already exists."
fi

log "Waiting for monitoring stack to deploy..."
sleep 10

# Wait for pods to be ready
log "Checking monitoring stack status..."
kubectl wait --for=condition=Ready pod -l app=prometheus -n monitoring --timeout=120s || log "Prometheus may still be starting..."
kubectl wait --for=condition=Ready pod -l app=grafana -n monitoring --timeout=120s || log "Grafana may still be starting..."
kubectl wait --for=condition=Ready pod -l app=loki -n monitoring --timeout=120s || log "Loki may still be starting..."

log "7. Setting up GitHub CI/CD Prerequisites"

# 7.1 Install Tailscale for secure CI/CD access
if command -v tailscale &> /dev/null; then
    log "Tailscale already installed."
    if systemctl is-active --quiet tailscaled; then
        log "Tailscale daemon is running."
    else
        log "Starting Tailscale daemon..."
        systemctl enable --now tailscaled
    fi
else
    log "Installing Tailscale..."
    yay -S --noconfirm tailscale || { log "FATAL: Tailscale installation failed."; exit 1; }
    systemctl enable --now tailscaled
    log "Tailscale installed. Run 'sudo tailscale up' to connect to your tailnet."
fi

# 7.2 Generate SSH key pair for GitHub Actions (if not exists)
CALLING_USER=$(logname)
USER_HOME=$(eval echo ~$CALLING_USER)
SSH_KEY_PATH="$USER_HOME/.ssh/github-actions"

if [ ! -f "$SSH_KEY_PATH" ]; then
    log "Generating SSH key pair for GitHub Actions..."
    sudo -u "$CALLING_USER" ssh-keygen -t ed25519 -C "github-actions-ci" -f "$SSH_KEY_PATH" -N ""
    
    # Add public key to authorized_keys
    log "Adding GitHub Actions public key to authorized_keys..."
    sudo -u "$CALLING_USER" cat "${SSH_KEY_PATH}.pub" >> "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    
    log "GitHub Actions SSH key pair created at: $SSH_KEY_PATH"
else
    log "GitHub Actions SSH key already exists at: $SSH_KEY_PATH"
fi

# 7.3 Display GitHub CI setup information
log "GitHub CI/CD Setup Information:"
echo ""
echo "SSH Key Locations:"
echo "  Private key (for GitHub Secrets): $SSH_KEY_PATH"
echo "  Public key: ${SSH_KEY_PATH}.pub"
echo ""
echo "Add these to your GitHub repository secrets:"
echo "  HOMELAB_SSH_KEY: $(cat $SSH_KEY_PATH | base64 -w 0)"
echo "  HOMELAB_USER: $CALLING_USER"
if command -v tailscale &> /dev/null && tailscale status &> /dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Run 'tailscale up' first")
    echo "  HOMELAB_HOST: $TAILSCALE_IP"
else
    echo "  HOMELAB_HOST: <Run 'tailscale up' to get IP>"
fi
echo ""

log "Monitoring Stack Information:"
echo ""
echo "Grafana Dashboard Access:"
echo "  URL: https://monitoring.drewroberts.com (update domain in grafana-ingress)"
echo "  Username: admin"
echo "  Password: homelab123"
echo ""
echo "Prometheus: http://prometheus-service.monitoring.svc.cluster.local:9090"
echo "Loki: http://loki-service.monitoring.svc.cluster.local:3100"
echo ""

log "✓ SETUP COMPLETE!"5. Consider implementing Phase D monitoring stack (Prometheus, Grafana, Loki)
echo ""
echo "--- NEXT STEPS ---"
echo "1. Connect to Tailscale: sudo tailscale up"
echo "2. Set up Port Forwarding (80/443) on your router to this machine"
echo "3. Log out and log back in, OR run: export KUBECONFIG=$USER_HOME/.kube/config"
echo "4. Create GitHub Personal Access Token with packages:write scope"
echo "5. Add the displayed secrets to your GitHub repository settings"
echo "6. Follow the GitHub CI/CD guide: githubci.md"
echo "7. Update monitoring.drewroberts.com in grafana-ingress to your actual domain"
echo "8. Access Grafana at https://monitoring.drewroberts.com (admin/homelab123)"
echo "9. Create ingress manifest files for each webapp to expose via Traefik"
echo "10. Your Let's Encrypt resolver name is: \033[1;32mletsencrypt\033[0m"
echo "------------------"
