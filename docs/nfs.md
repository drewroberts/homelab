# Setting Up NFS for Persistent Storage in Your K3s Homelab

This document provides a comprehensive guide to configuring Network File System (NFS) as the persistent storage backend for your Kubernetes cluster.

---

## Understanding Persistent Storage in Kubernetes

In Kubernetes, pods are ephemeral. If a pod crashes or is rescheduled, any data saved inside its container is lost. To save data permanently, you need **Persistent Storage**. This is achieved through three main concepts:

1.  **`PersistentVolume` (PV):** A piece of storage in the cluster that has been provisioned by an administrator. It's a resource in the cluster, just like a CPU or RAM.
2.  **`PersistentVolumeClaim` (PVC):** A request for storage by a user. It's similar to a pod requesting CPU or memory. An application will request a certain size of storage with specific access modes (e.g., `ReadWriteOnce`).
3.  **`StorageClass`:** This is the crucial link that enables **dynamic provisioning**. A `StorageClass` defines a "class" of storage (e.g., "fast-ssd" or "slow-hdd"). When a PVC is created requesting a specific `StorageClass`, a provisioner automatically creates a matching `PersistentVolume`.

Our homelab setup relies on a `StorageClass` named `nfs-client`.

## Why NFS?

For a homelab, NFS is an ideal choice for shared storage because it is:
- **Simple:** Most NAS devices and Linux servers support NFS out of the box.
- **Shared:** It provides `ReadWriteMany` access, meaning multiple pods can read from and write to the same volume simultaneously. This is useful for certain types of applications.
- **Stateless:** The NFS server is independent of your Kubernetes cluster. If your cluster goes down, your data remains safe on the NFS server.

## Recommended Provisioner: `nfs-subdir-external-provisioner`

While you could manually create a `PersistentVolume` for every application, this is tedious and not scalable. We strongly recommend using a dynamic provisioner.

The **`nfs-subdir-external-provisioner`** is the perfect choice for this homelab.

- **How it Works:** You point it at a single, large NFS export on your server. Whenever a PVC is requested in Kubernetes, this provisioner automatically creates a new subdirectory within that single share (e.g., `pvc-a1b2-c3d4-e5f6`).
- **Benefits:** This is incredibly efficient. You don't need to manage dozens of different NFS exports; you only need one. It keeps your NFS server configuration clean and your Kubernetes storage management fully automated.

---

## Installation Guide: `nfs-subdir-external-provisioner`

Follow these steps **after** you have successfully run `orchestrator.sh` and have `kubectl` access.

### Step 1: Prepare Your NFS Server

Before you touch Kubernetes, ensure your NFS server is ready.
1.  Install the necessary NFS server packages (e.g., `nfs-utils` on Arch/Debian).
2.  Create a directory that you will share. For example: `sudo mkdir -p /srv/nfs/k3s`.
3.  Set the permissions correctly. `sudo chown -R nobody:nogroup /srv/nfs/k3s` and `sudo chmod -R 777 /srv/nfs/k3s`.
4.  Export the directory by editing `/etc/exports`. Add a line like this, replacing the IP range with your local network's range:
    ```
    /srv/nfs/k3s    192.168.1.0/24(rw,sync,no_subtree_check)
    ```
5.  Apply the changes: `sudo exportfs -a` and restart the NFS server daemon (`sudo systemctl restart nfs-server.service`).

### Step 2: Add the Helm Repository

On your orchestrator node, add the Helm repository that contains the provisioner chart.
```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update
```

### Step 3: Install the Provisioner with Helm

This is the most critical step. You will install the provisioner using Helm, providing it with your NFS server's details.

**Find your NFS Server IP and Path:**
- `NFS_SERVER_IP`: The IP address of your NFS server (e.g., `192.168.1.50`).
- `NFS_PATH`: The exported directory path from Step 1 (e.g., `/srv/nfs/k3s`).

Now, run the `helm install` command, replacing the placeholder values.

```bash
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace default \
    --set nfs.server=YOUR_NFS_SERVER_IP \
    --set nfs.path=/YOUR_NFS_EXPORT_PATH \
    --set storageClass.name=nfs-client \
    --set storageClass.onDelete=delete
```

**Example:**
```bash
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace default \
    --set nfs.server=192.168.1.50 \
    --set nfs.path=/srv/nfs/k3s \
    --set storageClass.name=nfs-client \
    --set storageClass.onDelete=delete
```

### Step 4: Verify the Installation

Check that the `StorageClass` has been successfully created.
```bash
kubectl get sc
```

You should see `nfs-client` in the output.

```
NAME         PROVISIONER                                     RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
nfs-client   cluster.local/nfs-subdir-external-provisioner   Delete          Immediate           true                   ...
```

Your cluster is now ready to dynamically provision persistent storage for any application that requests the `nfs-client` `StorageClass`. The monitoring stack and database script will now work correctly.