# 🏠 Homelab Specification: K3s, Traefik, & Podman for High Availability

## 📜 HOMELAB CONSTITUTION: ARCHITECTURE & PRINCIPLES

This document defines the high-level architecture, security, and operational principles for your self-hosted Kubernetes environment, supporting multi-tenancy and scaling.

### 1. 🌐 Architecture Overview

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

### 2. 🛡️ Security and Access Principles

* **Zero Trust Access:** Management of the K3s API (`kubectl`) and SSH access to the nodes must only occur over the **Tailscale** VPN layer. The public AT&T router will **only** forward ports **80** and **443** to the primary **Control Plane Node** (Desktop 1).
* **Rootless CI/CD:** All container image builds (via **Podman**) will be performed in a rootless environment. All secrets (registry credentials, SSH keys) must be stored in **GitHub Secrets**, not in code.
* **Principle of Least Privilege:** Pods will run as non-root users whenever possible. Deployments will use resource **requests and limits** to prevent "noisy neighbor" issues.
* **Master Node Isolation:** The Control Plane Node will retain its default Kubernetes **Taint** (`node-role.kubernetes.io/control-plane:NoSchedule`) to prevent general application Pods from consuming critical resources.
* **Database Isolation:** Stateful workloads (MySQL) will use **Taints and Tolerations** to ensure they are scheduled only on dedicated, stable Worker Nodes, separate from the Control Plane.

---

### 3. 🔄 Spec-Driven Development (GitOps Lite)

* **Source of Truth:** All infrastructure and application configuration (Kubernetes YAML) will reside in a version-controlled Git repository (`homelab-config`).
* **Deployment Policy:** Changes to the cluster state are only permitted via **`kubectl apply`** of manifest files from the central Git repository, ensuring the current state matches the desired state defined in code.
* **Zero-Downtime:** Application updates will leverage the native Kubernetes **Rolling Update** strategy within the Deployment manifest. New Pods must be **Ready** before old Pods are terminated.

---

## 📋 HOMELAB PLAN: SETUP & CI/CD WORKFLOW

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

### Phase D: Monitoring & Observability Stack

| Step | Component | Action | Details |
| :--- | :--- | :--- | :--- |
| **D.1** | **Namespace** | **Create Monitoring Namespace** | `kubectl create namespace monitoring` - Isolate monitoring stack from application workloads. |
| **D.2** | **Prometheus** | **Deploy Metrics Collection** | Deploy Prometheus Server as StatefulSet with persistent storage for metrics retention (7-30 days). Configure ServiceMonitor resources for automatic discovery. |
| **D.3** | **Node Exporter** | **Install Host Metrics** | Deploy Node Exporter as DaemonSet on all nodes to collect CPU, memory, disk, and network metrics from each desktop. |
| **D.4** | **Grafana** | **Deploy Visualization** | Install Grafana with persistent storage for dashboards and configuration. Pre-configure dashboards for K3s cluster overview, node health, and application metrics. |
| **D.5** | **Loki** | **Log Aggregation** | Deploy Loki for centralized log collection with Promtail DaemonSet to ship logs from all pods and nodes. |
| **D.6** | **AlertManager** | **Configure Alerting** | Set up AlertManager with webhook integrations (Discord/Slack) for critical cluster events (node down, high resource usage, pod crashes). |
| **D.7** | **Ingress Rules** | **Expose Dashboards** | Create Traefik ingress rules for secure access to Grafana (`monitoring.drewroberts.com`) over Tailscale VPN only. |

#### 📊 Monitoring Architecture

```yaml
# FILE: monitoring/prometheus/deployment.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus-server
  namespace: monitoring
spec:
  serviceName: prometheus-server
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-server
  template:
    metadata:
      labels:
        app: prometheus-server
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        ports:
        - containerPort: 9090
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        volumeMounts:
        - name: prometheus-config
          mountPath: /etc/prometheus/
        - name: prometheus-storage
          mountPath: /prometheus/
        args:
          - --config.file=/etc/prometheus/prometheus.yml
          - --storage.tsdb.path=/prometheus/
          - --storage.tsdb.retention.time=30d
          - --web.console.libraries=/etc/prometheus/console_libraries
          - --web.console.templates=/etc/prometheus/consoles
      volumes:
      - name: prometheus-config
        configMap:
          name: prometheus-config
  volumeClaimTemplates:
  - metadata:
      name: prometheus-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 50Gi

---
# FILE: monitoring/grafana/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: grafana-credentials
              key: admin-password
        - name: GF_SERVER_ROOT_URL
          value: "https://monitoring.drewroberts.com"
        - name: GF_INSTALL_PLUGINS
          value: "grafana-piechart-panel,grafana-worldmap-panel"
        volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana
  volumeClaimTemplates:
  - metadata:
      name: grafana-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi

---
# FILE: monitoring/loki/deployment.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: monitoring
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:latest
        ports:
        - containerPort: 3100
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        volumeMounts:
        - name: loki-storage
          mountPath: /loki/
        args:
          - -config.file=/etc/loki/local-config.yaml
  volumeClaimTemplates:
  - metadata:
      name: loki-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 100Gi
```

#### 🚨 Key Monitoring Metrics & Alerts

| Category | Metric | Alert Threshold | Action |
| :--- | :--- | :--- | :--- |
| **Node Health** | `up{job="node-exporter"}` | Node down > 2 minutes | Send Discord alert, investigate hardware |
| **Resource Usage** | `node_memory_MemAvailable_bytes` | < 20% available memory | Scale down non-critical workloads |
| **Disk Space** | `node_filesystem_avail_bytes` | < 15% free space | Clean up logs, extend storage |
| **Pod Status** | `kube_pod_status_phase{phase="Failed"}` | Failed pods > 0 for 5 minutes | Restart deployment, check logs |
| **Laravel App** | `traefik_service_request_duration_seconds` | Response time > 2s | Scale up replicas, check database |
| **Database** | `mysql_up` | MySQL down > 30 seconds | Failover to backup, restore from snapshot |

#### 📈 Pre-configured Dashboards

1. **Cluster Overview**: Node status, resource utilization, pod distribution
2. **Node Details**: Per-node CPU, memory, disk, network metrics  
3. **Application Performance**: Laravel response times, error rates, throughput
4. **Database Monitoring**: MySQL connections, query performance, replication lag
5. **Traefik Ingress**: Request volume, SSL certificate expiry, backend health
6. **Resource Planning**: Historical trends for capacity planning

---

## 💻 Laravel Multi-Tenant Deployment Specification

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
