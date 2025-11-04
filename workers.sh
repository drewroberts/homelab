#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
# These will need to be provided when running the script
K3S_SERVER_URL=""
K3S_TOKEN=""

# --- Functions ---

log() {
    echo -e "\n\033[1;32m>>> $1\033[0m"
}

error() {
    echo -e "\n\033[1;31m❌ ERROR: $1\033[0m"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script with sudo."
        exit 1
    fi
}

show_usage() {
    echo "Usage: sudo ./workers.sh <SERVER_URL> <TOKEN>"
    echo ""
    echo "Arguments:"
    echo "  SERVER_URL    The K3s server URL (e.g., https://192.168.1.10:6443)"
    echo "  TOKEN         The cluster join token from the server node"
    echo ""
    echo "To get the required information from your server node:"
    echo "  1. Server URL: Use the internal IP of your orchestrator machine + :6443"
    echo "  2. Token: Run 'sudo cat /var/lib/rancher/k3s/server/node-token' on the server"
    echo ""
    echo "Example:"
    echo "  sudo ./workers.sh https://192.168.1.10:6443 K10abc123def456..."
}

validate_inputs() {
    if [ -z "$K3S_SERVER_URL" ] || [ -z "$K3S_TOKEN" ]; then
        error "Both SERVER_URL and TOKEN are required."
        show_usage
        exit 1
    fi
    
    # Basic URL validation
    if [[ ! "$K3S_SERVER_URL" =~ ^https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:6443$ ]]; then
        error "SERVER_URL should be in format: https://IP_ADDRESS:6443"
        show_usage
        exit 1
    fi
    
    # Basic token validation (K3s tokens start with K10)
    if [[ ! "$K3S_TOKEN" =~ ^K10.*::server:.* ]]; then
        error "TOKEN format appears invalid. Should start with 'K10' and contain '::server:'"
        show_usage
        exit 1
    fi
}

# --- Main Script ---

# Parse command line arguments
if [ $# -ne 2 ]; then
    error "Incorrect number of arguments."
    show_usage
    exit 1
fi

K3S_SERVER_URL="$1"
K3S_TOKEN="$2"

check_root
validate_inputs

log "🏠 K3s Worker Node Setup Script"
log "Server URL: $K3S_SERVER_URL"
log "Token: ${K3S_TOKEN:0:10}... (truncated for security)"

log "1. System Preparation"

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

# 1.2 Install necessary packages (minimal for worker nodes)
PACKAGES="curl git kubectl"
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
    yay -S --noconfirm "${MISSING_PACKAGES[@]}" || { error "Package installation failed."; exit 1; }
else
    log "All required packages already installed."
fi

log "2. Joining K3s Cluster as Worker Node"

# 2.1 Check if K3s agent is already installed and running
if systemctl is-active --quiet k3s-agent; then
    log "K3s agent is already installed and running."
    
    # Check if this node is already part of a cluster
    if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
        log "This node appears to already be part of a K3s cluster."
        log "If you need to rejoin a different cluster, please uninstall K3s first:"
        log "  /usr/local/bin/k3s-agent-uninstall.sh"
        exit 0
    fi
else
    log "Installing K3s agent and joining cluster..."
    
    # Test connectivity to server before attempting join
    log "Testing connectivity to K3s server..."
    if ! curl -k --connect-timeout 10 "$K3S_SERVER_URL/ping" >/dev/null 2>&1; then
        error "Cannot reach K3s server at $K3S_SERVER_URL"
        error "Please ensure:"
        error "  1. The server IP address is correct"
        error "  2. The server node is running"
        error "  3. Firewall allows access to port 6443"
        error "  4. Both machines are on the same network"
        exit 1
    fi
    
    # Install K3s agent
    curl -sfL https://get.k3s.io | K3S_URL="$K3S_SERVER_URL" K3S_TOKEN="$K3S_TOKEN" sh -
    
    log "Waiting for K3s agent to initialize..."
    sleep 10
    
    # Verify agent is running
    if systemctl is-active --quiet k3s-agent; then
        log "K3s agent successfully started."
    else
        error "K3s agent failed to start. Check logs with: journalctl -u k3s-agent"
        exit 1
    fi
fi

log "3. Installing Monitoring Agents"

# 3.1 Wait for K3s agent to be fully ready before deploying monitoring
log "Waiting for K3s agent to be fully operational..."
sleep 15

# 3.2 Deploy Node Exporter DaemonSet for host metrics
log "Installing Prometheus Node Exporter..."
NODE_EXPORTER_MANIFEST="/var/lib/rancher/k3s/agent/pod-manifests/node-exporter.yaml"
mkdir -p "$(dirname "$NODE_EXPORTER_MANIFEST")"

cat > "$NODE_EXPORTER_MANIFEST" << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
  labels:
    app: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: node-exporter
        image: prom/node-exporter:latest
        args:
        - '--path.procfs=/host/proc'
        - '--path.sysfs=/host/sys'
        - '--path.rootfs=/host/root'
        - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
        ports:
        - containerPort: 9100
          hostPort: 9100
          name: metrics
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: root
          mountPath: /host/root
          readOnly: true
        securityContext:
          runAsNonRoot: true
          runAsUser: 65534
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: root
        hostPath:
          path: /
      tolerations:
      - operator: Exists
        effect: NoSchedule
EOF

# 3.3 Deploy Promtail for log collection
log "Installing Promtail log agent..."
PROMTAIL_MANIFEST="/var/lib/rancher/k3s/agent/pod-manifests/promtail.yaml"

cat > "$PROMTAIL_MANIFEST" << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: monitoring
  labels:
    app: promtail
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      serviceAccountName: promtail
      containers:
      - name: promtail
        image: grafana/promtail:latest
        args:
        - '-config.file=/etc/promtail/config.yml'
        ports:
        - containerPort: 3101
          name: http-metrics
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "100m"
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
        - name: varlog
          mountPath: /var/log
          readOnly: true
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: varlogpods
          mountPath: /var/log/pods
          readOnly: true
        securityContext:
          runAsUser: 0
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: varlogpods
        hostPath:
          path: /var/log/pods
      tolerations:
      - operator: Exists
        effect: NoSchedule
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: monitoring
data:
  config.yml: |
    server:
      http_listen_port: 3101
      
    positions:
      filename: /tmp/positions.yaml
      
    clients:
      - url: http://loki-service.monitoring.svc.cluster.local:3100/loki/api/v1/push
        
    scrape_configs:
    - job_name: kubernetes-pods-name
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - docker: {}
      relabel_configs:
      - source_labels:
        - __meta_kubernetes_pod_label_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
        
    - job_name: kubernetes-pods-app
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - docker: {}
      relabel_configs:
      - action: drop
        regex: .+
        source_labels:
        - __meta_kubernetes_pod_label_name
      - source_labels:
        - __meta_kubernetes_pod_label_app
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail
subjects:
- kind: ServiceAccount
  name: promtail
  namespace: monitoring
EOF

log "Monitoring agents configured. They will start once the cluster is fully operational."

log "4. Verification"

# 4.1 Check agent status
if systemctl is-active --quiet k3s-agent; then
    log "✅ K3s agent is running successfully."
else
    error "K3s agent is not running."
    exit 1
fi

# 4.2 Show node information
HOSTNAME=$(hostname)
log "Worker node '$HOSTNAME' has been configured."
log "To verify the node joined successfully, run this on your server node:"
log "  kubectl get nodes"

log "✅ WORKER NODE SETUP COMPLETE!"
echo ""
echo "--- VERIFICATION STEPS ---"
echo "1. On your server node, run: kubectl get nodes"
echo "2. You should see this worker node ($HOSTNAME) listed as 'Ready'"
echo "3. Check monitoring agents: kubectl get pods -n monitoring -o wide"
echo "4. Verify Node Exporter metrics: curl http://$HOSTNAME:9100/metrics"
echo "5. Check agent logs if needed: journalctl -u k3s-agent"
echo ""
echo "--- MONITORING AGENTS INSTALLED ---"
echo "• Node Exporter: Host metrics collection (CPU, RAM, disk, network)"
echo "• Promtail: Log shipping to central Loki server"
echo "• Both agents will appear in Grafana dashboards automatically"
echo "------------------------"
