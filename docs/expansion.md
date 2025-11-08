# K3s Homelab Expansion Plan: Single Node to Multi-Node

This document recaps the process of establishing the initial K3s server on the first Arch Linux desktop and outlines the simple steps for adding worker nodes to expand the homelab cluster.

## Phase 1: Initial Server Setup (Desktop 1)

The first desktop runs as the **Control Plane** (server) and the initial **Worker Node** (agent). This phase uses the provided Bash script to automate installation and configuration.

### 1\. Pre-Installation Check

| Requirement | Action | Command/Detail |
| :--- | :--- | :--- |
| **Swap** | **Disable Permanently** | `sudo swapoff -a` and remove/comment out entries in `/etc/fstab`. |
| **Email** | **Configure Script** | Update the `EMAIL` variable in the `setup_k3s.sh` script for Let's Encrypt. |

### 2\. Execution and Core Services

| Step | Action | Command | Purpose |
| :--- | :--- | :--- | :--- |
| **1. Install** | **Run Setup Script** | `sudo ./setup_k3s.sh` | Installs K3s, Containerd, Traefik, and necessary tools. |
| **2. Traefik Setup** | **ACME Configuration** | (Automated by script) | Creates the `HelmChartConfig` to enable the `letsencrypt` certificate resolver. |
| **3. Access** | **Configure `kubectl`** | (Automated by script) | Copies `k3s.yaml` to `~/.kube/config`, enabling management access for your user. |
| **4. External Access** | **Router Forwarding** | **Manual Step** | Forward **External Ports 80 and 443** on your router to the **Internal IP Address of Desktop 1**. |

### 3\. Verification

On Desktop 1, confirm the cluster is running:

```bash
kubectl get nodes
# Output: Should show your machine as "Ready" with a Role of "control-plane,master"
```

-----

## Phase 2: Expanding to Worker Nodes (Desktop 2+)

Adding additional desktops is done via a single command, making them **Worker Agents** that join the existing cluster.

### 1\. Prerequisites (From Desktop 1 - The Server)

Before touching the new desktop, retrieve two critical pieces of information from the running server (Desktop 1).

| Item | Command on Desktop 1 | Purpose |
| :--- | :--- | :--- |
| **Server URL** | `ip a` (Get internal IP) | The address the agent must connect to (e.g., `192.168.1.10:6443`). |
| **Cluster Token** | `sudo cat /var/lib/rancher/k3s/server/node-token` | The secure secret that authenticates the new node. **(e.g., K10...::server:...)** |

### 2\. Worker Agent Installation (On New Desktop)

On each new Arch desktop you want to add:

| Step | Action | Detail |
| :--- | :--- | :--- |
| **1. Prepare** | **Disable Swap** | Run `sudo swapoff -a` (if not already done). |
| **2. Install Agent** | **Execute Join Command** | Run the K3s installation script with the required variables to join the existing cluster. |

```bash
# Execute this command on the new worker node. Replace placeholders.
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<DESKTOP_1_IP>:6443 \
    K3S_TOKEN=<YOUR_CLUSTER_TOKEN> \
    sh -
```

### 3\. Final Verification

Return to **Desktop 1 (the Server)** and verify that the new node has joined the cluster.

```bash
kubectl get nodes
```

The output will now show **multiple nodes** (Desktop 1 as the Server, and the new machine(s) as Agents) all with the status **`Ready`**.

-----

## Post-Expansion Benefits

  * **Load Balancing:** Traefik automatically routes traffic across application Pods running on *all* nodes.
  * **High Availability (HA):** Kubernetes will automatically reschedule application containers to a healthy node if one desktop fails.
  * **Scaling:** You now have the combined CPU and RAM resources of all machines available for your Laravel application replicas.