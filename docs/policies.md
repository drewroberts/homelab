# Network Policies & Security Hardening

This document outlines the "Zero Trust" network security strategy implemented in the homelab cluster. By default, Kubernetes allows all pods to communicate with each other. We have inverted this to a **Default Deny** model, where traffic is blocked unless explicitly allowed.

## Strategy: Zero Trust

We use `NetworkPolicy` resources to define firewall rules at the pod level. This ensures that if one service is compromised, the attacker cannot easily move laterally to other services (e.g., from a web server to a database) without explicit permission.

## Policy Manifests

The policies are located in the `policies/` directory. Here is a breakdown of each policy and its function:

### 1. The Firewall: `default-deny-all.yaml`
**Critical.** This policy selects **all pods** in the namespace and blocks all Ingress (incoming) and Egress (outgoing) traffic.
- **Effect:** Once applied, a pod cannot talk to anything, and nothing can talk to it.
- **Purpose:** Establishes the secure baseline. All other policies are "allow" rules that punch holes in this firewall.

### 2. The Plumbing: `allow-dns.yaml`
**Essential.** DNS is required for almost every service to function (to resolve `google.com` or `postgres.default.svc`).
- **Rule:** Allows all pods to send UDP/TCP traffic to the CoreDNS service in the `kube-system` namespace on port 53.
- **Without this:** Pods will fail to resolve hostnames, causing crash loops.

### 3. Internal Traffic: `allow-intra-namespace.yaml`
**Convenience.** This allows pods *within the same namespace* to talk to each other.
- **Rule:** Ingress is allowed from any pod that shares the same namespace.
- **Use Case:** A web frontend talking to a redis cache in the same `default` namespace.
- **Security Note:** If you want stricter isolation (e.g., preventing the frontend from talking to a worker pod), you can remove this and create specific point-to-point rules.

### 4. Ingress Access: `allow-traefik.yaml`
**Connectivity.** Allows the Ingress Controller (Traefik) to forward traffic to your applications.
- **Rule:** Allows Ingress traffic from pods labeled `app.kubernetes.io/name: traefik` in the `kube-system` namespace (or wherever Traefik runs).
- **Ports:** Typically allows traffic on 80/443/8080 depending on the container.
- **Requirement:** Your application pods must accept traffic from the Traefik load balancer.

### 5. Observability: `allow-monitoring.yaml`
**Metrics.** Allows Prometheus to scrape metrics from your pods.
- **Rule:** Allows Ingress traffic from the Prometheus monitoring stack.
- **Requirement:** Ensures your dashboards stay green without exposing metrics ports to the public internet.

## Deployment & Management

### Automated Enforcement
The `orchestrator.sh` script automatically enforces these policies. When you run the script, it:
1.  Copies the contents of the `policies/` directory to `/var/lib/rancher/k3s/policies` on the node.
2.  Applies them to the cluster using `kubectl apply`.

This ensures that your cluster always matches the security posture defined in this repository.

### Modifying Policies
To change the security rules (e.g., to allow a new port or service):
1.  **Edit** the YAML files in the `policies/` directory of this repository.
2.  **Commit** your changes to Git.
3.  **Apply** the changes to the cluster:
    *   **Option A (Full Sync):** Run `sudo ./orchestrator.sh` on the node.
    *   **Option B (Manual):** Run `kubectl apply -f policies/` from your terminal.

### Manual Deployment
If you are not using the orchestrator script, you can apply the policies manually:

```bash
# Apply all policies
kubectl apply -f policies/
```

**Note:** Network Policies are namespaced. The provided files typically target the `default` namespace. If you create a new namespace (e.g., `media`), you must re-apply these policies to that namespace or use a tool like Kyverno to enforce them globally.

## Considerations & Troubleshooting

### "My app stopped working after applying policies"
1.  **Check Labels:** Network Policies rely heavily on labels. Ensure your selectors match the actual labels on your pods.
2.  **Check DNS:** Can the pod resolve names? `kubectl exec -it <pod> -- nslookup google.com`.
3.  **Check Egress:** If your app needs to download something from the internet (e.g., an API call), the `default-deny-all` blocks Egress. You may need to create a specific `allow-internet-egress` policy for that specific app.

### Whitelisting a New Service
If you add a new database that needs to be accessed by a specific app:
1.  Create a new `NetworkPolicy`.
2.  **podSelector:** Target the Database pod.
3.  **Ingress:** Allow from `podSelector` matching the App pod.

### Egress to Internet
By default, Egress is blocked. To allow a specific pod to access the internet (e.g., a download client):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internet
spec:
  podSelector:
    matchLabels:
      app: my-downloader
  policyTypes: [Egress]
  egress:
  - {} # Empty rule allows all egress
```
