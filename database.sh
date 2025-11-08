#!/bin/bash
set -euo pipefail

# --- Configuration ---
DB_NAMESPACE="database"
DB_STORAGE_CLASS="nfs-client"
DB_STORAGE_SIZE="20Gi"

# --- Utility Functions ---

log() {
    echo -e "\n\033[1;34m>>> $1\033[0m"
}

error() {
    echo -e "\n\033[1;31m✗ ERROR: $1\033[0m"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script with sudo."
    fi
}

show_usage() {
    echo "Usage: sudo deploy-database.sh [NODE_NAME]"
    echo ""
    echo "Deploys a MySQL StatefulSet to your K3s cluster."
    echo ""
    echo "Arguments:"
    echo "  [NODE_NAME]   (Optional) The name of the worker node to dedicate to the database."
    echo "                If provided, the script will taint the node and pin the database to it."
    echo "                If omitted, the script will deploy the database to the control-plane node."
    echo ""
    echo "Examples:"
    echo "  # Deploy to a dedicated worker node named 'worker-db-01'"
    echo "  sudo deploy-database.sh worker-db-01"
    echo ""
    echo "  # Deploy to the control-plane node (for single-node clusters)"
    echo "  sudo deploy-database.sh"
}

# --- Core Functions ---

ensure_namespace() {
    log "Ensuring namespace '$DB_NAMESPACE' exists..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $DB_NAMESPACE
EOF
}

create_mysql_secret() {
    log "Ensuring MySQL secret exists..."
    if ! kubectl get secret mysql-credentials -n "$DB_NAMESPACE" &>/dev/null; then
        log "MySQL secret not found. Creating a new one..."
        MYSQL_ROOT_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24)
        kubectl create secret generic mysql-credentials -n "$DB_NAMESPACE" --from-literal=root-password="$MYSQL_ROOT_PASSWORD"
        echo "  MySQL root password created and stored in a secret."
        echo "  Your one-time generated password is: \033[1;33m$MYSQL_ROOT_PASSWORD\033[0m"
    else
        log "MySQL secret already exists. No changes made."
    fi
}

deploy_to_control_plane() {
    log "Deploying MySQL to the control-plane node..."
    log "This is suitable for single-node clusters."

    # The control-plane node has a default taint. We must add a toleration for it.
    # Taint: node-role.kubernetes.io/control-plane:NoSchedule
    TOLERATION_YAML=$(cat <<-EOF
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
EOF
)

    apply_mysql_manifest "" "$TOLERATION_YAML"
}

deploy_to_worker() {
    local node_name="$1"
    log "Deploying MySQL to dedicated worker node: $node_name"

    # Verify the node exists
    if ! kubectl get node "$node_name" >/dev/null; then
        error "Node '$node_name' not found in the cluster."
    fi

    # Taint the node to reserve it for database workloads.
    # The --overwrite flag makes this operation idempotent.
    log "Tainting node '$node_name' with 'app-type=db:NoSchedule'..."
    kubectl taint nodes "$node_name" app-type=db:NoSchedule --overwrite

    # Define the specific toleration and node affinity to pin the pod to this node.
    TOLERATION_YAML=$(cat <<-EOF
      tolerations:
      - key: "app-type"
        operator: "Equal"
        value: "db"
        effect: "NoSchedule"
EOF
)
    NODE_AFFINITY_YAML=$(cat <<-EOF
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - $node_name
EOF
)

    apply_mysql_manifest "$NODE_AFFINITY_YAML" "$TOLERATION_YAML"
}

apply_mysql_manifest() {
    local affinity_yaml="$1"
    local toleration_yaml="$2"

    log "Applying MySQL StatefulSet manifest..."

    # Heredoc containing the full Kubernetes manifest for MySQL
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: $DB_NAMESPACE
spec:
  clusterIP: None # Headless service for StatefulSet
  selector:
    app: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: $DB_NAMESPACE
spec:
  serviceName: "mysql"
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      # Apply the tolerations and affinity rules passed into this function
      $toleration_yaml
      $affinity_yaml
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-credentials
              key: root-password
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: mysql-persistent-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: $DB_STORAGE_CLASS
      resources:
        requests:
          storage: $DB_STORAGE_SIZE
EOF

    log "MySQL manifest applied. Waiting for StatefulSet to be ready..."
    kubectl rollout status statefulset/mysql -n "$DB_NAMESPACE" --timeout=5m
    log "✓ MySQL deployment complete!"
}

# --- Main Execution ---

main() {
    check_root

    if [ "$#" -gt 1 ]; then
        error "Too many arguments."
        show_usage
    fi

    ensure_namespace
    create_mysql_secret

    if [ "$#" -eq 0 ]; then
        # No node name provided, deploy to control-plane
        deploy_to_control_plane
    else
        # Node name provided, deploy to specific worker
        deploy_to_worker "$1"
    fi

    echo ""
    echo "--- MySQL Access Information ---"
    echo "Service Name: mysql.$DB_NAMESPACE.svc.cluster.local"
    echo "Namespace: $DB_NAMESPACE"
    echo "Password Secret: mysql-credentials"
    echo "------------------------------"
}

main "$@"
