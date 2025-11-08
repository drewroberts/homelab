# PLG Monitoring Stack for K3s Homelab

This document describes the PLG (Prometheus, Loki, Grafana) monitoring stack automatically deployed by the `orchestrator.sh` script. This setup uses modern, declarative, and version-controlled practices.

---

## Architecture Overview

The monitoring stack is deployed into the `monitoring` namespace and consists of two core parts, both automated by the `orchestrator.sh` script:

1.  **`kube-prometheus-stack` (via Helm):** This official Helm chart is the heart of the stack. It bundles, configures, and manages:
    *   **Prometheus:** For collecting and storing all cluster metrics.
    *   **Grafana:** For visualizing metrics and logs.
    *   **Monitoring Agents:** Includes `node-exporter` (for host metrics) and other agents deployed as `DaemonSets` to automatically scrape data from every node in the cluster.

2.  **Loki (Standalone `StatefulSet`):**
    *   A dedicated Loki instance is deployed by the script for efficient, centralized log aggregation.
    *   It is automatically configured as a data source within Grafana, providing a single interface for both metrics and logs.

The entire stack is designed to be **idempotent**. You can safely re-run `orchestrator.sh` at any time to ensure the cluster's monitoring state matches your configuration.

---

## The Source of Truth: `monitoring/values.yaml`

Forget manually editing `ConfigMaps` or `Deployments`. The **primary method of configuration** for this monitoring stack is the `homelab/monitoring/values.yaml` file. This file is your single source of truth.

**To change any monitoring configuration, follow this workflow:**

1.  **Edit the File:** Open `homelab/monitoring/values.yaml` and make your desired changes. This includes:
    *   Grafana domain name (`grafana.ingress.hosts`).
    *   Persistence sizes for Prometheus and Grafana.
    *   Component resource requests and limits.
    *   Adding new Grafana dashboards or data sources.

2.  **Apply the Changes:** Re-run the orchestrator script.
    ```bash
    sudo orchestrator.sh
    ```
    The script will use `helm upgrade --install` to intelligently apply only the changes you made, without disrupting the running services.

---

## Monitoring the MySQL Database

To provide visibility into the health and performance of the MySQL database, the `orchestrator.sh` script also deploys the `prometheus-mysql-exporter`.

-   **What it is:** A dedicated exporter that connects to the MySQL instance, queries it for key performance indicators (KPIs), and exposes them as Prometheus metrics.
-   **How it works:**
    1.  It is deployed as a Helm release into the `monitoring` namespace.
    2.  It automatically discovers the `mysql` service in the `database` namespace.
    3.  It securely authenticates using the `mysql-secret` that was created by the `database.sh` script.
    4.  A `ServiceMonitor` is created, which tells the main Prometheus instance to automatically start scraping metrics from this exporter.

This integration means that as soon as you deploy the database and run the orchestrator script, you can start building dashboards in Grafana to monitor query performance, connection counts, and other critical database metrics.

---

## Accessing Services

### Grafana Web Interface

Grafana is the main entrypoint for viewing your cluster's health.

-   **URL:** Configured in `monitoring/values.yaml`. By default: `https://monitoring.drewroberts.com`
-   **Username:** `admin`
-   **Password:** A secure, random password is **automatically generated** during the first run of `orchestrator.sh`.

**To retrieve the Grafana admin password:**

```bash
# The password will be in the output of this command
kubectl get secret grafana-credentials -n monitoring -o jsonpath="{.data.admin-password}" | base64 --decode
```

### Direct Service Access (for Debugging)

For advanced debugging, you can access services directly using `kubectl port-forward`.

```bash
# Grafana (port 3000)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Prometheus (port 9090)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Loki (port 3100)
kubectl port-forward -n monitoring svc/loki 3100:3100
```

---

## Management and Troubleshooting

While most configuration is handled by `values.yaml`, these `kubectl` commands are useful for observing the health and status of the stack.

### Check Pod Health

```bash
# View all monitoring pods
kubectl get pods -n monitoring

# Check the status of the Helm-managed components
kubectl get pods -n monitoring -l app.kubernetes.io/instance=prometheus

# Check the status of the standalone Loki pod
kubectl get pods -n monitoring -l app=loki

# Check the monitoring agents running on all nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=node-exporter -o wide
```

### View Logs

```bash
# View logs for a specific component (e.g., Grafana)
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -f

# View logs for the standalone Loki instance
kubectl logs -n monitoring -l app=loki -f

# View logs for the node-exporter agent on a specific node
kubectl logs -n monitoring <node-exporter-pod-name> -f
```

### Backup Strategy

Your backup strategy is now simpler and more robust.

1.  **Configuration Backup:** Your `monitoring/values.yaml` file, stored in Git, **is your configuration backup**. This is the most critical file to version control.

2.  **Data Backup (Optional):** If you need to back up the collected metric and log data, you can use standard Kubernetes volume snapshotting techniques or manually copy the data from the persistent volumes.

    ```bash
    # Example: Manually backing up the Prometheus data
    # 1. Find the prometheus pod name
    PROMETHEUS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')

    # 2. Create a tarball inside the container
    kubectl exec -n monitoring $PROMETHEUS_POD -- tar czf /tmp/prometheus-backup.tar.gz /prometheus

    # 3. Copy the backup to your local machine
    kubectl cp monitoring/$PROMETHEUS_POD:/tmp/prometheus-backup.tar.gz ./prometheus-backup.tar.gz
    ```

---

## Recommended Grafana Dashboards

The `kube-prometheus-stack` comes with several pre-built dashboards. You can also easily import community dashboards.

**Recommended Community Dashboards:**
-   **Node Exporter Full** (Dashboard ID: `1860`): Comprehensive host metrics (CPU, RAM, disk, network).
-   **Kubernetes Cluster Monitoring** (Dashboard ID: `315`): Cluster-wide resource allocation and pod health.

**To Import a Dashboard:**
1.  Log in to your Grafana instance.
2.  Navigate to the **Dashboards** section.
3.  Click **New** -> **Import**.
4.  Enter the dashboard ID and click **Load**.
5.  Select your Prometheus data source and click **Import**.
