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
declare -a CHILD_PIDS=()

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
    
    while [ $attempt -lt $max_attempts ]; do
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

# Child process cleanup on exit
cleanup_and_exit() {
    local exit_code="${1:-0}"
    log "INFO" "Cleaning up child processes before exit..."
    
    # Kill all registered child processes
    for service in "${!SERVICE_PIDS[@]}"; do
        local pid="${SERVICE_PIDS[$service]}"
        if ps -p "$pid" >/dev/null 2>&1; then
            log "INFO" "Terminating $service (PID: $pid)"
            kill -TERM "$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        fi
    done
    
    log "INFO" "Exiting with code $exit_code"
    exit "$exit_code"
}

# Set up trap for graceful termination
trap 'cleanup_and_exit' INT TERM

# Optimized FileBrowser startup with background process management
start_filebrowser() {
    local fb_username="${FB_USERNAME:-admin}"
    local fb_password="${FB_PASSWORD:-$(generate_secure_password)}"
    local fb_log_file="/tmp/filebrowser.log"
    local fb_port=8080
    local health_check_timeout=15  # seconds
    
    log "INFO" "Starting FileBrowser on port ${fb_port}..."
    
    # Initialize with secure settings
    filebrowser config init \
        --database /tmp/filebrowser.db \
        --root "$BASEDIR" \
        --port "$fb_port" \
        --address 0.0.0.0
    
    filebrowser users add "$fb_username" "$fb_password" \
        --database /tmp/filebrowser.db \
        --perm.admin
    
    # Start service in background with dedicated log file
    filebrowser \
        --database /tmp/filebrowser.db \
        --root "$BASEDIR" \
        --port "$fb_port" \
        --address 0.0.0.0 > "$fb_log_file" 2>&1 &
    
    # Capture actual PID
    local filebrowser_pid=$!
    
    # Add to child processes array for proper supervision
    CHILD_PIDS+=("$filebrowser_pid")
    
    log "INFO" "FileBrowser process started with PID: $filebrowser_pid"
    
    # Perform health check with timeout
    local start_time=$(date +%s)
    local end_time=$((start_time + health_check_timeout))
    local current_time
    local healthy=false
    
    log "INFO" "Waiting up to ${health_check_timeout}s for FileBrowser to become available..."
    
    while [ "$(date +%s)" -lt "$end_time" ]; do
        # Check if process is still running
        if ! ps -p "$filebrowser_pid" >/dev/null 2>&1; then
            log "ERROR" "FileBrowser process died unexpectedly. Check logs at $fb_log_file"
            return 1
        fi
        
        # Check if service is responding
        if curl -s --connect-timeout 2 "http://localhost:${fb_port}" >/dev/null 2>&1; then
            log "INFO" "FileBrowser is healthy on port ${fb_port}"
            healthy=true
            break
        fi
        
        sleep 1
    done
    
    if [ "$healthy" = false ]; then
        log "ERROR" "FileBrowser failed to start within ${health_check_timeout} seconds"
        log "ERROR" "Last 10 lines of log file:"
        tail -n 10 "$fb_log_file" | while read -r line; do
            log "ERROR" "FileBrowser Log: $line"
        done
        
        # Kill the filebrowser process if it's still running
        if ps -p "$filebrowser_pid" >/dev/null 2>&1; then
            kill -TERM "$filebrowser_pid" 2>/dev/null || kill -KILL "$filebrowser_pid" 2>/dev/null
        fi
        
        # Signal failure to parent
        return 1
    fi
    
    # Store service PID for later reference
    SERVICE_PIDS["filebrowser"]="$filebrowser_pid"
    SERVICE_PORTS["filebrowser"]="$fb_port"
    
    return 0
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
        if start_filebrowser; then
            ((services_started++))
            log "INFO" "FileBrowser started successfully"
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
    
    # Set up trap for EXIT to ensure cleanup happens when ComfyUI terminates
    trap 'cleanup_and_exit' EXIT
    
    # ComfyUI is the last component to start and should run in the foreground
    exec python3 main.py --listen 0.0.0.0 --port 7860
}

# Execute main function
main "$@"