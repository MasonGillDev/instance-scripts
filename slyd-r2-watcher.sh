#!/bin/bash
#
# SLYD R2 File Watcher & Downloader
# Monitors for download jobs and processes them with encryption support
#
# Version: 1.0.0
# GitHub: https://github.com/SLYD-Platform/instance-scripts
#

set -e

# Configuration
SCRIPT_VERSION="1.0.4"
WATCH_DIR="/tmp/slyd-downloads"
DOWNLOAD_DIR="/home/ubuntu/downloads"
LOG_FILE="/var/log/slyd-r2-watcher.log"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/MasonGillDev/instance-scripts/main"
CHECK_INTERVAL=5  # seconds between checks
UPDATE_CHECK_INTERVAL=3600  # Check for updates every hour

# Create necessary directories
mkdir -p "$WATCH_DIR"
mkdir -p "$DOWNLOAD_DIR"
touch "$LOG_FILE"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check for script updates
check_for_updates() {
    log "Checking for script updates..."

    REMOTE_VERSION=$(curl -fsSL --connect-timeout 5 "$GITHUB_RAW_BASE/VERSION" 2>/dev/null || echo "$SCRIPT_VERSION")

    if [ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ]; then
        log "New version available: $REMOTE_VERSION (current: $SCRIPT_VERSION)"
        log "Downloading update..."

        # Download new version to temp location
        if curl -fsSL "$GITHUB_RAW_BASE/slyd-r2-watcher.sh" -o /tmp/slyd-r2-watcher-new.sh; then
            # Verify it's a valid script
            if head -1 /tmp/slyd-r2-watcher-new.sh | grep -q "^#!/bin/bash"; then
                log "Update downloaded successfully. Installing..."

                # Replace current script
                sudo mv /tmp/slyd-r2-watcher-new.sh /usr/local/bin/slyd-r2-watcher.sh
                sudo chmod +x /usr/local/bin/slyd-r2-watcher.sh

                log "Update installed. Restarting service..."
                sudo systemctl restart slyd-r2-watcher
                exit 0
            else
                log "ERROR: Downloaded file is not a valid script. Skipping update."
                rm -f /tmp/slyd-r2-watcher-new.sh
            fi
        else
            log "ERROR: Failed to download update"
        fi
    else
        log "Script is up to date (version $SCRIPT_VERSION)"
    fi
}

# Process a download job file
process_download_job() {
    local job_file="$1"
    log "Processing job: $job_file"

    # Read job configuration (JSON format)
    if ! command -v jq &> /dev/null; then
        log "ERROR: jq not installed. Installing..."
        sudo apt-get update -qq && sudo apt-get install -y jq
    fi

    # Parse JSON job file
    local download_url=$(jq -r '.url' "$job_file" 2>/dev/null)
    local target_path=$(jq -r '.targetPath // empty' "$job_file" 2>/dev/null)
    local encrypted=$(jq -r '.encrypted // false' "$job_file" 2>/dev/null)
    local encryption_key=$(jq -r '.encryptionKey // empty' "$job_file" 2>/dev/null)
    local filename=$(jq -r '.filename // empty' "$job_file" 2>/dev/null)

    # Validate URL
    if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
        log "ERROR: No download URL in job file"
        mv "$job_file" "${job_file}.failed"
        return 1
    fi

    # Set default target path
    if [ -z "$target_path" ] || [ "$target_path" == "null" ]; then
        target_path="$DOWNLOAD_DIR"
    fi

    # Create target directory
    mkdir -p "$target_path"

    log "Downloading from: $download_url"
    log "Target directory: $target_path"

    # Download file
    local temp_file="/tmp/slyd-download-$$.tmp"
    if [ -n "$filename" ] && [ "$filename" != "null" ]; then
        temp_file="/tmp/${filename}"
    fi

    if curl -fsSL --connect-timeout 30 --max-time 1800 -o "$temp_file" "$download_url"; then
        log "Download successful"

        # Handle encryption
        if [ "$encrypted" == "true" ] && [ -n "$encryption_key" ] && [ "$encryption_key" != "null" ]; then
            log "Decrypting file..."

            # Install openssl if not present
            if ! command -v openssl &> /dev/null; then
                log "Installing openssl..."
                sudo apt-get update -qq && sudo apt-get install -y openssl
            fi

            # Path to instance private key (generated during bootstrap)
            local private_key_path="/root/.slyd/instance-private.key"

            if [ ! -f "$private_key_path" ]; then
                log "ERROR: Private key not found at $private_key_path"
                rm -f "$temp_file"
                mv "$job_file" "${job_file}.failed"
                return 1
            fi

            # Step 1: Decrypt the RSA-encrypted AES key with instance private key
            log "Decrypting AES key with RSA private key..."
            local encrypted_key_file="/tmp/encrypted_key_$$.bin"
            local decrypted_key_file="/tmp/decrypted_key_$$.bin"

            # Decode base64 encrypted key to binary
            echo "$encryption_key" | base64 -d > "$encrypted_key_file"

            # Decrypt AES key using RSA-OAEP with SHA-256
            if ! openssl pkeyutl -decrypt -inkey "$private_key_path" \
                -in "$encrypted_key_file" -out "$decrypted_key_file" \
                -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 2>/dev/null; then
                log "ERROR: Failed to decrypt AES key with RSA private key"
                rm -f "$temp_file" "$encrypted_key_file" "$decrypted_key_file"
                mv "$job_file" "${job_file}.failed"
                return 1
            fi

            log "AES key decrypted successfully"

            # Step 2: Extract IV, auth tag, and encrypted data from downloaded file
            # File format: [12 bytes IV][16 bytes Auth Tag][Encrypted Data]
            local iv_file="/tmp/iv_$$.bin"
            local tag_file="/tmp/tag_$$.bin"
            local encrypted_data_file="/tmp/encrypted_$$.bin"
            local decrypted_file="${temp_file}.decrypted"

            # Extract first 12 bytes as IV
            dd if="$temp_file" of="$iv_file" bs=12 count=1 2>/dev/null

            # Extract next 16 bytes as auth tag
            dd if="$temp_file" of="$tag_file" bs=16 count=1 skip=12 iflag=skip_bytes 2>/dev/null

            # Extract remaining bytes as encrypted data
            dd if="$temp_file" of="$encrypted_data_file" skip=28 iflag=skip_bytes 2>/dev/null

            # Step 3: Decrypt file with AES-256-GCM using Python cryptography
            log "Decrypting file with AES-256-GCM..."

            # Install cryptography library if needed
            if ! python3 -c "import cryptography" 2>/dev/null; then
                log "Installing Python cryptography library..."
                sudo apt-get update -qq && sudo apt-get install -y python3-pip 2>/dev/null
                sudo pip3 install cryptography 2>/dev/null
            fi

            # Decrypt using Python
            # Note: GCM requires entire ciphertext for authentication, cannot stream
            python3 -c "
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import sys

try:
    # Read key, IV, and tag
    with open('$decrypted_key_file', 'rb') as f:
        key = f.read()
    with open('$iv_file', 'rb') as f:
        iv = f.read()
    with open('$tag_file', 'rb') as f:
        tag = f.read()

    # Read ciphertext
    with open('$encrypted_data_file', 'rb') as f:
        ciphertext = f.read()

    # Decrypt
    aesgcm = AESGCM(key)
    plaintext = aesgcm.decrypt(iv, ciphertext + tag, None)

    # Write output
    with open('$decrypted_file', 'wb') as f:
        f.write(plaintext)

    sys.exit(0)
except Exception as e:
    print(f'Decryption error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1

            if [ $? -eq 0 ]; then
                log "File decryption successful"
                rm -f "$temp_file" "$encrypted_key_file" "$decrypted_key_file" "$iv_file" "$tag_file" "$encrypted_data_file"
                temp_file="$decrypted_file"
            else
                log "ERROR: File decryption failed"
                rm -f "$temp_file" "$encrypted_key_file" "$decrypted_key_file" "$iv_file" "$tag_file" "$encrypted_data_file" "$decrypted_file"
                mv "$job_file" "${job_file}.failed"
                return 1
            fi
        fi

        # Move to target location
        local final_filename=$(basename "$temp_file")
        if [ -n "$filename" ] && [ "$filename" != "null" ]; then
            final_filename="$filename"
        fi

        local final_path="${target_path}/${final_filename}"
        mv "$temp_file" "$final_path"
        chmod 644 "$final_path"

        log "File saved to: $final_path"

        # Mark job as complete
        mv "$job_file" "${job_file}.completed"
        log "Job completed successfully"

        return 0
    else
        log "ERROR: Download failed"
        rm -f "$temp_file"
        mv "$job_file" "${job_file}.failed"
        return 1
    fi
}

# Clean up old job files
cleanup_old_jobs() {
    # Remove completed jobs older than 24 hours
    find "$WATCH_DIR" -name "*.json.completed" -mtime +1 -delete 2>/dev/null || true
    # Remove failed jobs older than 7 days
    find "$WATCH_DIR" -name "*.json.failed" -mtime +7 -delete 2>/dev/null || true
}

# Main loop
main() {
    log "SLYD R2 Watcher starting (version $SCRIPT_VERSION)"
    log "Watching directory: $WATCH_DIR"
    log "Download directory: $DOWNLOAD_DIR"

    local last_update_check=0

    while true; do
        # Check for updates periodically
        local current_time=$(date +%s)
        if [ $((current_time - last_update_check)) -ge $UPDATE_CHECK_INTERVAL ]; then
            check_for_updates
            last_update_check=$current_time
        fi

        # Look for new job files
        for job_file in "$WATCH_DIR"/*.json; do
            # Skip if no files match
            [ -e "$job_file" ] || continue

            # Skip if already processed
            [[ "$job_file" == *.completed ]] && continue
            [[ "$job_file" == *.failed ]] && continue

            # Process the job
            process_download_job "$job_file"
        done

        # Clean up old files
        cleanup_old_jobs

        # Wait before next check
        sleep $CHECK_INTERVAL
    done
}

# Handle signals gracefully
trap 'log "Received shutdown signal. Exiting..."; exit 0' SIGTERM SIGINT

# Start the watcher
main
