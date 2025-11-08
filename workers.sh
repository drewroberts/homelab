#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
K3S_SERVER_URL=""
K3S_TOKEN=""

# --- Utility Functions ---

log() {
    echo -e "\n\033[1;32m>>> $1\033[0m"
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

show_usage() {
    echo "Usage: sudo workers.sh <SERVER_URL> <TOKEN>"
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
    echo "  sudo workers.sh https://192.168.1.10:6443 K10abc123def456..."
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

# --- Worker Node Setup Functions ---

prepare_worker_system() {
    log "1. System Preparation"

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

    # Install necessary packages (minimal for worker nodes)
    PACKAGES="curl git kubectl nfs-utils"
    MISSING_PACKAGES=()

    for package in $PACKAGES; do
        if ! pacman -Qi "$package" >/dev/null 2>&1; then
            MISSING_PACKAGES+=("$package")
        fi
    done

    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        log "Installing missing packages: ${MISSING_PACKAGES[*]}"
        yay -S --noconfirm "${MISSING_PACKAGES[@]}" || { error "Package installation failed."; exit 1; }
    else
        log "All required packages already installed."
    fi
}

join_k3s_cluster() {
    log "2. Joining K3s Cluster as Worker Node"

    # Check if K3s agent is already installed and running
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
}

verify_worker_setup() {
    log "3. Verification"

    # Check agent status
    if systemctl is-active --quiet k3s-agent; then
        log "✓ K3s agent is running successfully."
    else
        error "K3s agent is not running."
        exit 1
    fi

    # Show node information
    HOSTNAME=$(hostname)
    log "Worker node '$HOSTNAME' has been configured."
    log "To verify the node joined successfully, run this on your server node:"
    log "  kubectl get nodes"
}

display_worker_completion() {
    HOSTNAME=$(hostname)
    
    log "✓ WORKER NODE SETUP COMPLETE!"
    echo ""
    echo "--- VERIFICATION STEPS ---"
    echo "1. On your server node, run: kubectl get nodes"
    echo "2. You should see this worker node ($HOSTNAME) listed as 'Ready'"
    echo "3. Check agent logs if needed: journalctl -u k3s-agent"
    echo ""
    echo "--- NODE PREPARATION COMPLETE ---"
    echo "• NFS client tools have been installed to support shared storage."
    echo "• Monitoring agents (Prometheus Node Exporter, Promtail) will be deployed automatically by the orchestrator."
    echo "------------------------"
}

# --- Main Execution ---

main() {
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

    log "K3s Worker Node Setup Script"
    log "Server URL: $K3S_SERVER_URL"
    log "Token: ${K3S_TOKEN:0:10}... (truncated for security)"

    # Execute setup phases
    prepare_worker_system
    join_k3s_cluster
    verify_worker_setup
    display_worker_completion
}

# Execute main function with all script arguments
main "$@"
