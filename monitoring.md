# PLG Monitoring Stack for K3s Homelab

This document describes the PLG (Prometheus, Loki, Grafana) monitoring stack automatically installed by the `orchestrator.sh` script and how to manage it in your homelab environment.

## Overview

The PLG stack provides comprehensive observability for your K3s homelab:

- **Prometheus (P)**: Metrics collection and time-series database
- **Loki (L)**: Log aggregation and storage system  
- **Grafana (G)**: Visualization and dashboarding platform

**Additional monitoring agents deployed across all nodes:**
- **Node Exporter**: Host-level metrics collection (CPU, RAM, disk, network)
- **Promtail**: Log shipping agent that sends container and system logs to Loki

All components are deployed in the `monitoring` namespace with persistent storage and automatic SSL certificates via Traefik.

## Service Descriptions

### Prometheus - Metrics Collection

**What it does:**
- Scrapes metrics from Kubernetes nodes, pods, and services
- Stores time-series data with configurable retention (30 days default)
- Provides query language (PromQL) for metric analysis
- Serves as data source for Grafana dashboards

**Key Features:**
- **Service Discovery**: Automatically finds and monitors K3s components
- **Resource Metrics**: CPU, memory, disk, network usage across cluster
- **Application Metrics**: Custom metrics from your deployed applications
- **Alerting**: Foundation for alert rules (when integrated with AlertManager)

**Storage Requirements:**
- 50GB persistent volume for metric data
- Retention period: 30 days (configurable)
- Resource usage: 1-2GB RAM, 0.5-1 CPU core

**Access Methods:**
```bash
# Internal cluster access
kubectl port-forward -n monitoring svc/prometheus-service 9090:9090

# Direct service URL (from within cluster)
http://prometheus-service.monitoring.svc.cluster.local:9090
```

### Loki - Log Aggregation

**What it does:**
- Collects logs from all pods and containers in your cluster
- Indexes logs by metadata (not content) for efficient storage
- Provides LogQL query language for log searches and analysis
- Integrates with Grafana for unified metrics and logs view

**Key Features:**
- **Lightweight**: Only indexes metadata, not log content
- **Kubernetes Native**: Automatically discovers and labels log sources
- **Structured Logging**: Handles JSON logs and key-value pairs
- **Time Correlation**: Links logs with metrics by timestamp

**Storage Requirements:**
- 100GB persistent volume for log data
- Configurable retention (7 days default in config)
- Resource usage: 0.5-1GB RAM, 0.25-0.5 CPU core

**Access Methods:**
```bash
# Internal cluster access
kubectl port-forward -n monitoring svc/loki-service 3100:3100

# Direct service URL (from within cluster)  
http://loki-service.monitoring.svc.cluster.local:3100
```

### Node Exporter - Host Metrics Collection

**What it does:**
- Runs as DaemonSet on every worker node in your cluster
- Collects operating system and hardware metrics directly from Arch Linux
- Exposes metrics in Prometheus format for scraping
- Provides foundation for infrastructure monitoring dashboards

**Key Features:**
- **System Metrics**: CPU usage, load average, memory utilization
- **Disk Metrics**: Disk I/O, filesystem usage, mount point monitoring  
- **Network Metrics**: Interface statistics, bandwidth utilization
- **Hardware Monitoring**: Temperature, fan speeds (where available)

**Deployment Details:**
- **Image**: `prom/node-exporter:latest`
- **Port**: 9100 (exposed on host network)
- **Resources**: 64-128Mi RAM, 50-100m CPU
- **Access**: Host filesystem mounted read-only for metrics collection

**Access Methods:**
```bash
# Check metrics from any node
curl http://NODE_IP:9100/metrics

# View Node Exporter pods
kubectl get pods -n monitoring -l app=node-exporter
```

### Promtail - Log Collection Agent

**What it does:**
- Runs as DaemonSet on every node to collect logs
- Automatically discovers and ships container logs to Loki
- Handles Kubernetes metadata enrichment and log parsing
- Provides real-time log streaming with proper labeling

**Key Features:**
- **Container Logs**: Automatic collection from all pods
- **System Logs**: Access to host system logs when configured
- **Kubernetes Integration**: Automatic service discovery and labeling
- **Efficient Shipping**: Compressed log streaming to reduce network overhead

**Deployment Details:**
- **Image**: `grafana/promtail:latest`
- **Port**: 3101 (metrics endpoint)
- **Resources**: 128-256Mi RAM, 50-100m CPU
- **RBAC**: ClusterRole permissions for pod/node discovery

**Access Methods:**
```bash
# View Promtail pods and logs
kubectl get pods -n monitoring -l app=promtail
kubectl logs -n monitoring -l app=promtail -f

# Check Promtail metrics
kubectl port-forward -n monitoring ds/promtail 3101:3101
curl http://localhost:3101/metrics
```

### Grafana - Visualization Dashboard

**What it does:**
- Creates visual dashboards from Prometheus metrics and Loki logs
- Provides web interface for monitoring cluster health
- Supports alerting and notification integrations
- Offers pre-built dashboards for Kubernetes monitoring

**Key Features:**
- **Web Interface**: Browser-based dashboard management
- **Data Source Integration**: Connects to Prometheus and Loki automatically
- **Custom Dashboards**: Create dashboards for your specific applications
- **User Management**: Multi-user support with role-based access
- **Alerting**: Visual alerts and notification channels

**Storage Requirements:**
- 10GB persistent volume for dashboard configurations
- Resource usage: 0.5-1GB RAM, 0.25-0.5 CPU core

**Web Access:**
- **URL**: `https://monitoring.drewroberts.com` (update domain in ingress)
- **Username**: `admin`  
- **Password**: `homelab123`
- **SSL**: Automatic Let's Encrypt certificate via Traefik

## Management Tasks

### Accessing the Services

#### Grafana Web Interface:
```bash
# Update the domain in the ingress first
kubectl edit ingress grafana-ingress -n monitoring

# Then access via browser at your configured domain
https://monitoring.drewroberts.com
```

#### Port Forwarding for Local Access:
```bash
# Grafana (port 3000)
kubectl port-forward -n monitoring svc/grafana-service 3000:3000

# Prometheus (port 9090)  
kubectl port-forward -n monitoring svc/prometheus-service 9090:9090

# Loki (port 3100)
kubectl port-forward -n monitoring svc/loki-service 3100:3100
```

### Monitoring Stack Status

#### Check Pod Health:
```bash
# View all monitoring pods
kubectl get pods -n monitoring

# Check specific service status
kubectl get pods -n monitoring -l app=prometheus
kubectl get pods -n monitoring -l app=loki  
kubectl get pods -n monitoring -l app=grafana

# Check monitoring agents across all nodes
kubectl get pods -n monitoring -l app=node-exporter -o wide
kubectl get pods -n monitoring -l app=promtail -o wide

# View detailed pod information
kubectl describe pod -n monitoring <pod-name>

# Check DaemonSet status
kubectl get daemonsets -n monitoring
```

#### Check Storage Usage:
```bash
# View persistent volume claims
kubectl get pvc -n monitoring

# Check storage usage
kubectl exec -n monitoring <prometheus-pod> -- df -h /prometheus
kubectl exec -n monitoring <loki-pod> -- df -h /loki
kubectl exec -n monitoring <grafana-pod> -- df -h /var/lib/grafana
```

#### View Logs:
```bash
# Service logs
kubectl logs -n monitoring -l app=prometheus -f
kubectl logs -n monitoring -l app=loki -f
kubectl logs -n monitoring -l app=grafana -f

# Monitoring agent logs
kubectl logs -n monitoring -l app=node-exporter -f
kubectl logs -n monitoring -l app=promtail -f

# Previous container logs (if pod restarted)
kubectl logs -n monitoring <pod-name> --previous
```

### Configuration Management

#### Prometheus Configuration:
```bash
# View current config
kubectl get configmap prometheus-config -n monitoring -o yaml

# Edit scrape targets and retention
kubectl edit configmap prometheus-config -n monitoring

# Restart to apply changes
kubectl rollout restart statefulset/prometheus -n monitoring
```

#### Loki Configuration:
```bash
# View current config  
kubectl get configmap loki-config -n monitoring -o yaml

# Edit retention and storage settings
kubectl edit configmap loki-config -n monitoring

# Restart to apply changes
kubectl rollout restart statefulset/loki -n monitoring
```

#### Grafana Password Reset:
```bash
# Update admin password
kubectl patch deployment grafana -n monitoring -p '{"spec":{"template":{"spec":{"containers":[{"name":"grafana","env":[{"name":"GF_SECURITY_ADMIN_PASSWORD","value":"new-password"}]}]}}}}'

# Or edit directly
kubectl edit deployment grafana -n monitoring
```

### Scaling and Resources

#### Scale Services:
```bash
# Grafana (can be scaled horizontally)
kubectl scale deployment grafana -n monitoring --replicas=2

# Prometheus and Loki (StatefulSets - be careful with scaling)
kubectl scale statefulset prometheus -n monitoring --replicas=1
kubectl scale statefulset loki -n monitoring --replicas=1
```

#### Update Resource Limits:
```bash
# Edit resource requests/limits
kubectl edit statefulset prometheus -n monitoring
kubectl edit statefulset loki -n monitoring  
kubectl edit deployment grafana -n monitoring
```

### Backup and Maintenance

#### Backup Configurations:
```bash
# Export all monitoring configurations
kubectl get all,configmaps,secrets,pvc,ingress -n monitoring -o yaml > monitoring-backup.yaml

# Backup specific configs
kubectl get configmap prometheus-config -n monitoring -o yaml > prometheus-config-backup.yaml
kubectl get configmap loki-config -n monitoring -o yaml > loki-config-backup.yaml
```

#### Data Backup:
```bash
# Create volume snapshots (if supported by storage class)
kubectl create volumesnapshot prometheus-snapshot --source=prometheus-storage-prometheus-0 -n monitoring

# Or manually backup data directories
kubectl exec -n monitoring prometheus-0 -- tar czf /tmp/prometheus-backup.tar.gz /prometheus
kubectl cp monitoring/prometheus-0:/tmp/prometheus-backup.tar.gz ./prometheus-backup.tar.gz
```

### Troubleshooting

#### Common Issues:

**Prometheus not scraping targets:**
```bash
# Check service discovery
kubectl logs -n monitoring -l app=prometheus | grep "discovery"

# Verify RBAC permissions
kubectl auth can-i get nodes --as=system:serviceaccount:monitoring:default
```

**Node Exporter not providing metrics:**
```bash
# Check Node Exporter pods on all nodes
kubectl get pods -n monitoring -l app=node-exporter -o wide

# Test metrics endpoint directly
curl http://NODE_IP:9100/metrics | head -20

# Check if Prometheus is discovering Node Exporter targets
kubectl port-forward -n monitoring svc/prometheus-service 9090:9090
# Then visit http://localhost:9090/targets
```

**Promtail not shipping logs:**
```bash
# Check Promtail pods on all nodes
kubectl get pods -n monitoring -l app=promtail -o wide

# Check Promtail configuration
kubectl get configmap promtail-config -n monitoring -o yaml

# Test Promtail metrics endpoint
kubectl port-forward -n monitoring ds/promtail 3101:3101
curl http://localhost:3101/metrics

# Verify Loki API connectivity
kubectl exec -n monitoring <promtail-pod> -- wget -qO- http://loki-service.monitoring.svc.cluster.local:3100/ready
```

**Grafana data source connection issues:**
```bash
# Check internal service connectivity
kubectl exec -n monitoring <grafana-pod> -- nslookup prometheus-service.monitoring.svc.cluster.local
kubectl exec -n monitoring <grafana-pod> -- wget -qO- http://prometheus-service:9090/api/v1/status/config
```

#### Performance Tuning:

**High Memory Usage:**
- Reduce Prometheus retention period
- Adjust query timeout settings
- Increase resource limits if needed

**Slow Queries:**
- Review PromQL query efficiency  
- Add recording rules for frequent calculations
- Consider metric federation for large clusters

**Storage Growth:**
- Monitor retention settings
- Implement log rotation policies
- Archive old metrics/logs to external storage

## Integration with Applications

### Exposing Application Metrics:
```yaml
# Add to your application deployment
apiVersion: v1
kind: Service
metadata:
  name: myapp-metrics
  labels:
    app: myapp
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
```

### Recommended Grafana Dashboards:

#### Import Community Dashboards:
1. **Node Exporter Full** (Dashboard ID: 1860)
   - Comprehensive host metrics visualization
   - CPU, memory, disk, network overview per node

2. **Kubernetes Cluster Monitoring** (Dashboard ID: 315)
   - Pod and container resource usage
   - Cluster-wide resource allocation

3. **Loki Logs Dashboard** (Dashboard ID: 13639)
   - Log volume and error rate tracking
   - Integration with Prometheus metrics

#### Import Process:
```bash
# Access Grafana at https://monitoring.drewroberts.com
# Login: admin / homelab123
# Go to: + → Import → Enter dashboard ID
```

### Monitoring Agent Management:

#### Restart Monitoring Agents:
```bash
# Restart Node Exporter on all nodes
kubectl rollout restart daemonset/node-exporter -n monitoring

# Restart Promtail on all nodes  
kubectl rollout restart daemonset/promtail -n monitoring

# Check rollout status
kubectl rollout status daemonset/node-exporter -n monitoring
kubectl rollout status daemonset/promtail -n monitoring
```

#### Update Agent Configuration:
```bash
# Update Promtail configuration
kubectl edit configmap promtail-config -n monitoring

# Restart to apply changes
kubectl rollout restart daemonset/promtail -n monitoring
```

#### Scale Monitoring Services:
```bash
# Node Exporter and Promtail automatically scale with cluster nodes
# No manual scaling needed - DaemonSets ensure one pod per node

# Scale core monitoring services
kubectl scale statefulset prometheus -n monitoring --replicas=1
kubectl scale deployment grafana -n monitoring --replicas=2
```

This monitoring stack provides comprehensive visibility into your homelab's health, performance, and logs at both the infrastructure and application level, enabling proactive maintenance and troubleshooting across your entire K3s cluster.