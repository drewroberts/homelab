# Homelab K3s Cluster

A production-ready Kubernetes homelab built on Arch Linux desktops using K3s, Traefik, and automated deployment scripts.

## Documentation

- **[Plan](plan.md)** - Complete homelab specification with architecture, security principles, and deployment phases
- **[Expansion Guide](expansion.md)** - Step-by-step process for setting up the initial server and adding worker nodes

## Quick Start Scripts

### Orchestrator Node Setup
Run this on your primary desktop to create the K3s control plane:
```bash
sudo ./orchestrator.sh
```

**What it does:**
- Disables swap (K3s requirement)
- Installs required packages (curl, git, kubectl, podman)
- Sets up K3s server with Traefik ingress controller
- Configures Let's Encrypt for automatic SSL certificates
- Sets up kubectl access for the current user

### Worker Node Setup
Run this on additional desktops to join them as worker nodes:
```bash
sudo ./workers.sh <SERVER_URL> <TOKEN>
```

**What it does:**
- Disables swap on the worker node
- Installs minimal required packages (curl, git, kubectl)
- Joins the existing K3s cluster as an agent
- Validates connectivity and cluster membership

**Getting the required parameters:**
```bash
# On the orchestrator machine:
# SERVER_URL: Use internal IP + port 6443
ip a  # Find your internal IP (e.g., 192.168.1.10)

# TOKEN: Get the cluster join token
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Features

- **Idempotent Scripts**: Safe to run multiple times without breaking existing setups
- **Zero-Trust Security**: Management access only through Tailscale VPN
- **Automatic SSL**: Let's Encrypt integration via Traefik
- **High Availability**: Multi-node setup with automatic failover
- **GitOps Ready**: Designed for spec-driven infrastructure management

## Next Steps

1. Set up port forwarding (80/443) on your router to the orchestrator node
2. Install Tailscale on all nodes for secure cluster management
3. Deploy your first application
4. Consider implementing Phase D monitoring stack (Prometheus, Grafana, Loki)
