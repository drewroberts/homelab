# K3s Homelab Expansion: From Single Node to a Multi-Node Cluster

This document outlines the best practices and streamlined processes for bootstrapping your K3s cluster with `orchestrator.sh` and expanding it with `workers.sh`.

---

## Core Concepts & Architecture

This homelab follows a simple, robust architecture. A text-based diagram helps illustrate the roles:

```
                                     ┌───────────────────┐
                                     │   Your Router     │
                                     │ (Port 80/443 Fwd) │
                                     └─────────┬─────────┘
                                               │
                                     ┌─────────▼─────────┐
                                     │  Orchestrator Node│
                                     │ (Control Plane)   │
                                     │ - K3s Server      │
                                     │ - Traefik Ingress │
                                     │ - Monitoring      │
                                     └─────────┬─────────┘
                                               │
                                     ┌─────────▼─────────┐
                                     │   Worker Node 1   │
                                     │  (K3s Agent)      │
                                     └───────────────────┘
                                     ┌─────────▼─────────┘
                                     │   Worker Node 2   │
                                     │  (K3s Agent)      │
                                     └───────────────────┘
```

### Best Practices for a Stable Cluster
- **Static IPs:** Assign static IPs or DHCP reservations to all cluster nodes. The orchestrator's IP, in particular, must be stable.
- **Incremental Expansion:** Add new worker nodes one at a time. After adding a node, run `kubectl get nodes` to verify it is `Ready` before proceeding to the next one.
- **Resource Management:** For production-like stability, define resource `requests` and `limits` in your application manifests. This prevents a single runaway app from crashing a node.

---

## Critical Prerequisite: Shared Storage (NFS)

> **[!] Action Required: Manual NFS Provisioner Setup**
>
> Your cluster requires a `StorageClass` named `nfs-client` for persistent data (e.g., for Prometheus and MySQL). The `orchestrator.sh` and `workers.sh` scripts only install the client-side tools (`nfs-utils`).
>
> **You must manually deploy an NFS provisioner manifest after the orchestrator is running.**
>
> **Why is this manual?** Every user's NFS server setup is different (IP address, share path).
>
> **Recommendation:** A popular and easy-to-use option is the **`nfs-subdir-external-provisioner`**. You can find Helm charts and manifests for it online. You will need to configure it with your NFS server's IP and the path to your NFS share.

---

## Phase 1: Deploying the Orchestrator Node

The first desktop runs as the **Control Plane** and is configured entirely by the `orchestrator.sh` script.

### 1. Pre-Installation Check
Update the `EMAIL` variable in `orchestrator.sh`. This is used for Let's Encrypt SSL certificate notifications.

### 2. Execution
Simply run the orchestrator script with `sudo`. It handles the entire idempotent setup.
```bash
sudo ./orchestrator.sh
```
The script automates:
*   **System Preparation:** Disables swap, installs `curl`, `git`, `kubectl`, `podman`, `helm`, `nfs-utils`.
*   **K3s Server Installation:** Installs K3s in server mode.
*   **`kubectl` Access:** Configures `~/.kube/config` for the calling user.
*   **Traefik Ingress & SSL:** Deploys `HelmChartConfig` to enable the `letsencrypt` resolver.
*   **PLG Monitoring Stack:** Deploys Prometheus, Loki, and Grafana.
*   **MySQL Monitoring:** Deploys the `prometheus-mysql-exporter` for database visibility.
*   **CI/CD Preparation:** Installs Tailscale and generates a `~/.ssh/github-actions` key pair.

### 3. Post-Installation
1.  **Router Forwarding:** Forward **External Ports 80 and 443** on your router to the **Internal IP Address** of the orchestrator node.
2.  **NFS Provisioner:** Deploy your chosen NFS provisioner manifest (see prerequisite section above).

### 4. Verification
On the orchestrator node, confirm the cluster is running:
```bash
kubectl get nodes
# Output: Should show your machine as "Ready" with a Role of "control-plane,master"
```

---

## Phase 2: Adding Worker Nodes

Adding additional desktops is handled by the `workers.sh` script, which makes them **Worker Agents** that securely join the existing cluster.

### 1. Get Connection Details (From Orchestrator)
Retrieve two critical pieces of information from the running server.

| Item | Command on Orchestrator | Purpose |
| :--- | :--- | :--- |
| **Server URL** | `ip a` (Get internal IP) | The address the agent must connect to (e.g., `https://192.168.1.10:6443`). |
| **Cluster Token** | `sudo cat /var/lib/rancher/k3s/server/node-token` | The secure secret that authenticates the new node. |

### 2. Worker Installation (On New Desktop)
On each new Arch desktop you want to add, run the `workers.sh` script. It automates system preparation and securely joins the node to the cluster.

```bash
# Execute this command on the new worker node. Replace placeholders.
sudo ./workers.sh <SERVER_URL> <YOUR_CLUSTER_TOKEN>

# Example:
sudo ./workers.sh https://192.168.1.10:6443 K10abc123def456...
```

### 3. Final Verification
Return to the **Orchestrator** and verify that the new node has joined the cluster.
```bash
kubectl get nodes
```
The output will now show **multiple nodes** (one `control-plane,master`, and the new machine(s) as `<none>`) all with the status **`Ready`**.

---

## Next Steps: Deploying Stateful Workloads (MySQL)

With your cluster running, you can deploy a database using the `database.sh` script.

#### Option 1: Deploy to the Control Plane (Single-Node Setup)
If you are running a single-node cluster, or don't need to isolate the database.
```bash
sudo ./database.sh
```

#### Option 2: Deploy to a Dedicated Worker Node
This is the recommended approach for multi-node clusters to ensure performance isolation.
```bash
# This command taints the node and deploys MySQL to it
sudo ./database.sh <worker-node-name>
```

**How does isolation work?** The script automatically applies a **taint** to the specified worker node. This taint prevents general workloads from being scheduled there. It then configures the MySQL `StatefulSet` with a **toleration** and a **nodeAffinity** rule, ensuring that the database pods can *only* run on that specific, dedicated node.

---

## Advanced: Migrating the Database to a Dedicated Worker

If you initially deployed the database to the orchestrator and later wish to move it, you must perform a backup and restore.

**High-Level Migration Steps:**

1.  **Maintenance Mode:** Stop applications from writing to the database.
2.  **Backup Data:** Use `kubectl exec` to access the running MySQL pod and `mysqldump` to create a logical backup (`.sql` file). Copy this file to your local machine with `kubectl cp`.
3.  **Tear Down Old Database:** Delete the old MySQL `StatefulSet` and `PersistentVolumeClaim` in the `database` namespace.
4.  **Deploy New Database:** Run `database.sh` targeting your new dedicated worker node (e.g., `sudo ./database.sh worker-db-01`).
5.  **Restore Data:** Use `kubectl cp` to copy your `.sql` backup file into the new MySQL pod, then `kubectl exec` into the pod and use the `mysql` client to import the data.
6.  **Verify:** Confirm the data is restored and take your applications out of maintenance mode.
