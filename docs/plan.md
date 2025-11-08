# Homelab Specification: K3s, Traefik, & Podman for High Availability

## HOMELAB CONSTITUTION: ARCHITECTURE & PRINCIPLES

This document defines the high-level architecture, security, and operational principles for your self-hosted Kubernetes environment, supporting multi-tenancy and scaling.

### 1. Architecture Overview

The system is defined as a **single logical K3s cluster** spanning multiple physical Arch Linux desktops, providing High Availability (HA) and simplified scaling.

| Component | Role | Desktop(s) |
| :--- | :--- | :--- |
| **Orchestrator** | **K3s (Lightweight Kubernetes)** | All Nodes |
| **Reverse Proxy / Ingress** | **Traefik** (K3s built-in Ingress Controller) | All Nodes (via DaemonSet) |
| **Container Runtime** | **Containerd** (K3s Default) | All Nodes |
| **Image Builder** | **Podman** (Used exclusively in CI/CD pipeline) | CI Runner / Local Development |
| **Cluster Access** | **Tailscale** (Zero Trust Mesh VPN) | All Nodes |
| **Stateful Data** | **MySQL** (Separate StatefulSet with dedicated storage) | Dedicated Worker Node(s) |

---

### 2. Security and Access Principles

* **Zero Trust Access:** Management of the K3s API (`kubectl`) and SSH access to the nodes must only occur over the **Tailscale** VPN layer. The public AT&T router will **only** forward ports **80** and **443** to the primary **Control Plane Node** (Desktop 1).
* **Rootless CI/CD:** All container image builds (via **Podman**) will be performed in a rootless environment. All secrets (registry credentials, SSH keys) must be stored in **GitHub Secrets**, not in code.
* **Principle of Least Privilege:** Pods will run as non-root users whenever possible. Deployments will use resource **requests and limits** to prevent "noisy neighbor" issues.
* **Master Node Isolation:** The Control Plane Node will retain its default Kubernetes **Taint** (`node-role.kubernetes.io/control-plane:NoSchedule`) to prevent general application Pods from consuming critical resources.
* **Database Isolation:** Stateful workloads (MySQL) will use **Taints and Tolerations** to ensure they are scheduled only on dedicated, stable Worker Nodes, separate from the Control Plane.

---

### 3. Spec-Driven Development (GitOps Lite)

* **Source of Truth:** All infrastructure and application configuration (Kubernetes YAML) will reside in a version-controlled Git repository (`homelab-config`).
* **Deployment Policy:** Changes to the cluster state are only permitted via **`kubectl apply`** of manifest files from the central Git repository, ensuring the current state matches the desired state defined in code.
* **Zero-Downtime:** Application updates will leverage the native Kubernetes **Rolling Update** strategy within the Deployment manifest. New Pods must be **Ready** before old Pods are terminated.

---

## HOMELAB PLAN: SETUP & CI/CD WORKFLOW

### Phase A: Cluster Bootstrap and Initial Setup

| Step | Component | Action | Details |
| :--- | :--- | :--- | :--- |
| **A.1** | **Host OS** | **Prepare Arch Linux** | Disable swap: `sudo swapoff -a` and remove entry from `/etc/fstab`. Install `curl`, `git`, `kubectl`, `podman`, `tailscale`, `helm`, and `nfs-utils`. |
| **A.2** | **Networking** | **Install Tailscale** | Install the Tailscale client on **all** desktops for internal cluster communication security. |
| **A.3** | **K3s Server** | **Install Control Plane (Desktop 1)** | Run the K3s installation script. This desktop will be the single point of management. |
| **A.4** | **K3s Config** | **Configure `kubectl`** | `sudo chmod 644 /etc/rancher/k3s/k3s.yaml` and copy the file to `~/.kube/config` on your management machine. |
| **A.5** | **Traefik SSL** | **Enable Let's Encrypt** | Create a `HelmChartConfig` manifest override to enable the ACME resolver for Traefik. |

---

### Phase B: Automated Monitoring & Observability

The PLG (Prometheus, Loki, Grafana) stack is deployed automatically by the `orchestrator.sh` script, ensuring a complete, production-ready monitoring solution is available immediately after cluster bootstrap. This process is fully idempotent and managed via version-controlled configuration.

*   **Automated Installation**: The `orchestrator.sh` script handles the entire deployment process.
*   **Core Technology**:
    *   **Prometheus & Grafana**: Deployed via the official `kube-prometheus-stack` Helm chart for robust, community-maintained configuration.
    *   **Loki**: Deployed as a separate `StatefulSet` for centralized log aggregation.
*   **Centralized Configuration**: All settings for the monitoring stack are managed in the `homelab/monitoring/values.yaml` file, which provides a single source of truth for persistence, Grafana dashboards, and Ingress settings.
*   **Idempotent & Secure**: The deployment creates a `monitoring` namespace, securely generates a one-time Grafana admin password, and uses `helm upgrade --install` to ensure the process is safely re-runnable.

This automated approach replaces the previous manual, multi-step process, integrating observability directly into the cluster's core setup.

---

### Phase C: Scaling Out and Database Deployment

This phase covers adding more compute capacity to the cluster and deploying the stateful MySQL database using the provided automation script.

| Step | Component | Action | Details |
| :--- | :--- | :--- | :--- |
| **C.1** | **Join Cluster** | **Add Worker Agent (Desktop 2+)** | Use the `workers.sh` script to add new machines to the cluster, expanding its resource pool. |
| **C.2** | **Deploy Database** | **Run `database.sh` script** | Use the `database.sh` script to deploy a MySQL `StatefulSet`. The script can target a dedicated worker node for isolation or deploy to the control-plane for single-node setups. |

---

### Phase D: CI/CD Workflow (Podman & GitHub Actions)

The `orchestrator.sh` script automates the initial setup on the control-plane node required for a secure CI/CD pipeline.

*   **Automated Host Preparation**: The script idempotently installs Tailscale for secure, out-of-band network access and generates a unique SSH key pair (`~/.ssh/github-actions`) for the GitHub Actions runner to use.
*   **Secure by Default**: This ensures that CI/CD access to the cluster does not require exposing SSH to the public internet. The script outputs the necessary secrets to be added to your GitHub repository.

| Stage | Tool | Steps |
| :--- | :--- | :--- |
| **1. Build** (CI) | **GitHub Actions + Podman** | 1. `podman build` the new Laravel image with the commit SHA as the tag. 2. `podman push` the tagged image to the GitHub Container Registry (`ghcr.io`). |
| **2. Deploy** (CD) | **GitHub Actions + SSH** | 1. **SSH** into the K3s Control Plane (Desktop 1) using GitHub Secrets. 2. Execute a deployment script to **patch the Deployment** manifest. |
| **3. Cluster Update** | **K3s/kubectl** | Run the command to initiate a rolling update: `kubectl set image deployment/laravel-multitenant laravel-app=ghcr.io/<REPO>:<NEW_SHA>`. |
| **4. Ingress** | **Traefik** | Traefik performs its routine, directing traffic to the healthy new Pods and terminating the old ones, completing the **zero-downtime deployment**. |

---

## Laravel Multi-Tenant Deployment Specification

```yaml
# FILE: apps/laravel-multitenant/deployment.yaml

---
apiVersion: v1
kind: Service
metadata:
  name: laravel-multi-tenant-service
  namespace: laravel-apps
spec:
  selector:
    app: laravel-multi-tenant
  ports:
  - protocol: TCP
    port: 80 
    targetPort: 8000 # App container port
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: laravel-multi-tenant
  namespace: laravel-apps
spec:
  replicas: 3 
  selector:
    matchLabels:
      app: laravel-multi-tenant
  strategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: laravel-multi-tenant
    spec:
      # Pod Definition for Laravel Container
      containers:
      - name: laravel-app
        image: ghcr.io/<YOUR_GH_USER>/<REPO_NAME>:<TAG> 
        ports:
        - containerPort: 8000
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        env:
        - name: DB_HOST
          value: mysql-multi-tenant-service.laravel-apps.svc.cluster.local 

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-tenant-router
  namespace: laravel-apps
  annotations:
    # Use Traefik's internal cert resolver (assumes Phase A.5 is complete)
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt 
    # Optional: Automatically redirect HTTP to HTTPS
    traefik.ingress.kubernetes.io/router.entrypoints: websecure 
spec:
  tls:
  # One certificate covering multiple domains (SANs)
  - hosts: 
    - tenant1.mydomain.com
    - tenant2.mydomain.com
    - myapp.mydomain.com
    secretName: multitenant-tls-secret
  rules:
  - host: tenant1.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: laravel-multi-tenant-service
            port:
              number: 80
  - host: tenant2.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: laravel-multi-tenant-service
            port:
              number: 80
```
