# Database Backup Strategy

This guide details how to implement an automated, "set-it-and-forget-it" backup system for your MySQL database. We will use a Kubernetes **CronJob** to dump the database nightly and upload it to a **Google Cloud Storage (GCS)** bucket.

## Architecture

- **Frequency**: Nightly (e.g., 3:00 AM).
- **Method**: `mysqldump` piped to `gzip`.
- **Destination**: Google Cloud Storage (Standard or Archive class).
- **Retention**: Managed automatically by GCS Lifecycle Rules (e.g., keep 7 days).
- **Cost**: Extremely low (often within the GCP Free Tier for small databases).

---

## Step 1: Google Cloud Platform (GCP) Setup

### 1. Create a Storage Bucket
1. Go to the [Google Cloud Console](https://console.cloud.google.com/storage/browser).
2. Create a new bucket (e.g., `homelab-backups-drew`).
3. Choose a region close to you (e.g., `us-central1`).
4. **Storage Class**: "Standard" is fine, or "Archive" for long-term cold storage.

### 2. Configure Retention (Lifecycle Rules)
Don't write scripts to delete old backups. Let Google do it.
1. Click on your bucket name.
2. Go to the **Lifecycle** tab.
3. Click **Add a rule**.
4. **Select action**: "Delete object".
5. **Select object conditions**:
   - **Age**: `7` days (or `30` days, depending on your preference).
6. Click **Create**.

### 3. Create a Service Account
We need a "robot account" that only has permission to write to this bucket.
1. Go to **IAM & Admin** > **Service Accounts**.
2. Click **Create Service Account**.
   - Name: `homelab-backup-uploader`.
3. **Grant this service account access to project**:
   - Role: `Storage Object Creator` (Allows uploading files).
   - Role: `Storage Object Viewer` (Allows listing files to verify).
4. Click **Done**.

### 4. Generate a Key
1. Click on the newly created Service Account.
2. Go to the **Keys** tab.
3. Click **Add Key** > **Create new key**.
4. Select **JSON**.
5. The file will download to your computer (e.g., `project-id-12345.json`). **Keep this safe.**

---

## Step 2: Kubernetes Configuration

### 1. Create the Secret
We need to store the Google Cloud JSON key inside Kubernetes so the CronJob can use it.

Rename your downloaded key to `gcp-key.json` and run:

```bash
# Create the secret in the 'database' namespace
kubectl create secret generic gcp-backup-key \
  --from-file=gcp-key.json=./gcp-key.json \
  --namespace database
```

### 2. Deploy the CronJob
Create a file named `mysql-backup-cronjob.yaml` (or add it to your repo) with the following content.

**Note:** Replace `<YOUR_BUCKET_NAME>` with your actual bucket name.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mysql-backup-to-gcs
  namespace: database
spec:
  schedule: "0 3 * * *" # Runs at 3:00 AM daily
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            # This image contains the 'gcloud' and 'gsutil' tools
            image: google/cloud-sdk:alpine
            command: ["/bin/sh", "-c"]
            args:
            - |
              set -e
              
              echo "1. Installing MySQL client..."
              apk add --no-cache mysql-client

              echo "2. Dumping database..."
              # Connects to the mysql service in the same namespace
              # Uses the root password from the existing secret
              mysqldump -h mysql.database.svc.cluster.local -u root -p$MYSQL_ROOT_PASSWORD --all-databases | gzip > /tmp/backup.sql.gz

              echo "3. Authenticating with Google Cloud..."
              gcloud auth activate-service-account --key-file=/secrets/gcp-key.json

              echo "4. Uploading to GCS..."
              FILENAME="backup-$(date +%Y%m%d-%H%M%S).sql.gz"
              gsutil cp /tmp/backup.sql.gz gs://<YOUR_BUCKET_NAME>/$FILENAME

              echo "Done! Backup uploaded to gs://<YOUR_BUCKET_NAME>/$FILENAME"
            env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: root-password
            volumeMounts:
            - name: gcp-key
              mountPath: /secrets
              readOnly: true
          restartPolicy: OnFailure
          volumes:
          - name: gcp-key
            secret:
              secretName: gcp-backup-key
```

### 3. Apply the CronJob
```bash
kubectl apply -f mysql-backup-cronjob.yaml
```

---

## Step 3: Verification

### Manual Test
You don't have to wait until 3:00 AM to see if it works. You can trigger a job manually:

```bash
# Create a job from the cronjob template
kubectl create job --from=cronjob/mysql-backup-to-gcs manual-backup-test -n database

# Watch the logs
kubectl logs -f job/manual-backup-test -n database
```

If successful, you should see "Done! Backup uploaded..." and the file will appear in your Google Cloud Storage bucket.

### Recovery (How to Restore)
If disaster strikes, here is how to get your data back:

1. Download the `.sql.gz` file from Google Cloud.
2. Copy it to the database pod:
   ```bash
   kubectl cp backup.sql.gz database/mysql-0:/tmp/backup.sql.gz
   ```
3. Exec into the pod and restore:
   ```bash
   kubectl exec -it mysql-0 -n database -- bash
   # Inside the pod:
   zcat /tmp/backup.sql.gz | mysql -u root -p$MYSQL_ROOT_PASSWORD
   ```
