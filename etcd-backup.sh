#!/bin/bash

# Constants
readonly LOG_FILE="/var/log/etcd-backup.log"
readonly BACKUP_PREFIX="etcd-backup"
readonly MAX_LOG_SIZE=$((10*1024*1024)) # 10MB
readonly VALID_S3_BUCKET_REGEX='^[a-z0-9.-]+$'
readonly VALID_GCS_BUCKET_REGEX='^[a-z0-9][-a-z0-9._]+$'
readonly VALID_AZURE_ACCOUNT_REGEX='^[a-z0-9]+$'
readonly VALID_AZURE_CONTAINER_REGEX='^[a-z0-9]([a-z0-9-]){1,61}[a-z0-9]$'
readonly VALID_STORAGE_TYPE_REGEX='^(local|cloud)$'
readonly VALID_CLOUD_PROVIDER_REGEX='^(s3|gcs|azure)$'
readonly ACTION="backup" # Set ACTION as a constant

# Check dependencies
check_dependencies() {
    local deps=("etcdctl" "stat" "tee" "find" "sort" "tail" "awk" "kubectl" "yq" "df")
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || {
            log "❌ Error: $dep is required but not installed."
            if [[ "$dep" == "yq" ]]; then
                log "To install yq 4.x: sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
                log "Or: sudo apt-get install yq (Debian/Ubuntu, ensure version 4.x) or brew install yq (macOS)"
            fi
            exit 1
        }
    done
    local yq_version
    yq_version=$(yq --version 2>&1 | grep -o 'version v\?[0-9]\+\.[0-9]\+' || echo "unknown")
    if [[ ! "$yq_version" =~ ^version\ v?4\.[0-9]+ ]]; then
        log "❌ Error: yq version 4.x is required, but found $yq_version."
        log "Please upgrade yq to version 4.x:"
        log "  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
        log "Or: sudo apt-get install yq (Debian/Ubuntu, ensure version 4.x) or brew install yq (macOS)"
        exit 1
    fi
    local current_dir
    current_dir=$(pwd)
    if ! touch "$current_dir/test.$$" 2>/dev/null || ! rm "$current_dir/test.$$" 2>/dev/null; then
        log "❌ Error: Current directory $current_dir is not writable."
        log "Ensure the user has write permissions to $current_dir or run the script from a writable directory."
        log "Try: sudo chmod u+w $current_dir or change to a writable directory with 'cd /path/to/writable/dir')"
        exit 1
    fi
    local disk_space
    disk_space=$(df -k "$current_dir" | tail -n 1 | awk '{print $4}')
    if [[ -z "$disk_space" || "$disk_space" -lt 1024 ]]; then
        log "❌ Error: Insufficient disk space in $current_dir. Available: ${disk_space:-0} KB, required: at least 1024 KB."
        log "Check disk space with 'df -h $current_dir' and free up space."
        exit 1
    fi
    kubectl get nodes >/dev/null 2>&1 || {
        log "❌ Error: kubectl cannot connect to the Kubernetes cluster."
        exit 1
    }
}

# Check cloud dependencies
check_cloud_dependencies() {
    if [[ "$STORAGE_TYPE" != "cloud" ]]; then
        return 0
    fi
    local cloud_dep=""
    local provider_name=""
    case "$CLOUD_PROVIDER" in
        s3) cloud_dep="aws"; provider_name="AWS CLI" ;;
        gcs) cloud_dep="gsutil"; provider_name="Google Cloud SDK (gsutil)" ;;
        azure) cloud_dep="az"; provider_name="Azure CLI" ;;
    esac
    if [[ -n "$cloud_dep" ]]; then
        command -v "$cloud_dep" >/dev/null 2>&1 || {
            log "❌ Error: $provider_name is required for $CLOUD_PROVIDER but not installed."
            case "$cloud_dep" in
                aws)
                    log "To install AWS CLI:"
                    log "  - Ubuntu/Debian: sudo apt-get install awscli"
                    log "  - CentOS/RHEL: sudo yum install awscli"
                    log "  - macOS: brew install awscli"
                    log "  - Or download from: https://aws.amazon.com/cli/"
                    ;;
                gsutil)
                    log "To install Google Cloud SDK (includes gsutil):"
                    log "  - Ubuntu/Debian: sudo snap install google-cloud-sdk --classic"
                    log "  - CentOS/RHEL: sudo yum install google-cloud-sdk"
                    log "  - macOS: brew install google-cloud-sdk"
                    log "  - Or download from: https://cloud.google.com/sdk/docs/install"
                    ;;
                az)
                    log "To install Azure CLI:"
                    log "  - Ubuntu/Debian: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
                    log "  - CentOS/RHEL: sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc && sudo dnf install -y azure-cli"
                    log "  - macOS: brew install azure-cli"
                    log "  - Or download from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
                    ;;
            esac
            exit 1
        }
        log "✅ $provider_name is installed for $CLOUD_PROVIDER"
    fi
}

# Initialize logging
init_log() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir" || {
        echo "❌ Error: Failed to create log directory $log_dir" >&2
        exit 1
    }
    chmod 700 "$log_dir"
    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    if [[ -f "$LOG_FILE" && $(stat -c %s "$LOG_FILE" 2>/dev/null || stat -f %z "$LOG_FILE") -gt $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "$LOG_FILE.$(TZ=UTC date +%s)" || {
            echo "❌ Error: Failed to rotate log file" >&2
            exit 1
        }
    fi
}

# Log message
log() {
    local message="$*"
    echo "$(TZ=UTC date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Prompt with default value
prompt_with_default() {
    local var_name=$1
    local prompt_message=$2
    local default_value=$3
    local validator=$4
    local user_input
    read -p "$prompt_message [$default_value]: " user_input
    user_input="${user_input:-$default_value}"
    if [[ -n "$validator" && -n "$user_input" && ! "$user_input" =~ $validator ]]; then
        log "❌ Invalid input for $var_name: '$user_input'. Must match regex: $validator"
        exit 1
    fi
    eval "$var_name=\"$user_input\""
    case "$var_name" in
        ETCD_CACERT|ETCD_CERT|ETCD_KEY|AWS_PROFILE|GCS_CREDENTIALS|AZURE_STORAGE_ACCOUNT_KEY)
            log "User set $var_name to a value (hidden for security)"
            ;;
        *)
            log "User set $var_name to '$user_input'"
            ;;
    esac
}

# Prompt for required input
prompt_required() {
    local var_name=$1
    local prompt_message=$2
    local validator=$3
    local user_input
    read -p "$prompt_message: " user_input
    if [[ -z "$user_input" ]]; then
        log "❌ $var_name is required"
        exit 1
    fi
    if [[ -n "$validator" && ! "$user_input" =~ $validator ]]; then
        log "❌ Invalid input for $var_name: '$user_input'. Must match regex: $validator"
        exit 1
    fi
    eval "$var_name=\"$user_input\""
    case "$var_name" in
        ETCD_CACERT|ETCD_CERT|ETCD_KEY|AWS_PROFILE|GCS_CREDENTIALS|AZURE_STORAGE_ACCOUNT_KEY)
            log "User set $var_name to a value (hidden for security)"
            ;;
        *)
            log "User set $var_name to '$user_input'"
            ;;
    esac
}

# Prompt for cloud provider
prompt_cloud_provider() {
    local var_name=$1
    local prompt_message=$2
    local available_providers=$3
    local validator="^($(echo "$available_providers" | tr ' ' '|'))$"
    local user_input
    read -p "$prompt_message ($available_providers) [s3]: " user_input
    user_input="${user_input:-s3}"
    if [[ ! "$user_input" =~ $validator ]]; then
        log "❌ Invalid cloud provider: $user_input. Must be one of: $available_providers"
        exit 1
    fi
    eval "$var_name=\"$user_input\""
    log "User set $var_name to '$user_input'"
}

# Validate file or directory path
validate_path() {
    local path=$1
    local type=$2
    local description=$3
    if [[ "$type" == "file" && ! -f "$path" ]]; then
        log "❌ $description not found: $path"
        exit 1
    elif [[ "$type" == "dir" && ! -d "$path" ]]; then
        log "❌ $description not found: $path"
        exit 1
    fi
    if [[ "$type" == "file" && ! -r "$path" ]]; then
        log "❌ $description is not readable: $path"
        exit 1
    fi
    if [[ "$type" == "dir" && ! -w "$path" ]]; then
        log "❌ $description is not writable: $path"
        exit 1
    fi
}

# Validate cloud credentials
validate_cloud_credentials() {
    if [[ "$STORAGE_TYPE" != "cloud" ]]; then
        return 0
    fi
    log "🔐 Validating cloud credentials..."
    case "$CLOUD_PROVIDER" in
        s3)
            aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ Invalid AWS credentials for profile $AWS_PROFILE"
                exit 1
            }
            log "✅ AWS credentials validated"
            ;;
        gcs)
            validate_path "$GCS_CREDENTIALS" file "GCS credentials"
            GOOGLE_APPLICATION_CREDENTIALS="$GCS_CREDENTIALS" gsutil ls "gs://$GCS_BUCKET" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ Invalid GCS credentials in $GCS_CREDENTIALS"
                exit 1
            }
            log "✅ GCS credentials validated"
            ;;
        azure)
            AZURE_STORAGE_KEY="$AZURE_STORAGE_ACCOUNT_KEY" az storage account show \
                --name "$AZURE_STORAGE_ACCOUNT" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ Invalid Azure credentials for storage account $AZURE_STORAGE_ACCOUNT"
                exit 1
            }
            log "✅ Azure credentials validated"
            ;;
    esac
}

# Validate cloud path
validate_cloud_path() {
    if [[ "$STORAGE_TYPE" != "cloud" ]]; then
        return 0
    fi
    log "📂 Checking if cloud path exists..."
    case "$CLOUD_PROVIDER" in
        s3)
            local s3_path="s3://$S3_BUCKET"
            [[ -n "$S3_FOLDER" ]] && s3_path="$s3_path/$S3_FOLDER/"
            aws s3 ls "$s3_path" --profile "$AWS_PROFILE" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ S3 path $s3_path does not exist"
                exit 1
            }
            log "✅ S3 path $s3_path exists"
            ;;
        gcs)
            local gcs_path="gs://$GCS_BUCKET"
            [[ -n "$GCS_FOLDER" ]] && gcs_path="$gcs_path/$GCS_FOLDER/"
            GOOGLE_APPLICATION_CREDENTIALS="$GCS_CREDENTIALS" gsutil ls "$gcs_path" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ GCS path $gcs_path does not exist"
                exit 1
            }
            log "✅ GCS path $gcs_path exists"
            ;;
        azure)
            local azure_path="$AZURE_STORAGE_ACCOUNT"
            [[ -n "$AZURE_CONTAINER" ]] && azure_path="$azure_path/$AZURE_CONTAINER"
            AZURE_STORAGE_KEY="$AZURE_STORAGE_ACCOUNT_KEY" az storage container show \
                --account-name "$AZURE_STORAGE_ACCOUNT" \
                --name "${AZURE_CONTAINER:-etcd-backups}" >/dev/null 2>>"$LOG_FILE" || {
                log "❌ Azure path $azure_path does not exist"
                exit 1
            }
            log "✅ Azure path $azure_path exists"
            ;;
    esac
}

# Read and parse configuration file
read_config_block() {
    local config_file=$1
    local block_index=$2
    validate_path "$config_file" file "Configuration file"
    chmod 600 "$config_file" || { log "❌ Failed to set permissions on $config_file"; exit 1; }
    
    # Reset variables for each block
    unset STORAGE_TYPE ETCD_BACKUP_FOLDER ETCD_ENDPOINTS ETCD_CACERT ETCD_CERT ETCD_KEY
    unset CLOUD_PROVIDER S3_BUCKET S3_FOLDER AWS_PROFILE
    unset GCS_BUCKET GCS_FOLDER GCS_CREDENTIALS
    unset AZURE_STORAGE_ACCOUNT AZURE_CONTAINER AZURE_STORAGE_ACCOUNT_KEY

    # Read the specific block using awk
    local block_content
    block_content=$(awk -v block_num="$block_index" '
        BEGIN { block_count = 0; in_block = 0; }
        /^$/ || /^#/ {
            if (in_block) { in_block = 0; }
            next;
        }
        !in_block && !/^$/ && !/^#/ {
            block_count++;
            in_block = 1;
        }
        in_block && block_count == block_num {
            print;
        }
        in_block && block_count > block_num {
            exit;
        }
    ' "$config_file")

    if [[ -z "$block_content" ]]; then
        return 1 # No more blocks
    fi

    # Debug: Log the block content
    log "DEBUG: Block $block_index content:\n$block_content"

    # Process the block content without creating a subshell
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key=$(echo "$key" | awk '{$1=$1};1')
        value=$(echo "$value" | awk '{$1=$1};1')
        case "$key" in
            STORAGE_TYPE)
                [[ "$value" =~ $VALID_STORAGE_TYPE_REGEX ]] || { log "❌ Invalid $key: $value"; exit 1; }
                STORAGE_TYPE="$value"
                log "Storage type set to '$value'"
                ;;
            ETCD_BACKUP_FOLDER)
                ETCD_BACKUP_FOLDER="$value"
                log "ETCD backup folder set to '$value'"
                ;;
            ETCD_ENDPOINTS)
                ETCD_ENDPOINTS="$value"
                log "ETCD endpoints set to '$value'"
                ;;
            ETCD_CACERT)
                ETCD_CACERT="$value"
                log "ETCD CA cert set to a value (hidden)"
                ;;
            ETCD_CERT)
                ETCD_CERT="$value"
                log "ETCD cert set to a value (hidden)"
                ;;
            ETCD_KEY)
                ETCD_KEY="$value"
                log "ETCD key set to a value (hidden)"
                ;;
            CLOUD_PROVIDER)
                [[ "$value" =~ $VALID_CLOUD_PROVIDER_REGEX ]] || { log "❌ Invalid $key: $value"; exit 1; }
                CLOUD_PROVIDER="$value"
                log "Cloud provider set to '$value'"
                ;;
            S3_BUCKET)
                [[ "$value" =~ $VALID_S3_BUCKET_REGEX ]] || { log "❌ Invalid $key: $value"; exit 1; }
                S3_BUCKET="$value"
                log "S3 bucket set to '$value'"
                ;;
            S3_FOLDER)
                S3_FOLDER="$value"
                log "S3 folder set to '${value:-empty}'"
                ;;
            AWS_PROFILE)
                AWS_PROFILE="$value"
                log "AWS profile set to a value (hidden)"
                ;;
            GCS_BUCKET)
                [[ "$value" =~ $VALID_GCS_BUCKET_REGEX ]] || { log "❌ Invalid $key: $value"; exit 1; }
                GCS_BUCKET="$value"
                log "GCS bucket set to '$value'"
                ;;
            GCS_FOLDER)
                GCS_FOLDER="$value"
                log "GCS folder set to '${value:-empty}'"
                ;;
            GCS_CREDENTIALS)
                GCS_CREDENTIALS="$value"
                log "GCS credentials set to a value (hidden)"
                ;;
            AZURE_STORAGE_ACCOUNT)
                [[ "$value" =~ $VALID_AZURE_ACCOUNT_REGEX ]] || { log "❌ Invalid $key: $value"; exit 1; }
                AZURE_STORAGE_ACCOUNT="$value"
                log "Azure storage account set to '$value'"
                ;;
            AZURE_CONTAINER)
                [[ -n "$value" && ! "$value" =~ $VALID_AZURE_CONTAINER_REGEX ]] && { log "❌ Invalid $key: '$value'. Must be 3-63 characters, lowercase letters, numbers, or hyphens, starting and ending with a letter or number."; exit 1; }
                AZURE_CONTAINER="$value"
                log "Azure container set to '${value:-etcd-backups}'"
                ;;
            AZURE_STORAGE_ACCOUNT_KEY)
                AZURE_STORAGE_ACCOUNT_KEY="$value"
                log "Azure storage account key set to a value (hidden)"
                ;;
            *)
                log "⚠️ Unknown config key: $key"
                ;;
        esac
    done <<< "$block_content"

    # Set default for Azure container if not specified
    if [[ "$CLOUD_PROVIDER" == "azure" && -z "$AZURE_CONTAINER" ]]; then
        AZURE_CONTAINER="etcd-backups"
        log "Azure container set to default 'etcd-backups' (not specified in config)"
    fi

    # Validate required settings
    [[ -n "$STORAGE_TYPE" ]] || { log "❌ STORAGE_TYPE not set in block $block_index"; exit 1; }
    if [[ "$STORAGE_TYPE" == "local" ]]; then
        [[ -n "$ETCD_BACKUP_FOLDER" ]] || { log "❌ ETCD_BACKUP_FOLDER not set in block $block_index"; exit 1; }
    fi
    [[ -n "$ETCD_ENDPOINTS" ]] || { log "❌ ETCD_ENDPOINTS not set in block $block_index"; exit 1; }
    [[ -n "$ETCD_CACERT" ]] || { log "❌ ETCD_CACERT not set in block $block_index"; exit 1; }
    [[ -n "$ETCD_CERT" ]] || { log "❌ ETCD_CERT not set in block $block_index"; exit 1; }
    [[ -n "$ETCD_KEY" ]] || { log "❌ ETCD_KEY not set in block $block_index"; exit 1; }
    if [[ "$STORAGE_TYPE" == "cloud" ]]; then
        [[ -n "$CLOUD_PROVIDER" ]] || { log "❌ CLOUD_PROVIDER not set in block $block_index"; exit 1; }
        case "$CLOUD_PROVIDER" in
            s3)
                [[ -n "$S3_BUCKET" ]] || { log "❌ S3_BUCKET not set in block $block_index"; exit 1; }
                [[ -n "$AWS_PROFILE" ]] || { log "❌ AWS_PROFILE not set in block $block_index"; exit 1; }
                ;;
            gcs)
                [[ -n "$GCS_BUCKET" ]] || { log "❌ GCS_BUCKET not set in block $block_index"; exit 1; }
                [[ -n "$GCS_CREDENTIALS" ]] || { log "❌ GCS_CREDENTIALS not set in block $block_index"; exit 1; }
                ;;
            azure)
                [[ -n "$AZURE_STORAGE_ACCOUNT" ]] || { log "❌ AZURE_STORAGE_ACCOUNT not set in block $block_index"; exit 1; }
                [[ -n "$AZURE_STORAGE_ACCOUNT_KEY" ]] || { log "❌ AZURE_STORAGE_ACCOUNT_KEY not set in block $block_index"; exit 1; }
                ;;
        esac
    fi
}

# Upload to S3
upload_to_s3() {
    local file_path=$1
    local s3_path="s3://$S3_BUCKET"
    [[ -n "$S3_FOLDER" ]] && s3_path="$s3_path/$S3_FOLDER"
    s3_path="$s3_path/$(basename "$file_path")"
    log "📤 Uploading $file_path to $s3_path"
    aws s3 cp "$file_path" "$s3_path" --profile "$AWS_PROFILE" >> "$LOG_FILE" 2>&1 || {
        log "❌ Failed to upload $file_path to S3"
        exit 1
    }
}

# Upload to GCS
upload_to_gcs() {
    local file_path=$1
    local gcs_path="gs://$GCS_BUCKET"
    [[ -n "$GCS_FOLDER" ]] && gcs_path="$gcs_path/$GCS_FOLDER"
    gcs_path="$gcs_path/$(basename "$file_path")"
    log "📤 Uploading $file_path to $gcs_path"
    GOOGLE_APPLICATION_CREDENTIALS="$GCS_CREDENTIALS" gsutil cp "$file_path" "$gcs_path" >> "$LOG_FILE" 2>&1 || {
        log "❌ Failed to upload $file_path to GCS"
        exit 1
    }
}

# Upload to Azure
upload_to_azure() {
    local file_path=$1
    local azure_path="${AZURE_CONTAINER:-etcd-backups}/$(basename "$file_path")"
    log "📤 Uploading $file_path to Azure Blob Storage: $AZURE_STORAGE_ACCOUNT/$azure_path"
    AZURE_STORAGE_KEY="$AZURE_STORAGE_ACCOUNT_KEY" az storage blob upload \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --container-name "${AZURE_CONTAINER:-etcd-backups}" \
        --file "$file_path" \
        --name "$(basename "$file_path")" >> "$LOG_FILE" 2>&1 || {
        log "❌ Failed to upload $file_path to Azure Blob Storage"
        exit 1
    }
}

# Show backup metadata
show_backup_metadata() {
    local file_path=$1
    if [[ "$STORAGE_TYPE" == "local" ]]; then
        validate_path "$file_path" file "Backup file"
        log "📂 Local Backup Metadata:"
        local stat_output
        if [[ "$OSTYPE" == "darwin"* ]]; then
            stat_output=$(stat -f "File: %N | Size: %z bytes | Modified: %Sm" "$file_path" 2>>"$LOG_FILE")
        else
            stat_output=$(stat --format="File: %n | Size: %s bytes | Modified: %y" "$file_path" 2>>"$LOG_FILE")
        fi
        echo -e "$stat_output" | tee -a "$LOG_FILE"
    elif [[ "$STORAGE_TYPE" == "cloud" ]]; then
        case "$CLOUD_PROVIDER" in
            s3)
                local s3_file="s3://$S3_BUCKET"
                [[ -n "$S3_FOLDER" ]] && s3_file="$s3_file/$S3_FOLDER"
                s3_file="$s3_file/$(basename "$file_path")"
                log "☁️ S3 Backup Metadata for: $s3_file"
                aws s3 ls "$s3_file" --profile "$AWS_PROFILE" >> "$LOG_FILE" 2>&1 || {
                    log "❌ Failed to retrieve S3 metadata for $s3_file"
                    exit 1
                }
                ;;
            gcs)
                local gcs_file="gs://$GCS_BUCKET"
                [[ -n "$GCS_FOLDER" ]] && gcs_file="$gcs_file/$GCS_FOLDER"
                gcs_file="$gcs_file/$(basename "$file_path")"
                log "☁️ GCS Backup Metadata for: $gcs_file"
                GOOGLE_APPLICATION_CREDENTIALS="$GCS_CREDENTIALS" gsutil ls -l "$gcs_file" >> "$LOG_FILE" 2>&1 || {
                    log "❌ Failed to retrieve GCS metadata for $gcs_file"
                    exit 1
                }
                ;;
            azure)
                local azure_file="${AZURE_CONTAINER:-etcd-backups}/$(basename "$file_path")"
                log "☁️ Azure Backup Metadata for: $AZURE_STORAGE_ACCOUNT/$azure_file"
                AZURE_STORAGE_KEY="$AZURE_STORAGE_ACCOUNT_KEY" az storage blob show \
                    --account-name "$AZURE_STORAGE_ACCOUNT" \
                    --container-name "${AZURE_CONTAINER:-etcd-backups}" \
                    --name "$(basename "$file_path")" \
                    --query '{Name:name, Size:properties.contentLength, Modified:properties.lastModified}' \
                    --output table >> "$LOG_FILE" 2>&1 || {
                    log "❌ Failed to retrieve Azure metadata for $azure_file"
                    exit 1
                }
                ;;
        esac
    fi
}

# Configure settings interactively
configure_settings() {
    if [[ ! -t 0 ]]; then
        log "❌ Error: Interactive mode requires a terminal"
        exit 1
    fi
    log "🖥️ Running in interactive mode"
    prompt_with_default STORAGE_TYPE "📂 Use local or cloud storage? (local/cloud)" "local" "$VALID_STORAGE_TYPE_REGEX"
    if [[ "$STORAGE_TYPE" == "cloud" ]]; then
        AVAILABLE_CLOUD_PROVIDERS="s3 gcs azure"
        prompt_cloud_provider CLOUD_PROVIDER "☁️ Which cloud provider?" "$AVAILABLE_CLOUD_PROVIDERS"
        check_cloud_dependencies || exit 1
        case "$CLOUD_PROVIDER" in
            s3)
                prompt_required S3_BUCKET "🪣 Enter S3 bucket name" "$VALID_S3_BUCKET_REGEX"
                prompt_with_default S3_FOLDER "📂 Enter S3 folder prefix (optional)" ""
                prompt_with_default AWS_PROFILE "🔐 Enter AWS CLI profile to use" "default"
                ;;
            gcs)
                prompt_required GCS_BUCKET "🪣 Enter GCS bucket name" "$VALID_GCS_BUCKET_REGEX"
                prompt_with_default GCS_FOLDER "📂 Enter GCS folder prefix (optional)" ""
                prompt_required GCS_CREDENTIALS "🔐 Enter path to GCS service account key"
                ;;
            azure)
                prompt_required AZURE_STORAGE_ACCOUNT "🪣 Enter Azure storage account name" "$VALID_AZURE_ACCOUNT_REGEX"
                prompt_with_default AZURE_CONTAINER "📂 Enter Azure container name (optional, default: etcd-backups)" "etcd-backups" "$VALID_AZURE_CONTAINER_REGEX"
                prompt_required AZURE_STORAGE_ACCOUNT_KEY "🔐 Enter Azure storage account key"
                ;;
        esac
    fi
    if [[ "$STORAGE_TYPE" == "local" ]]; then
        prompt_with_default ETCD_BACKUP_FOLDER "📁 Enter backup folder path" "/opt/etcd-backup"
    fi
    prompt_with_default ETCD_ENDPOINTS "🔗 Enter ETCD endpoints" "https://127.0.0.1:2379"
    prompt_with_default ETCD_CACERT "🔒 Enter path to CA cert" "/etc/kubernetes/pki/etcd/ca.crt"
    prompt_with_default ETCD_CERT "🔒 Enter path to server cert" "/etc/kubernetes/pki/etcd/server.crt"
    prompt_with_default ETCD_KEY "🔒 Enter path to server key" "/etc/kubernetes/pki/etcd/server.key"

    # Validate settings
    [[ -n "$STORAGE_TYPE" ]] || { log "❌ STORAGE_TYPE not set"; exit 1; }
    if [[ "$STORAGE_TYPE" == "local" ]]; then
        [[ -n "$ETCD_BACKUP_FOLDER" ]] || { log "❌ ETCD_BACKUP_FOLDER not set"; exit 1; }
    fi
    [[ -n "$ETCD_ENDPOINTS" ]] || { log "❌ ETCD_ENDPOINTS not set"; exit 1; }
    [[ -n "$ETCD_CACERT" ]] || { log "❌ ETCD_CACERT not set"; exit 1; }
    [[ -n "$ETCD_CERT" ]] || { log "❌ ETCD_CERT not set"; exit 1; }
    [[ -n "$ETCD_KEY" ]] || { log "❌ ETCD_KEY not set"; exit 1; }
    if [[ "$STORAGE_TYPE" == "cloud" ]]; then
        [[ -n "$CLOUD_PROVIDER" ]] || { log "❌ CLOUD_PROVIDER not set"; exit 1; }
        case "$CLOUD_PROVIDER" in
            s3) [[ -n "$S3_BUCKET" ]] || { log "❌ S3_BUCKET not set"; exit 1; }; [[ -n "$AWS_PROFILE" ]] || { log "❌ AWS_PROFILE not set"; exit 1; }; ;;
            gcs) [[ -n "$GCS_BUCKET" ]] || { log "❌ GCS_BUCKET not set"; exit 1; }; [[ -n "$GCS_CREDENTIALS" ]] || { log "❌ GCS_CREDENTIALS not set"; exit 1; }; ;;
            azure) [[ -n "$AZURE_STORAGE_ACCOUNT" ]] || { log "❌ AZURE_STORAGE_ACCOUNT not set"; exit 1; }; [[ -n "$AZURE_STORAGE_ACCOUNT_KEY" ]] || { log "❌ AZURE_STORAGE_ACCOUNT_KEY not set"; exit 1; }; ;;
        esac
    fi
}

# Perform etcd backup
etcd_backup() {
    log "🔄 Starting ETCD backup..."
    etcdctl --endpoints="$ETCD_ENDPOINTS" --cacert="$ETCD_CACERT" \
            --cert="$ETCD_CERT" --key="$ETCD_KEY" \
            snapshot save "$ETCD_BACKUP_FILE_NAME" >> "$LOG_FILE" 2>&1 || {
        log "❌ Backup failed"
        exit 1
    }
    if [[ "$STORAGE_TYPE" == "cloud" ]]; then
        case "$CLOUD_PROVIDER" in
            s3) upload_to_s3 "$ETCD_BACKUP_FILE_NAME"; ;;
            gcs) upload_to_gcs "$ETCD_BACKUP_FILE_NAME"; ;;
            azure) upload_to_azure "$ETCD_BACKUP_FILE_NAME"; ;;
        esac
    fi
    show_backup_metadata "$ETCD_BACKUP_FILE_NAME"
    if [[ "$STORAGE_TYPE" == "local" ]]; then
        find "$ETCD_BACKUP_FOLDER" -name "*.db" -mtime +7 -delete 2>>"$LOG_FILE"
        log "🗑️ Deleted local backups older than 7 days"
    fi
    log "✅ Backup completed"
}

# Main function
main() {
    init_log
    export ETCDCTL_API=3
    log "🚀 Script started"

    check_dependencies

    if [[ $# -eq 0 ]]; then
        # Interactive mode
        if [[ ! -t 0 ]]; then
            log "❌ Error: Interactive mode requires a terminal"
            log "Usage: $0 [config_file]"
            exit 1
        fi
        log "🖥️ Running in interactive mode"
        configure_settings

        # Validate paths and credentials
        validate_path "$ETCD_CACERT" file "CA certificate"
        validate_path "$ETCD_CERT" file "Server certificate"
        validate_path "$ETCD_KEY" file "Server key"
        check_cloud_dependencies
        validate_cloud_credentials
        validate_cloud_path

        # Prepare backup folder or temporary directory
        if [[ "$STORAGE_TYPE" == "local" ]]; then
            mkdir -p "$ETCD_BACKUP_FOLDER" || {
                log "❌ Failed to create backup folder $ETCD_BACKUP_FOLDER"
                exit 1
            }
            chmod 700 "$ETCD_BACKUP_FOLDER"
            validate_path "$ETCD_BACKUP_FOLDER" dir "Backup folder"
        fi
        if [[ "$STORAGE_TYPE" == "cloud" && "$CLOUD_PROVIDER" == "gcs" && -n "$GCS_CREDENTIALS" ]]; then
            validate_path "$GCS_CREDENTIALS" file "GCS credentials"
        fi

        # Set backup file name
        local timestamp
        timestamp=$(TZ=UTC date "+%Y%m%d-%H%M%S")
        ETCD_BACKUP_PREFIX="$BACKUP_PREFIX-$timestamp.db"
        if [[ "$STORAGE_TYPE" == "local" ]]; then
            ETCD_BACKUP_FILE_NAME="$ETCD_BACKUP_FOLDER/$ETCD_BACKUP_PREFIX"
        else
            ETCD_BACKUP_FILE_NAME="/tmp/etcd-backup-$$/$ETCD_BACKUP_PREFIX"
            mkdir -p "$(dirname "$ETCD_BACKUP_FILE_NAME")" || {
                log "❌ Failed to create temporary directory for $ETCD_BACKUP_FILE_NAME"
                exit 1
            }
            chmod 700 "$(dirname "$ETCD_BACKUP_FILE_NAME")"
            trap 'rm -rf "$(dirname "$ETCD_BACKUP_FILE_NAME")"' EXIT
        fi

        # Perform backup
        etcd_backup
    elif [[ $# -eq 1 ]]; then
        # Config file mode
        local config_file="$1"
        if [[ ! -f "$config_file" ]]; then
            log "❌ Error: Configuration file '$config_file' does not exist"
            log "Usage: $0 [config_file]"
            exit 1
        fi
        log "📄 Using configuration file: $config_file"

        # Count the number of backup blocks
        local block_count
        block_count=$(awk '
            BEGIN { count = 0; in_block = 0; }
            /^$/ || /^#/ { in_block = 0; next; }
            !in_block && !/^$/ && !/^#/ { count++; in_block = 1; }
            END { print count; }
        ' "$config_file")
        if [[ "$block_count" -eq 0 ]]; then
            log "❌ No valid backup configurations found in $config_file"
            exit 1
        fi
        log "🔍 Found $block_count backup configurations"

        # Process each backup block
        local block_index=1
        while true; do
            log "📋 Processing backup configuration $block_index"
            read_config_block "$config_file" "$block_index" || {
                log "✅ All backup configurations processed"
                break
            }

            # Validate paths and credentials
            validate_path "$ETCD_CACERT" file "CA certificate"
            validate_path "$ETCD_CERT" file "Server certificate"
            validate_path "$ETCD_KEY" file "Server key"
            check_cloud_dependencies
            validate_cloud_credentials
            validate_cloud_path

            # Prepare backup folder or temporary directory
            if [[ "$STORAGE_TYPE" == "local" ]]; then
                mkdir -p "$ETCD_BACKUP_FOLDER" || {
                    log "❌ Failed to create backup folder $ETCD_BACKUP_FOLDER"
                    exit 1
                }
                chmod 700 "$ETCD_BACKUP_FOLDER"
                validate_path "$ETCD_BACKUP_FOLDER" dir "Backup folder"
            fi
            if [[ "$STORAGE_TYPE" == "cloud" && "$CLOUD_PROVIDER" == "gcs" && -n "$GCS_CREDENTIALS" ]]; then
                validate_path "$GCS_CREDENTIALS" file "GCS credentials"
            fi

            # Set backup file name
            local timestamp
            timestamp=$(TZ=UTC date "+%Y%m%d-%H%M%S")
            ETCD_BACKUP_PREFIX="$BACKUP_PREFIX-$timestamp.db"
            if [[ "$STORAGE_TYPE" == "local" ]]; then
                ETCD_BACKUP_FILE_NAME="$ETCD_BACKUP_FOLDER/$ETCD_BACKUP_PREFIX"
            else
                ETCD_BACKUP_FILE_NAME="/tmp/etcd-backup-$$-$block_index/$ETCD_BACKUP_PREFIX"
                mkdir -p "$(dirname "$ETCD_BACKUP_FILE_NAME")" || {
                    log "❌ Failed to create temporary directory for $ETCD_BACKUP_FILE_NAME"
                    exit 1
                }
                chmod 700 "$(dirname "$ETCD_BACKUP_FILE_NAME")"
                trap 'rm -rf "$(dirname "$ETCD_BACKUP_FILE_NAME")"' EXIT
            fi

            # Perform backup
            etcd_backup

            ((block_index++))
        done
    else
        # Invalid arguments
        log "❌ Error: Invalid number of arguments ($#)"
        log "Usage: $0 [config_file]"
        exit 1
    fi
}

main "$@"
log "🏁 Script finished"