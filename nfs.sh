#!/bin/bash
set -euo pipefail

# --- Functions ---

log() {
    echo -e "\n\033[1;34m>>> $1\033[0m"
}

error() {
    echo -e "\n\033[1;31m✗ ERROR: $1\033[0m"
}

usage() {
    echo "Usage: $0 <NFS_SERVER_IP> <NFS_EXPORT_PATH>"
    echo ""
    echo "Deploys the nfs-subdir-external-provisioner to enable dynamic NFS storage."
    echo ""
    echo "Arguments:"
    echo "  <NFS_SERVER_IP>      The IP address of your NFS server (e.g., 192.168.1.50)."
    echo "  <NFS_EXPORT_PATH>    The absolute path of the share on your NFS server (e.g., /srv/nfs/k3s)."
    echo ""
    echo "Example:"
    echo "  sudo $0 192.168.1.50 /srv/nfs/k3s"
    exit 1
}

# --- Input Validation ---

if [ "$#" -ne 2 ]; then
    error "Invalid number of arguments."
    usage
fi

NFS_SERVER_IP="$1"
NFS_PATH="$2"

if [[ ! "$NFS_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid NFS_SERVER_IP format. Please provide a valid IP address."
    usage
fi

if [[ ! "$NFS_PATH" = /* ]]; then
    error "Invalid NFS_EXPORT_PATH. The path must be absolute (start with '/')."
    usage
fi


# --- Main Execution ---

main() {
    log "1. Adding 'nfs-subdir-external-provisioner' Helm repository..."
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ --force-update
    helm repo update

    log "2. Deploying NFS Provisioner via Helm..."
    echo "   NFS Server IP: $NFS_SERVER_IP"
    echo "   NFS Export Path: $NFS_PATH"
    echo "   StorageClass Name: nfs-client"

    # `helm upgrade --install` is idempotent. It will install the chart if it's not present,
    # or upgrade it if it is already installed, applying any configuration changes.
    helm upgrade --install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --namespace default \
        --set nfs.server="$NFS_SERVER_IP" \
        --set nfs.path="$NFS_PATH" \
        --set storageClass.name=nfs-client \
        --set storageClass.onDelete=delete \
        --wait

    log "3. Verifying StorageClass creation..."
    if kubectl get sc nfs-client >/dev/null 2>&1; then
        log "✓ Success! The 'nfs-client' StorageClass is configured and ready."
        echo "Your cluster can now dynamically provision persistent storage."
    else
        error "StorageClass 'nfs-client' was not found after deployment. Please check the Helm output for errors."
        exit 1
    fi
}

# Execute main function
main
