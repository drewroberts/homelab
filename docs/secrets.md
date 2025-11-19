# Secret Management (Sealed Secrets)

In a GitOps workflow, everything must be in Git. But you cannot commit passwords, API keys, or `.env` files to Git.

**Bitnami Sealed Secrets** solves this. It allows you to **encrypt** your secrets into a format that is safe to commit to a public repository.

## Prerequisites

You need the `kubeseal` CLI tool on your local machine (where you write code).

**Arch Linux:**
```bash
yay -S kubeseal
```

**macOS:**
```bash
brew install kubeseal
```

## Workflow: How to Seal a Secret

### 1. Create a "Dry Run" Secret
First, generate the standard Kubernetes Secret YAML locally. **Do not apply it.**

```bash
# Example: Creating a secret from a literal value
kubectl create secret generic my-app-secret \
  --from-literal=DB_PASSWORD=supersecret123 \
  --namespace default \
  --dry-run=client \
  -o yaml > my-secret.yaml
```

### 2. Seal It
Use `kubeseal` to encrypt the file. This fetches the public encryption key from your cluster.

```bash
kubeseal --format=yaml < my-secret.yaml > my-sealed-secret.yaml
```

### 3. Commit to Git
You can now safely delete `my-secret.yaml` (the unencrypted one) and commit `my-sealed-secret.yaml` to your Git repository.

```bash
git add my-sealed-secret.yaml
git commit -m "Add sealed secret for my-app"
git push
```

### 4. Deploy
When ArgoCD syncs this file to the cluster:
1.  The **SealedSecrets Controller** sees the `SealedSecret` resource.
2.  It uses its private key (which only exists inside the cluster) to decrypt it.
3.  It creates a standard `Secret` resource named `my-app-secret`.
4.  Your application mounts `my-app-secret` just like normal.

## Managing Secrets for Multiple Projects (The Fleet Pattern)

In your `fleet` repository, organize secrets alongside the applications they belong to.

```
fleet/
├── apps/
│   ├── laravel-app/
│   │   ├── application.yaml
│   │   └── sealed-secrets.yaml  <-- Encrypted secrets here
│   ├── react-app/
│   │   ├── application.yaml
│   │   └── sealed-secrets.yaml
```

### Updating a Secret
You cannot "edit" a sealed secret directly because it's encrypted. To update a value:
1.  Create a new dry-run secret with the new values.
2.  Run `kubeseal` again to generate a new sealed blob.
3.  Replace the content in your git repo.

### Disaster Recovery
If you delete your cluster, you lose the private key needed to decrypt these secrets.
**CRITICAL:** You must back up the master key from the cluster!

```bash
# Run this once and store the output in a secure password manager (1Password, etc.)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > master-key-backup.yaml
```

To restore on a new cluster:
```bash
kubectl apply -f master-key-backup.yaml
# Then restart the sealed-secrets-controller pod
```
