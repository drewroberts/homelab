# Homelab K3s Cluster

A production-ready Kubernetes homelab built on Arch Linux desktops using K3s, Traefik, and automated, idempotent deployment scripts.

## Documentation

- **[Plan](docs/plan.md)** - Complete homelab specification with architecture, security principles, and deployment phases.
- **[Expansion Guide](docs/expansion.md)** - Step-by-step process for setting up the initial server and adding worker nodes.
- **[NFS Setup Guide](docs/nfs.md)** - How to configure the required NFS persistent storage.
- **[GitHub CI/CD Setup](docs/githubci.md)** - Guide to automated deployments from GitHub using Podman and container images.
- **[Monitoring Guide](docs/monitoring.md)** - How to manage the PLG stack and observe cluster health.

## Quick Start Scripts

### 1. Orchestrator Node Setup
Run this on your primary desktop to create the K3s control plane and deploy core services.
```bash
sudo orchestrator.sh
```

**What it does:**
- Prepares the host system (disables swap, installs `curl`, `git`, `kubectl`, `podman`, `helm`, `nfs-utils`).
- Installs and configures the K3s server with Traefik Ingress.
- Configures Traefik with Let's Encrypt for automatic SSL.
- Deploys the PLG (Prometheus, Loki, Grafana) monitoring stack via Helm.
- Prepares the node for CI/CD with Tailscale and dedicated SSH keys.
- Sets up `kubectl` access for the current user.

### 2. Worker Node Setup
Run this on additional desktops to join them to the cluster as worker nodes.
```bash
sudo workers.sh <SERVER_URL> <TOKEN>
```

**What it does:**
- Prepares the worker node (disables swap, installs `nfs-utils`).
- Joins the existing K3s cluster as an agent.
- Validates connectivity and cluster membership.

**Getting the required parameters:**
```bash
# On the orchestrator machine:
# SERVER_URL: Use internal IP + port 6443
ip a  # Find your internal IP (e.g., 192.168.1.10)

# TOKEN: Get the cluster join token
sudo cat /var/lib/rancher/k3s/server/node-token
```

### 3. Database Setup
Run this on the orchestrator node to deploy a MySQL database.
```bash
# Deploy to the control-plane (for single-node setups)
sudo database.sh

# Or, deploy to a dedicated worker node for isolation
sudo database.sh <worker-node-name>
```
**What it does:**
- Deploys a `StatefulSet` for MySQL with persistent storage.
- Automatically generates a secure root password and stores it in a Kubernetes secret.
- If a worker node is specified, it taints the node and uses affinity rules to ensure the database runs only on that node.

## Features

- **Idempotent Scripts**: Safe to run multiple times without breaking the existing setup.
- **Declarative & Script-Driven**: Manages infrastructure through version-controlled scripts and configuration files.
- **Automated Secret Management**: Automatically generates secure passwords for Grafana and MySQL.
- **Automatic SSL**: Let's Encrypt integration via Traefik for all ingress routes.
- **Zero-Trust Security**: Designed for management access only through a Tailscale VPN.
- **High Availability**: Supports a multi-node setup with automatic failover for applications.

## Next Steps

1. Set up port forwarding (80/443) on your router to the orchestrator node.
2. Run `sudo orchestrator.sh` to bootstrap the cluster.
3. (Optional) Add worker nodes using `sudo workers.sh`.
4. Run `sudo database.sh` to deploy the MySQL database.
5. Set up your CI/CD pipeline for automated application deployments (see [GitHub CI/CD Setup](docs/githubci.md)).
6. Deploy your first application.
