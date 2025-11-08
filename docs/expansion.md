# K3s Homelab Expansion: From Orchestrator to Multi-Node Cluster

This document outlines the streamlined process for bootstrapping your K3s cluster using the `orchestrator.sh` script and expanding it with additional machines using the `workers.sh` script.

---

## Overall Prerequisites: Shared Storage

Before you begin, ensure you have a functional **NFS server** on your network. The automated monitoring stack requires persistent storage, and the scripts are pre-configured to use a `StorageClass` named `nfs-client`.

**Action Required:** You must manually deploy an NFS provisioner to your cluster after the orchestrator is running to satisfy this storage requirement. The `orchestrator.sh` and `workers.sh` scripts will install the necessary `nfs-utils` client tools on each node.

---

## Phase 1: Deploying the Orchestrator Node (Desktop 1)

The first desktop runs as the **Control Plane** (server) and is configured entirely by the `orchestrator.sh` script. This script provides a fully automated, idempotent setup for the core of your homelab.

### 1. Pre-Installation Check

| Requirement | Action | Detail |
| :--- | :--- | :--- |
| **Email** | **Configure Script** | Update the `EMAIL` variable in `orchestrator.sh`. This is used for your Let's Encrypt SSL certificate notifications. |

### 2. Execution and Automated Services

Simply run the orchestrator script with `sudo`. It will handle the entire setup process.

| Step | Action | Command |
| :--- | :--- | :--- |
| **1. Execute** | **Run Orchestrator Script** | `sudo orchestrator.sh` |

The script automates the following services:
*   **System Preparation:** Disables swap and installs all necessary tools (`curl`, `git`, `kubectl`, `podman`, `helm`, `nfs-utils`).
*   **K3s Server Installation:** Installs K3s in server mode.
*   **`kubectl` Access:** Configures `~/.kube/config` for immediate cluster management by your user.
*   **Traefik Ingress:** Deploys the `HelmChartConfig` to enable the `letsencrypt` certificate resolver for automatic SSL.
*   **PLG Monitoring Stack:** Deploys Prometheus, Loki, and Grafana, creating a `monitoring` namespace and a secure, one-time admin password for Grafana.
*   **CI/CD Preparation:** Installs Tailscale and generates a unique SSH key pair (`~/.ssh/github-actions`) to prepare the node for secure access from a GitHub Actions runner.

### 3. Post-Installation

| Step | Action | Detail |
| :--- | :--- | :--- |
| **1. Router Forwarding** | **Manual Step** | Forward **External Ports 80 and 443** on your router to the **Internal IP Address of Desktop 1**. |
| **2. NFS Provisioner** | **Manual Step** | Deploy your chosen NFS provisioner manifest to create the `nfs-client` `StorageClass`. |

### 4. Verification

On Desktop 1, confirm the cluster is running:

```bash
kubectl get nodes
# Output: Should show your machine as "Ready" with a Role of "control-plane,master"
```

---

## Phase 2: Adding Worker Nodes with `workers.sh` (Desktop 2+)

Adding additional desktops is handled by the `workers.sh` script, which makes them **Worker Agents** that securely join the existing cluster. This script provides a safe, user-friendly, and idempotent method for expansion.

### 1. Prerequisites (From Desktop 1 - The Orchestrator)

Before touching the new desktop, retrieve two critical pieces of information from the running server (Desktop 1).

| Item | Command on Desktop 1 | Purpose |
| :--- | :--- | :--- |
| **Server URL** | `ip a` (Get internal IP) | The address the agent must connect to (e.g., `https://192.168.1.10:6443`). |
| **Cluster Token** | `sudo cat /var/lib/rancher/k3s/server/node-token` | The secure secret that authenticates the new node. **(e.g., K10...::server:...)** |

### 2. Worker Agent Installation (On New Desktop)

On each new Arch desktop you want to add, use the `workers.sh` script. It automates system preparation (disabling swap, installing `nfs-utils`) and securely joins the node to the cluster.

```bash
# Execute this command on the new worker node. Replace placeholders.
sudo workers.sh <SERVER_URL> <YOUR_CLUSTER_TOKEN>

# Example:
sudo workers.sh https://192.168.1.10:6443 K10abc123def456...
```

The script will validate your inputs and test connectivity before attempting to join the cluster.

### 3. Final Verification

Return to **Desktop 1 (the Orchestrator)** and verify that the new node has joined the cluster.

```bash
kubectl get nodes
```

The output will now show **multiple nodes** (Desktop 1 as the `control-plane,master`, and the new machine(s) as `<none>`) all with the status **`Ready`**.

---

## Post-Expansion Benefits

  * **Load Balancing:** Traefik automatically routes traffic across application Pods running on *all* available nodes.
  * **High Availability (HA):** Kubernetes will automatically reschedule application containers to a healthy node if one desktop fails.
  * **Scaling:** You now have the combined CPU and RAM resources of all machines available for your application replicas.

---

## Next Steps: Deploying Stateful Workloads

With your cluster expanded, you can now deploy stateful applications like a database. Use the `database.sh` script to deploy MySQL.

**To deploy the database to a specific worker node:**
```bash
# Taint the node and deploy MySQL to it
sudo database.sh <worker-node-name>
```

This isolates your database on a dedicated machine for stable performance.

---

## Advanced: Migrating the Database to a Dedicated Worker

If you initially deployed the database to the orchestrator node and later wish to move it to a dedicated worker, you must perform a migration to preserve your data. The safest method is a backup and restore procedure.

**High-Level Migration Steps:**

1.  **Maintenance Mode:** Place your applications in maintenance mode to prevent new data from being written to the database.
2.  **Backup Data:** Use `kubectl exec` to access the running MySQL pod and `mysqldump` to create a logical backup of your databases into a `.sql` file. Copy this file to your local machine with `kubectl cp`.
3.  **Tear Down Old Database:** Delete the old MySQL `StatefulSet` and `PersistentVolumeClaim` in the `database` namespace. This frees up the resources.
4.  **Deploy New Database:** Run the `database.sh` script, targeting your new dedicated worker node (e.g., `sudo database.sh worker-db-01`). This creates a fresh, empty database instance on the correct node.
5.  **Restore Data:** Use `kubectl cp` to copy your `.sql` backup file into the new MySQL pod, then `kubectl exec` into the pod and use the `mysql` client to import the data.
6.  **Verify:** Confirm the data is restored correctly and take your applications out of maintenance mode.