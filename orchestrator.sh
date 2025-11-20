#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
EMAIL="websites@drewroberts.com"
K3S_CONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

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

prepare_host_system() {
    log "1. System Preparation and Tool Installation"

    # Disable swap permanently (K3s requirement)
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

    # Install necessary packages
    # Standard packages
    STD_PACKAGES="curl git kubectl podman helm nfs-utils"
    MISSING_STD_PACKAGES=()

    for package in $STD_PACKAGES; do
        if ! pacman -Qi "$package" >/dev/null 2>&1; then
            MISSING_STD_PACKAGES+=("$package")
        fi
    done

    if [ ${#MISSING_STD_PACKAGES[@]} -gt 0 ]; then
        log "Installing missing standard packages: ${MISSING_STD_PACKAGES[*]}"
        pacman -S --noconfirm "${MISSING_STD_PACKAGES[@]}" || { error "Package installation failed."; exit 1; }
    else
        log "All required standard packages already installed."
    fi

    # AUR packages (kubeseal)
    if ! pacman -Qi kubeseal >/dev/null 2>&1; then
        log "Installing kubeseal from AUR..."
        if [ -n "${SUDO_USER:-}" ]; then
             sudo -u "$SUDO_USER" yay -S --noconfirm kubeseal || { error "kubeseal installation failed."; exit 1; }
        else
             error "Cannot install AUR packages as root without SUDO_USER. Please install 'kubeseal' manually."
             exit 1
        fi
    fi
}

install_k3s_server() {
    log "2. Installing K3s (Single-Node Server)"

    if systemctl is-active --quiet k3s; then
        log "K3s is already installed and running."
        K3S_VERSION=$(k3s --version 2>/dev/null | head -n1 | awk '{print $3}' || echo "unknown")
        log "Current K3s version: $K3S_VERSION"
        
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
        kubectl wait --for=condition=Ready node/"$(hostname)" --timeout=120s || { error "K3s node failed to become ready."; exit 1; }
    fi
}

configure_kubectl() {
    log "3. Configuring Cluster Access for Current User"

    CALLING_USER=$(logname)
    USER_HOME=$(eval echo "~$CALLING_USER")
    USER_KUBECONFIG="$USER_HOME/.kube/config"

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
}

install_essentials() {
    log "4. Installing Essentials (Cert-Manager & Sealed Secrets)"

    # --- Cert-Manager ---
    log "Installing Cert-Manager (SSL)..."
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update

    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --set installCRDs=true \
      --wait

    log "Creating Let's Encrypt ClusterIssuer..."
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

    # --- Sealed Secrets ---
    log "Installing Sealed Secrets (GitOps)..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update
    helm repo update

    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
      --namespace kube-system \
      --set-string fullnameOverride=sealed-secrets-controller \
      --wait
      
    log "Essentials installed."
}

deploy_plg_stack() {
    log "5. Deploying PLG Monitoring Stack (Prometheus, Loki, Grafana)"

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
        echo -e "  Your one-time generated password is: \033[1;33m$ADMIN_PASSWORD\033[0m"
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

deploy_mysql_exporter() {
    log "6. Deploying MySQL Exporter for Prometheus"

    log "Checking for 'database' namespace and 'mysql-secret'..."
    if ! kubectl get namespace database >/dev/null 2>&1; then
        log "WARNING: 'database' namespace not found. Skipping MySQL exporter deployment."
        log "         Run 'database.sh' to create the database and its secret first."
        return
    fi

    if ! kubectl get secret mysql-secret -n database >/dev/null 2>&1; then
        log "WARNING: 'mysql-secret' not found in 'database' namespace. Skipping MySQL exporter deployment."
        log "         Run 'database.sh' to create the database and its secret first."
        return
    fi

    log "Deploying prometheus-mysql-exporter via Helm..."
    # The repo is already added in deploy_plg_stack, but let's ensure it's here for modularity
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    helm repo update

    # Use `helm upgrade --install` for idempotent deployment
    # We configure it to connect to the mysql service and use the existing secret.
    helm upgrade --install mysql-exporter prometheus-community/prometheus-mysql-exporter \
      --namespace monitoring \
      --set mysql.host=mysql.database \
      --set mysql.user=root \
      --set mysql.existingSecret=database/mysql-secret \
      --set serviceMonitor.enabled=true \
      --wait

    log "MySQL Exporter deployment is complete."
}

install_argocd() {
    log "7. Installing ArgoCD (GitOps)"

    # 1. Create namespace
    log "Ensuring 'argocd' namespace exists..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    # 2. Install ArgoCD
    log "Applying ArgoCD manifests..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    # 3. Wait for pods
    log "Waiting for ArgoCD pods to be ready..."
    kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

    # 4. Patch for Insecure Mode (Required for Traefik SSL termination)
    log "Patching ArgoCD server to run in insecure mode (for Traefik compatibility)..."
    kubectl -n argocd patch deployment argocd-server --type=json \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'

    # 5. Create Ingress
    log "Creating ArgoCD Ingress..."
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  rules:
  - host: argocd.drewroberts.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

    # 6. Get Initial Password
    log "Retrieving initial admin password..."
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    echo ""
    echo "  ArgoCD installed successfully."
    echo "  URL: https://argocd.drewroberts.com"
    echo "  Username: admin"
    echo -e "  Password: \033[1;33m$ARGOCD_PASSWORD\033[0m"
    echo ""
}

setup_tailscale() {
    log "8. Setting up Tailscale (Secure Remote Access)"

    # Install Tailscale
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
        pacman -S --noconfirm tailscale || { error "Tailscale installation failed."; exit 1; }
        systemctl enable --now tailscaled
        log "Tailscale installed."
    fi
    
    echo ""
    echo "  To connect this node to your Tailnet, run:"
    echo "  sudo tailscale up"
    echo ""
}

display_completion_info() {
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

    log "✓ SETUP COMPLETE!"
    echo ""
    echo "--- NEXT STEPS ---"
    echo "1. Connect to Tailscale: sudo tailscale up"
    echo "2. Set up Port Forwarding (80/443) on your router to this machine"
    echo "3. Deploy a database with: sudo database.sh [NODE_NAME]"
    echo "4. Log out and log back in, OR run: export KUBECONFIG=$USER_HOME/.kube/config"
    echo "5. Follow the Repository Standards guide: docs/repos.md"
    echo "6. Update monitoring.drewroberts.com in monitoring/values.yaml to your actual domain"
    echo "7. Access Grafana at https://monitoring.drewroberts.com"
    echo "8. Access ArgoCD at https://argocd.drewroberts.com"
    echo "------------------"
}

# --- Main Execution ---

main() {
    check_root
    
    log "Starting Orchestrator Setup..."
    
    # Phase A: Cluster Bootstrap
    prepare_host_system
    install_k3s_server
    configure_kubectl
    configure_traefik
    
    # Phase B: Monitoring Stack
    deploy_plg_stack
    deploy_mysql_exporter
    
    # Phase C: GitOps
    install_argocd

    # Remote Access
    setup_tailscale
    
    # Display completion information
    display_completion_info
}

# Execute main function
main
