# k8s-etcd-backup-restore

## Project Description

The `etcd-backup.sh` script is a robust Bash utility designed to automate backups of etcd, a distributed key-value store commonly used in Kubernetes clusters. It supports backing up etcd snapshots to local storage or cloud storage providers (AWS S3, Google Cloud Storage, and Azure Blob Storage). The script offers both interactive and configuration file-based modes, making it flexible for one-off backups or scheduled automation. It includes validation of settings, dependency checks, and detailed logging, ensuring reliability and ease of use in production environments.

## Features

| Feature | Description | Supported |
|---------|-------------|-----------|
| Local Storage Backup | Save etcd snapshots to a local directory | ✅ |
| Cloud Storage Backup | Upload snapshots to AWS S3, GCS, or Azure Blob Storage | ✅ |
| Interactive Mode | Configure backups via user prompts | ✅ |
| Config File Mode | Read settings from a configuration file for automation | ✅ |
| Multiple Backup Configurations | Process multiple backup targets in a single config file | ✅ |
| Input Validation | Validate configuration settings and credentials | ✅ |
| Dependency Checks | Ensure required tools are installed | ✅ |
| Logging | Detailed logs for debugging and monitoring | ✅ |
| Automatic Cleanup | Delete local backups older than 7 days | ✅ |
| Secure File Handling | Restrict permissions on config files and directories | ✅ |
| Cronjob Support | Suitable for scheduled backups | ✅ |

## Dependencies

The script requires the following tools to be installed on the system:

- **etcdctl**: For taking etcd snapshots (ensure `ETCDCTL_API=3`).
- **stat**: For file metadata (part of coreutils).
- **tee**: For logging output.
- **find**: For cleanup of old backups.
- **sort**, **tail**, **awk**: For text processing.
- **kubectl**: For Kubernetes cluster connectivity checks.
- **yq**: YAML parser (version 4.x required).
- **df**: For disk space checks.
- **Cloud CLI Tools** (for cloud storage):
  - **aws**: AWS CLI for S3 backups.
  - **gsutil**: Google Cloud SDK for GCS backups.
  - **az**: Azure CLI for Azure Blob Storage backups.

### Installation Instructions

1. Install core dependencies (on Ubuntu/Debian):
   ```bash
   sudo apt-get update
   sudo apt-get install -y etcd-client coreutils findutils sort awk kubectl
   ```
2. Install `yq` (version 4.x):
   ```bash
   sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
   sudo chmod +x /usr/local/bin/yq
   ```
3. Install cloud CLI tools (if using cloud storage):
   - AWS CLI:
     ```bash
     sudo apt-get install -y awscli
     ```
   - Google Cloud SDK:
     ```bash
     sudo snap install google-cloud-sdk --classic
     ```
   - Azure CLI:
     ```bash
     curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
     ```

## Usage

The script supports two modes: **interactive** and **config file-based**. Below are instructions for both, including configuration samples and expected output.

### 1. Interactive Mode

Run the script without arguments to enter interactive mode, where you are prompted to configure backup settings.

#### Command
```bash
./etcd-backup.sh
```

#### Prompts
You will be prompted for:
- Storage type (`local` or `cloud`).
- Cloud provider (if `cloud`: `s3`, `gcs`, or `azure`).
- Cloud-specific settings (e.g., bucket name, credentials).
- Local backup folder (if `local`).
- etcd endpoints and certificate paths.

#### Example Interaction
```bash
📂 Use local or cloud storage? (local/cloud) [local]: local
📁 Enter backup folder path [/opt/etcd-backup]: /opt/etcd-backup
🔗 Enter ETCD endpoints [https://127.0.0.1:2379]: https://127.0.0.1:2379
🔒 Enter path to CA cert [/etc/kubernetes/pki/etcd/ca.crt]: /etc/kubernetes/pki/etcd/ca.crt
🔒 Enter path to server cert [/etc/kubernetes/pki/etcd/server.crt]: /etc/kubernetes/pki/etcd/server.crt
🔒 Enter path to server key [/etc/kubernetes/pki/etcd/server.key]: /etc/kubernetes/pki/etcd/server.key
```

#### Expected Output
Logs are written to `/var/log/etcd-backup.log`. Example output:
```
2025-05-16 17:10:00 - 🚀 Script started
2025-05-16 17:10:00 - 🖥️ Running in interactive mode
2025-05-16 17:10:00 - User set STORAGE_TYPE to 'local'
2025-05-16 17:10:00 - User set ETCD_BACKUP_FOLDER to '/opt/etcd-backup'
2025-05-16 17:10:00 - User set ETCD_ENDPOINTS to 'https://127.0.0.1:2379'
2025-05-16 17:10:00 - User set ETCD_CACERT to a value (hidden)
2025-05-16 17:10:00 - User set ETCD_CERT to a value (hidden)
2025-05-16 17:10:00 - User set ETCD_KEY to a value (hidden)
2025-05-16 17:10:00 - 🔄 Starting ETCD backup...
2025-05-16 17:10:00 - 📂 Local Backup Metadata:
2025-05-16 17:10:00 - File: /opt/etcd-backup/etcd-backup-20250516-171000.db | Size: 123456 bytes | Modified: 2025-05-16 17:10:00
2025-05-16 17:10:00 - 🗑️ Deleted local backups older than 7 days
2025-05-16 17:10:00 - ✅ Backup completed
2025-05-16 17:10:00 - 🏁 Script finished
```

### 2. Config File Mode

Run the script with a configuration file to automate backups, ideal for cronjobs. The config file specifies one or more backup configurations, each in a block separated by blank lines.

#### Command
```bash
./etcd-backup.sh etcd-conf.conf
```

#### Configuration File Format
The config file contains key-value pairs in `KEY=VALUE` format. Each block represents a backup target (local or cloud). Blocks are separated by blank lines or comments.

##### Sample Configuration: Local Storage
```bash
# Local backup configuration
STORAGE_TYPE=local
ETCD_BACKUP_FOLDER=/opt/etcd-backup
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
```

##### Sample Configuration: AWS S3
```bash
# S3 backup configuration
STORAGE_TYPE=cloud
CLOUD_PROVIDER=s3
S3_BUCKET=my-etcd-backup-bucket
S3_FOLDER=etcd-backups
AWS_PROFILE=default
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
```

##### Sample Configuration: Google Cloud Storage
```bash
# GCS backup configuration
STORAGE_TYPE=cloud
CLOUD_PROVIDER=gcs
GCS_BUCKET=my-etcd-backup-bucket
GCS_FOLDER=etcd-backups
GCS_CREDENTIALS=/path/to/gcs-service-account.json
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
```

##### Sample Configuration: Azure Blob Storage
```bash
# Azure backup configuration
STORAGE_TYPE=cloud
CLOUD_PROVIDER=azure
AZURE_STORAGE_ACCOUNT=myetcdstorage
AZURE_CONTAINER=etcd-backups
AZURE_STORAGE_ACCOUNT_KEY=your_storage_account_key
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
```

##### Combined Config File Example
To back up to both local and S3:
```bash
# Block 1: Local backup
STORAGE_TYPE=local
ETCD_BACKUP_FOLDER=/opt/etcd-backup
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key

# Block 2: S3 backup
STORAGE_TYPE=cloud
CLOUD_PROVIDER=s3
S3_BUCKET=my-etcd-backup-bucket
S3_FOLDER=etcd-backups
AWS_PROFILE=default
ETCD_ENDPOINTS=https://127.0.0.1:2379
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
```

#### Expected Output
Logs are written to `/var/log/etcd-backup.log`. Example output for the combined config:
```
2025-05-16 17:15:00 - 🚀 Script started
2025-05-16 17:15:00 - 📄 Using configuration file: etcd-conf.conf
2025-05-16 17:15:00 - 🔍 Found 2 backup configurations
2025-05-16 17:15:00 - 📋 Processing backup configuration 1
2025-05-16 17:15:00 - Storage type set to 'local'
2025-05-16 17:15:00 - ETCD backup folder set to '/opt/etcd-backup'
2025-05-16 17:15:00 - ETCD endpoints set to 'https://127.0.0.1:2379'
2025-05-16 17:15:00 - ETCD CA cert set to a value (hidden)
2025-05-16 17:15:00 - ETCD cert set to a value (hidden)
2025-05-16 17:15:00 - ETCD key set to a value (hidden)
2025-05-16 17:15:00 - 🔄 Starting ETCD backup...
2025-05-16 17:15:00 - 📂 Local Backup Metadata:
2025-05-16 17:15:00 - File: /opt/etcd-backup/etcd-backup-20250516-171500.db | Size: 123456 bytes | Modified: 2025-05-16 17:15:00
2025-05-16 17:15:00 - 🗑️ Deleted local backups older than 7 days
2025-05-16 17:15:00 - ✅ Backup completed
2025-05-16 17:15:00 - 📋 Processing backup configuration 2
2025-05-16 17:15:00 - Storage type set to 'cloud'
2025-05-16 17:15:00 - Cloud provider set to 's3'
2025-05-16 17:15:00 - S3 bucket set to 'my-etcd-backup-bucket'
2025-05-16 17:15:00 - S3 folder set to 'etcd-backups'
2025-05-16 17:15:00 - AWS profile set to a value (hidden)
2025-05-16 17:15:00 - 🔐 Validating cloud credentials...
2025-05-16 17:15:00 - ✅ AWS credentials validated
2025-05-16 17:15:00 - 📂 Checking if cloud path exists...
2025-05-16 17:15:00 - ✅ S3 path s3://my-etcd-backup-bucket/etcd-backups/ exists
2025-05-16 17:15:00 - 🔄 Starting ETCD backup...
2025-05-16 17:15:00 - 📤 Uploading /tmp/etcd-backup-123-2/etcd-backup-20250516-171500.db to s3://my-etcd-backup-bucket/etcd-backups/etcd-backup-20250516-171500.db
2025-05-16 17:15:00 - ☁️ S3 Backup Metadata for: s3://my-etcd-backup-bucket/etcd-backups/etcd-backup-20250516-171500.db
2025-05-16 17:15:00 - ✅ Backup completed
2025-05-16 17:15:00 - ✅ All backup configurations processed
2025-05-16 17:15:00 - 🏁 Script finished
```

### Setting Up a Cronjob for Config Mode

To schedule automated backups using config mode, set up a cronjob to run `etcd-backup.sh` with a configuration file.

#### Instructions
1. **Prepare the Script and Config File**:
   - Place `etcd-backup.sh` in a secure location, e.g., `/usr/local/bin/`.
     ```bash
     sudo mv etcd-backup.sh /usr/local/bin/etcd-backup.sh
     sudo chmod +x /usr/local/bin/etcd-backup.sh
     ```
   - Place `etcd-conf.conf` in a secure location, e.g., `/etc/etcd-backup/`.
     ```bash
     sudo mkdir -p /etc/etcd-backup
     sudo mv etcd-conf.conf /etc/etcd-backup/etcd-conf.conf
     sudo chmod 600 /etc/etcd-backup/etcd-conf.conf
     ```

2. **Edit Crontab**:
   - Open the crontab for the user running the script (e.g., `root`):
     ```bash
     sudo crontab -e
     ```
   - Add a cronjob to run daily at 2 AM (adjust schedule as needed):
     ```bash
     0 2 * * * /usr/local/bin/etcd-backup.sh /etc/etcd-backup/etcd-conf.conf
     ```
   - This runs the script every day at 2:00 AM UTC.

3. **Verify Permissions**:
   - Ensure the user running the cronjob has access to:
     - The script (`/usr/local/bin/etcd-backup.sh`).
     - The config file (`/etc/etcd-backup/etcd-conf.conf`).
     - etcd certificate files (e.g., `/etc/kubernetes/pki/etcd/*`).
     - Cloud credentials (if applicable).
   - Example for `root`:
     ```bash
     sudo chown root:root /usr/local/bin/etcd-backup.sh /etc/etcd-backup/etcd-conf.conf
     sudo chmod 700 /usr/local/bin/etcd-backup.sh
     sudo chmod 600 /etc/etcd-backup/etcd-conf.conf
     ```

4. **Test the Cronjob**:
   - Manually run the script to ensure it works:
     ```bash
     /usr/local/bin/etcd-backup.sh /etc/etcd-backup/etcd-conf.conf
     ```
   - Check `/var/log/etcd-backup.log` for errors.
   - Simulate the cronjob environment:
     ```bash
     env -i /bin/bash -c "/usr/local/bin/etcd-backup.sh /etc/etcd-backup/etcd-conf.conf"
     ```

5. **Monitor Logs**:
   - Regularly check `/var/log/etcd-backup.log` for backup status.
   - Set up log rotation if needed to manage log size:
     ```bash
     sudo nano /etc/logrotate.d/etcd-backup
     ```
     Add:
     ```
     /var/log/etcd-backup.log {
         weekly
         rotate 4
         compress
         missingok
         notifempty
     }
     ```

#### Cronjob Notes
- Ensure the cronjob runs as a user with sufficient permissions (e.g., `root` for Kubernetes clusters).
- If using cloud storage, verify that cloud credentials are accessible (e.g., AWS profile or GCS service account key).
- Adjust the cron schedule (`0 2 * * *`) to your needs (e.g., `0 0 * * *` for midnight, or `*/30 * * * *` for every 30 minutes).

## Troubleshooting

- **Check Logs**: Review `/var/log/etcd-backup.log` for detailed error messages.
- **Dependency Errors**: Ensure all dependencies are installed and compatible (e.g., `yq` version 4.x).
- **Permission Issues**: Verify file permissions for the script, config file, and certificate paths.
- **Cloud Credential Errors**: Validate cloud credentials using the respective CLI tools (`aws`, `gsutil`, `az`).
- **etcd Connectivity**: Ensure `etcdctl` can connect to the specified endpoints with the provided certificates.

For further assistance, include the full log output and configuration details when seeking help.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.