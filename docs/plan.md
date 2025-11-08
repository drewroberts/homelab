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
| **A.1** | **Host OS** | **Prepare Arch Linux** | Disable swap: `sudo swapoff -a` and remove entry from `/etc/fstab`. Install `curl`, `git`, `kubectl`, `podman`, `tailscale`. |
| **A.2** | **Networking** | **Install Tailscale** | Install the Tailscale client on **all** desktops for internal cluster communication security. |
| **A.3** | **K3s Server** | **Install Control Plane (Desktop 1)** | Run the K3s installation script. This desktop will be the single point of management. |
| **A.4** | **K3s Config** | **Configure `kubectl`** | `sudo chmod 644 /etc/rancher/k3s/k3s.yaml` and copy the file to `~/.kube/config` on your management machine. |
| **A.5** | **Traefik SSL** | **Enable Let's Encrypt** | Create a `HelmChartConfig` manifest override to enable the ACME resolver for Traefik. |

---

### Phase B: Scaling Out and Database Deployment

| Step | Component | Action | Details |
| :--- | :--- | :--- | :--- |
| **B.1** | **Join Cluster** | **Add Worker Agent (Desktop 2+)** | On the second desktop, use the token retrieved from Desktop 1 to join the cluster. |
| **B.2** | **Storage** | **Set up NFS/Storage** | Configure a shared **Persistent Volume** solution (e.g., NFS share) accessible by all nodes for storing application files and database data. |
| **B.3** | **Database Node** | **Taint Node** | Apply a taint to designated database Worker Node(s) to isolate MySQL: `kubectl taint nodes worker-db-01 app-type=db:NoSchedule`. |
| **B.4** | **MySQL Deployment** | **Deploy StatefulSet** | Deploy MySQL using a **StatefulSet** with a **PersistentVolumeClaim** and matching **Tolerations** and **Node Affinity** to ensure it only runs on the dedicated DB node(s). |

---

### Phase C: CI/CD Workflow (Podman & GitHub Actions)

| Stage | Tool | Steps |
| :--- | :--- | :--- |
| **1. Build** (CI) | **GitHub Actions + Podman** | 1. `podman build` the new Laravel image with the commit SHA as the tag. 2. `podman push` the tagged image to the GitHub Container Registry (`ghcr.io`). |
| **2. Deploy** (CD) | **GitHub Actions + SSH** | 1. **SSH** into the K3s Control Plane (Desktop 1) using GitHub Secrets. 2. Execute a deployment script to **patch the Deployment** manifest. |
| **3. Cluster Update** | **K3s/kubectl** | Run the command to initiate a rolling update: `kubectl set image deployment/laravel-multitenant laravel-app=ghcr.io/<REPO>:<NEW_SHA>`. |
| **4. Ingress** | **Traefik** | Traefik performs its routine, directing traffic to the healthy new Pods and terminating the old ones, completing the **zero-downtime deployment**. |

---

### Phase D: Monitoring & Observability (PLG Stack)

Deploying a robust PLG (Prometheus, Loki, Grafana) stack is best accomplished using the `kube-prometheus-stack` Helm chart. It bundles Prometheus, Grafana, Alertmanager, and key exporters, managing them with a central, version-controlled configuration. This approach is superior to applying individual YAML files.

| Step | Component | Action | Details |
| :--- | :--- | :--- | :--- |
| **D.1** | **Helm Repo** | **Add Prometheus Community Repo** | `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts` |
| **D.2** | **Namespace** | **Create Monitoring Namespace** | `kubectl create namespace monitoring` - Isolate the entire monitoring stack. |
| **D.3** | **Helm Values** | **Configure `values.yaml`** | Create a `monitoring-values.yaml` file to configure persistence, Grafana dashboards, and ingress. |
| **D.4** | **Helm Install** | **Deploy the Stack** | `helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring -f monitoring-values.yaml` |
| **D.5** | **Loki** | **Deploy Log Aggregation** | Deploy Loki and Promtail separately, as they are not part of this chart. Configure Grafana to use Loki as a data source. |
| **D.6** | **Ingress** | **Expose Dashboards** | The Helm chart can create Ingress resources automatically for Grafana and Prometheus, secured via Tailscale. |

---

#### Best Practice: Monitoring Architecture & Configuration

The `kube-prometheus-stack` chart deploys the **Prometheus Operator**, which automates the management of the monitoring infrastructure. The key components are:

*   **Prometheus Operator**: Watches for custom resources like `ServiceMonitor` and `PodMonitor` and automatically updates the Prometheus configuration to scrape metrics from new services.
*   **Prometheus**: A `StatefulSet` for metrics collection and storage.
*   **Grafana**: A `StatefulSet` for visualization. The chart pre-configures it to use the deployed Prometheus as a data source.
*   **Node Exporter**: A `DaemonSet` that collects host-level metrics from every node.
*   **Alertmanager**: A `StatefulSet` to handle alerts defined in Prometheus.

Below is a sample `monitoring-values.yaml` demonstrating best practices for configuration.

```yaml
# FILE: monitoring/monitoring-values.yaml
#
# Sample values for the kube-prometheus-stack Helm chart.
# This file replaces the individual component YAMLs with a single, manageable configuration.

# --- Prometheus Configuration ---
prometheus:
  prometheusSpec:
    # Enable creating ServiceMonitors for services in other namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    # Set retention for metrics data
    retention: 30d
    # Define persistent storage for the Prometheus StatefulSet
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-client # Use the NFS provisioner from Phase B
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

# --- Grafana Configuration ---
grafana:
  # Use the Grafana StatefulSet for stable storage
  persistence:
    enabled: true
    type: pvc
    storageClassName: nfs-client # Use the NFS provisioner
    accessModes: ["ReadWriteOnce"]
    size: 10Gi
  # Define admin credentials via a secret for security
  adminPassword:
    existingSecret: grafana-credentials
    secretKey: admin-password
  # Configure Ingress to expose Grafana securely over Tailscale
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - "monitoring.drewroberts.com"
    tls:
      - secretName: grafana-tls
        hosts:
          - "monitoring.drewroberts.com"
    annotations:
      traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
  # Provision additional data sources like Loki
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring.svc.cluster.local:3100
      access: proxy
      isDefault: false

# --- Alertmanager Configuration ---
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-client
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
```

#### Key Monitoring Metrics & Alerts

| Category | Metric | Alert Threshold | Action |
| :--- | :--- | :--- | :--- |
| **Node Health** | `up{job="node-exporter"}` | Node down > 2 minutes | Send Discord alert, investigate hardware |
| **Resource Usage** | `node_memory_MemAvailable_bytes` | < 20% available memory | Scale down non-critical workloads |
| **Disk Space** | `node_filesystem_avail_bytes` | < 15% free space | Clean up logs, extend storage |
| **Pod Status** | `kube_pod_status_phase{phase="Failed"}` | Failed pods > 0 for 5 minutes | Restart deployment, check logs |
| **Laravel App** | `traefik_service_request_duration_seconds` | Response time > 2s | Scale up replicas, check database |
| **Database** | `mysql_up` | MySQL down > 30 seconds | Failover to backup, restore from snapshot |

#### Pre-configured Dashboards

The Helm chart automatically installs several essential dashboards. You can add your own by creating `ConfigMap`s with a specific label (`grafana_dashboard: "1"`).

1.  **Cluster Overview**: Node status, resource utilization, pod distribution.
2.  **Node Details**: Per-node CPU, memory, disk, network metrics.
3.  **Application Performance**: Custom dashboards for Laravel response times, error rates.
4.  **Database Monitoring**: MySQL connections, query performance, replication lag.
5.  **Traefik Ingress**: Request volume, SSL certificate expiry, backend health.

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
