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

error() {
    echo -e "\n\033[1;31m✗ ERROR: $1\033[0m"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script with sudo."
        exit 1
    fi
}

deploy_plg_stack() {
    log "Deploying PLG Monitoring Stack (Prometheus, Loki, Grafana)"

    # Idempotently create the monitoring namespace
    log "Ensuring 'monitoring' namespace exists..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
EOF

    # Idempotently create the Grafana admin password secret
    log "Ensuring Grafana admin secret exists..."
    if ! kubectl get secret grafana-credentials -n monitoring &>/dev/null; then
        log "Grafana secret not found. Creating a new one..."
        ADMIN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24)
        kubectl create secret generic grafana-credentials -n monitoring --from-literal=admin-password="$ADMIN_PASSWORD"
        echo "  Grafana admin password created and stored in a secret."
        echo "  Your one-time generated password is: \033[1;33m$ADMIN_PASSWORD\033[0m"
    else
        log "Grafana secret already exists. No changes made."
    fi

    # Deploy Loki for log aggregation
    log "Deploying Loki StatefulSet..."
    cat <<EOF | kubectl apply -f -
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
        args:
          - "-config.file=/etc/loki/local-config.yaml"
        ports:
        - containerPort: 3100
        volumeMounts:
        - name: loki-storage
          mountPath: /loki
  volumeClaimTemplates:
  - metadata:
      name: loki-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: nfs-client
      resources:
        requests:
          storage: 100Gi
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: monitoring
spec:
  selector:
    app: loki
  ports:
  - port: 3100
    targetPort: 3100
EOF

    # Deploy the main monitoring stack using Helm for idempotency
    log "Deploying kube-prometheus-stack via Helm..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    helm repo update

    # Use `helm upgrade --install` for idempotent deployment
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --values ./monitoring/values.yaml \
      --wait

    log "PLG monitoring stack deployment is complete."
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
PACKAGES="curl git kubectl podman helm nfs-utils"
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

    log "No K3s restart needed - configuration unchanged."
fi

# Deploy the monitoring stack
deploy_plg_stack

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
echo "  URL: https://monitoring.drewroberts.com"
echo "  Username: admin"
echo "  Password: See secret 'grafana-credentials' in 'monitoring' namespace or check console output from first run."
echo ""
echo "Prometheus: Forward port 9090 from the prometheus pod to access."
echo "Loki: Accessible via Grafana."
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
echo "7. Update monitoring.drewroberts.com in monitoring/values.yaml to your actual domain"
echo "8. Access Grafana at https://monitoring.drewroberts.com"
echo "9. Create ingress manifest files for each webapp to expose via Traefik"
echo "10. Your Let's Encrypt resolver name is: \033[1;32mletsencrypt\033[0m"
echo "------------------"
