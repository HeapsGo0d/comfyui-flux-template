#!/usr/bin/env bash

# =============================================================================
# HARDENED START.SH - RunPod ComfyUI-Flux Template Runtime Orchestrator
# =============================================================================
# Updated version with JupyterLab removed and enhanced startup resilience
# Maintains all performance optimizations from original strategy

DEBUG_MODE=$(echo "${DEBUG_MODE:-false}" | tr '[:upper:]' '[:lower:]')
if [ "$DEBUG_MODE" = "true" ]; then
    set -euxo pipefail
    echo "🐛 Debug mode enabled (verbose output)"
else
    set -euo pipefail
fi

# Global configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_PID=$$
readonly LOG_FILE="/tmp/start_script.log"
readonly PID_FILE="/tmp/start_script.pid"

# Service tracking with enhanced resilience
declare -A SERVICE_PIDS=()
declare -A SERVICE_PORTS=()
declare -A SERVICE_CRITICAL=(
    ["filebrowser"]="false"
    ["comfyui"]="true"
)

# Security: Create secure log file
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
echo "$SCRIPT_PID" > "$PID_FILE"

# Enhanced logging with debug levels
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: ${message}" | tee -a "$LOG_FILE"
}

# Secure credential generation
generate_secure_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-16
}

# Port availability checking
check_port_available() {
    local port="$1"
    if ss -tuln | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# Enhanced service health checking
check_service_health() {
    local service_name="$1"
    local port="$2"
    local max_attempts="${3:-30}"
    local attempt=0
    
    log "INFO" "Checking health of ${service_name} on port ${port}..."
    
    while [ $attempt -lt $max_attempts ]; then
        if curl -s --connect-timeout 2 "http://localhost:${port}" >/dev/null 2>&1; then
            log "INFO" "${service_name} is healthy on port ${port}"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 2
    done
    
    log "ERROR" "${service_name} failed health check on port ${port} after ${max_attempts} attempts"
    return 1
}

# Optimized FileBrowser startup (simplified)
start_filebrowser() {
    local fb_username="${FB_USERNAME:-admin}"
    local fb_password="${FB_PASSWORD:-$(generate_secure_password)}"
    
    log "INFO" "Starting FileBrowser on port 8080..."
    
    # Initialize with secure settings
    filebrowser config init \
        --database /tmp/filebrowser.db \
        --root "$BASEDIR" \
        --port 8080 \
        --address 0.0.0.0
    
    filebrowser users add "$fb_username" "$fb_password" \
        --database /tmp/filebrowser.db \
        --perm.admin
    
    # Start service
    exec filebrowser \
        --database /tmp/filebrowser.db \
        --root "$BASEDIR" \
        --port 8080 \
        --address 0.0.0.0
}

# Enhanced model organization function
organize_models() {
    log "INFO" "Organizing downloaded models..."
    
    # Validate download directory
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        log "ERROR" "Download directory does not exist: $DOWNLOAD_DIR"
        return 1
    fi

    # Process HuggingFace cache structure
    find "${DOWNLOAD_DIR}" -type d -name "snapshots" -print0 | while IFS= read -r -d '' snap_dir; do
        find "$snap_dir" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" \) -exec cp -n {} "$DOWNLOAD_DIR" \;
    done

    # Run organization script with error handling
    if /usr/local/bin/organise_downloads.sh "$DOWNLOAD_DIR"; then
        log "INFO" "Model organization completed successfully"
    else
        log "ERROR" "Model organization encountered errors"
        return 1
    fi
}

# Main execution flow with enhanced resilience
main() {
    log "INFO" "Starting hardened ComfyUI container..."
    
    # Setup directories
    USE_VOLUME=$(echo "${USE_VOLUME:-false}" | tr '[:upper:]' '[:lower:]')
    BASEDIR="/workspace"
    DOWNLOAD_DIR="${BASEDIR}/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    chmod 755 "$DOWNLOAD_DIR"

    # Start services
    local services_started=0
    
    # FileBrowser (non-critical)
    if [ "${FILEBROWSER:-false}" = "true" ]; then
        if start_filebrowser & SERVICE_PIDS["filebrowser"]=$!; then
            SERVICE_PORTS["filebrowser"]=8080
            ((services_started++))
        else
            log "WARN" "FileBrowser failed to start (non-critical)"
        fi
    fi

    # Model downloads
    download_civitai_models || log "WARN" "CivitAI downloads had issues"
    download_huggingface_models || log "WARN" "HuggingFace downloads had issues"
    
    # Model organization
    if ! organize_models; then
        log "ERROR" "Model organization failed, but proceeding"
    fi

    # Start ComfyUI (critical service)
    log "INFO" "Starting ComfyUI (critical service)..."
    cd /ComfyUI
    exec python3 main.py --listen 0.0.0.0 --port 7860
}

# Execute main function
main "$@"