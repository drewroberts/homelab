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
if grep -q "swap" /etc/fstab; then
    log "Disabling swap and removing fstab entry..."
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
else
    log "Swap already disabled/removed in fstab."
fi

# 1.2 Install necessary packages
PACKAGES="curl git kubectl podman yay"
if command -v yay &> /dev/null; then
    log "Yay is installed. Installing required packages..."
    yay -Syu --noconfirm $PACKAGES || { log "FATAL: Package installation failed."; exit 1; }
else
    log "Yay not found. Attempting to install with pacman first..."
    pacman -Syu --noconfirm $PACKAGES || { log "FATAL: Package installation failed. Install yay manually or update the script."; exit 1; }
fi

log "2. Installing K3s (Single-Node Server)"

# 2.1 Install K3s (Server mode)
curl -sfL https://get.k3s.io | sh -

log "Waiting for K3s to initialize..."
sleep 10
kubectl wait --for=condition=Ready node/$(hostname) --timeout=120s || { log "FATAL: K3s node failed to become ready."; exit 1; }

log "3. Configuring Cluster Access for Current User"

# 3.1 Setup Kubeconfig for the user who called the script
CALLING_USER=$(logname)
USER_HOME=$(eval echo ~$CALLING_USER)

log "Setting up kubectl access for user: $CALLING_USER"
mkdir -p "$USER_HOME/.kube"
cp "$K3S_CONFIG_PATH" "$USER_HOME/.kube/config"
chown -R "$CALLING_USER":"$CALLING_USER" "$USER_HOME/.kube"
chmod 600 "$USER_HOME/.kube/config"

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
log "Writing Traefik configuration to $TRAEFIK_CONFIG_PATH"
echo "$TRAEFIK_CONFIG" > "$TRAEFIK_CONFIG_PATH"

log "5. Restarting K3s to Apply Traefik Changes"

# 5.1 Restart K3s systemd service
systemctl restart k3s

log "Waiting for Traefik configuration to apply..."
sleep 15

log "✅ SETUP COMPLETE!"
echo ""
echo "--- NEXT STEPS ---"
echo "1. Log out and log back in, OR run: export KUBECONFIG=$USER_HOME/.kube/config"
echo "2. Verify Traefik setup by applying an Ingress manifest."
echo "3. Remember to set up Port Forwarding (80/443) on your home router."
echo "4. Your Let's Encrypt resolver name is: \033[1;32mletsencrypt\033[0m"
echo "------------------"
