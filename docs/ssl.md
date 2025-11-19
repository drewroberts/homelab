# SSL Certificate Management (Cert-Manager)

We use **cert-manager** to automatically provision and renew SSL certificates from Let's Encrypt. This replaces the legacy method of using Traefik's built-in ACME resolver.

## How it Works

1.  **ClusterIssuer**: A global resource (created by `orchestrator.sh`) that represents your account with Let's Encrypt.
2.  **Ingress Annotation**: When you create an Ingress, you add a specific annotation.
3.  **Automation**: `cert-manager` watches for that annotation, talks to Let's Encrypt, solves the challenge (using Traefik), and stores the resulting certificate in a Kubernetes Secret.

## Usage

To enable SSL for any application, simply add these lines to your `Ingress` manifest:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    # This tells cert-manager to use our production issuer
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - myapp.drewroberts.com
    # cert-manager will create this secret automatically
    secretName: my-app-tls
  rules:
  - host: myapp.drewroberts.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app-service
            port:
              number: 80
```

## Troubleshooting

If your certificate is not being issued:

1.  **Check the Certificate resource:**
    ```bash
    kubectl get certificate -n <namespace>
    kubectl describe certificate <certificate-name> -n <namespace>
    ```

2.  **Check the Order/Challenge:**
    ```bash
    kubectl get orders -n <namespace>
    kubectl describe order <order-name> -n <namespace>
    ```

3.  **Check Cert-Manager logs:**
    ```bash
    kubectl logs -n cert-manager -l app=cert-manager
    ```
