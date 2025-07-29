#!/usr/bin/env bash

# =============================================================================
# HARDENED START.SH - RunPod ComfyUI-Flux Template Runtime Orchestrator
# =============================================================================
# Updated version with JupyterLab removed and enhanced startup resilience
# Maintains all performance optimizations from original strategy
# Features robust environment variable parsing and validation

# Base script settings
set -euo pipefail

# Source the variable parser module
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/variable_parser.sh"

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
    
    # Special formatting for CONFIG level messages
    if [ "$level" = "CONFIG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔧 ${message}" | tee -a "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: ${message}" | tee -a "$LOG_FILE"
    fi
    
    # Only show DEBUG level messages if debug mode is enabled
    if [ "$level" = "DEBUG" ] && [ "${CONFIG[DEBUG_MODE]:-false}" != "true" ]; then
        return 0
    fi
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
    # Get parsed values from our config
    local fb_username="${CONFIG[FB_USERNAME]}"
    local fb_password="${CONFIG[FB_PASSWORD]}"
    
    # Generate password if not provided
    if [ -z "$fb_password" ]; then
        fb_password="$(generate_secure_password)"
        # Update the CONFIG array with the generated password
        CONFIG["FB_PASSWORD"]="$fb_password"
    fi
    
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

# CivitAI model download function
download_civitai_models() {
    log "INFO" "Starting CivitAI model downloads..."
    
    # Get parsed variables from config
    local checkpoint_ids="${CONFIG[CHECKPOINT_IDS_TO_DOWNLOAD]}"
    local lora_ids="${CONFIG[LORA_IDS_TO_DOWNLOAD]}"
    local vae_ids="${CONFIG[VAE_IDS_TO_DOWNLOAD]}"
    local civitai_token="${CONFIG[CIVITAI_TOKEN]}"
    
    # Check if any model IDs are specified
    if [ -z "$checkpoint_ids" ] && [ -z "$lora_ids" ] && [ -z "$vae_ids" ]; then
        log "INFO" "No CivitAI model IDs specified, skipping downloads"
        return 0
    fi
    
    # Verify CivitAI_Downloader exists
    if [ ! -d "/CivitAI_Downloader" ]; then
        log "ERROR" "CivitAI_Downloader directory not found"
        return 1
    fi
    
    # Set authentication token if provided
    TOKEN_ARG=""
    if [ -n "$civitai_token" ]; then
        log "INFO" "Using provided CivitAI token for authentication"
        TOKEN_ARG="--token ${civitai_token}"
    else
        log "WARN" "No CivitAI token provided, some models may not be accessible"
    fi
    
    # Create arrays to track successful and failed downloads
    declare -a FAILED_IDS
    TOTAL_DOWNLOADS=0
    SUCCESSFUL_DOWNLOADS=0
    
    # Function to download models of a specific type
    download_models() {
        local ids="$1"
        local type="$2"
        
        if [ -z "$ids" ]; then
            return 0
        fi
        
        # Parse the comma-separated list - already properly parsed by our variable parser
        IFS=',' read -ra ID_ARRAY <<< "$ids"
        local count=${#ID_ARRAY[@]}
        
        log "INFO" "Found $count CivitAI $type models to download"
        
        for id in "${ID_ARRAY[@]}"; do
            # ID is already trimmed by our parser
            if [ -z "$id" ]; then
                continue
            fi
            
            ((TOTAL_DOWNLOADS++))
            log "INFO" "Downloading CivitAI $type model ID: $id"
            
            # Execute the downloader script with appropriate arguments
            if cd /CivitAI_Downloader && python3 download.py \
                --id "$id" \
                --type "$type" \
                --output "${DOWNLOAD_DIR}" \
                $TOKEN_ARG \
                --nsfw allow \
                --timeout 600 \
                --retries 3 2>> "$LOG_FILE"; then
                log "INFO" "Successfully downloaded $type model ID: $id"
                ((SUCCESSFUL_DOWNLOADS++))
            else
                log "ERROR" "Failed to download $type model ID: $id"
                FAILED_IDS+=("$type:$id")
            fi
        done
    }
    
    # Download models by type
    download_models "$checkpoint_ids" "checkpoint"
    download_models "$lora_ids" "lora"
    download_models "$vae_ids" "vae"
    
    # Log summary
    FAILED_COUNT=${#FAILED_IDS[@]}
    log "INFO" "CivitAI downloads completed: ${SUCCESSFUL_DOWNLOADS}/${TOTAL_DOWNLOADS} successful"
    
    if [ $FAILED_COUNT -gt 0 ]; then
        log "WARN" "Failed to download ${FAILED_COUNT} models:"
        for failed in "${FAILED_IDS[@]}"; do
            log "WARN" "  - $failed"
        done
        
        if [ $SUCCESSFUL_DOWNLOADS -eq 0 ]; then
            log "ERROR" "All CivitAI downloads failed"
            return 1
        fi
    fi
    
    return 0
}

# HuggingFace model download function
download_huggingface_models() {
    log "INFO" "Starting HuggingFace model downloads..."
    
    # Get parsed variables from config
    local huggingface_repos="${CONFIG[HUGGINGFACE_REPOS]}"
    local huggingface_token="${CONFIG[HUGGINGFACE_TOKEN]}"
    
    # Check if HuggingFace repos are specified
    if [ -z "$huggingface_repos" ]; then
        log "INFO" "No HuggingFace repositories specified, skipping downloads"
        return 0
    fi

    # Create a temporary directory for HF cache
    HF_CACHE_DIR="${DOWNLOAD_DIR}/hf_cache"
    mkdir -p "${HF_CACHE_DIR}"
    
    # Set HuggingFace token if provided
    if [ -n "$huggingface_token" ]; then
        log "INFO" "Using provided HuggingFace token for authentication"
        export HUGGINGFACE_HUB_TOKEN="$huggingface_token"
    else
        log "WARN" "No HuggingFace token provided, only public repos will be accessible"
    fi
    
    # Parse the comma-separated list - already properly parsed by our variable parser
    IFS=',' read -ra REPOS <<< "$huggingface_repos"
    TOTAL_REPOS=${#REPOS[@]}
    SUCCESSFUL_DOWNLOADS=0
    FAILED_DOWNLOADS=0
    
    if [ ${TOTAL_REPOS} -eq 0 ]; then
        log "WARN" "No valid repositories found in HUGGINGFACE_REPOS"
        return 0
    fi
    
    log "INFO" "Found ${TOTAL_REPOS} HuggingFace repositories to download"
    
    # Process each repository
    for repo in "${REPOS[@]}"; do
        # Repo is already trimmed by our parser
        if [ -z "$repo" ]; then
            continue
        fi
        
        log "INFO" "Downloading HuggingFace repository: $repo"
        
        # Use Python with huggingface_hub to download the repository
        if python3 -c "
import os
import sys
from huggingface_hub import snapshot_download
try:
    # Set cache directory to our temp location
    os.environ['HF_HOME'] = '${HF_CACHE_DIR}'
    
    # Download the repository
    cache_dir = snapshot_download(
        repo_id='$repo',
        local_dir='${DOWNLOAD_DIR}/${repo##*/}',
        local_dir_use_symlinks=False,
        ignore_patterns=['*.md', 'LICENSE', '.git*'],
    )
    print(f'Downloaded {repo} to {cache_dir}')
    sys.exit(0)
except Exception as e:
    print(f'Error downloading {repo}: {e}')
    sys.exit(1)
" 2>> "$LOG_FILE"; then
            log "INFO" "Successfully downloaded $repo"
            ((SUCCESSFUL_DOWNLOADS++))
        else
            log "ERROR" "Failed to download $repo"
            ((FAILED_DOWNLOADS++))
        fi
    done
    
    log "INFO" "HuggingFace downloads completed: ${SUCCESSFUL_DOWNLOADS} successful, ${FAILED_DOWNLOADS} failed"
    
    if [ ${SUCCESSFUL_DOWNLOADS} -eq 0 ] && [ ${FAILED_DOWNLOADS} -gt 0 ]; then
        log "ERROR" "All HuggingFace downloads failed"
        return 1
    fi
    
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

    # Check if there are any model files to organize
    local model_count=$(find "${DOWNLOAD_DIR}" -maxdepth 3 -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" -o -name "*.pth" -o -name "*.pt" \) | wc -l)
    if [ "$model_count" -eq 0 ]; then
        log "WARN" "No model files found in ${DOWNLOAD_DIR} - nothing to organize"
        return 0
    else
        log "INFO" "Found ${model_count} model files to organize"
    fi
    
    # Process HuggingFace cache structure with extended file patterns and recursive search
    log "INFO" "Processing HuggingFace cache directories..."
    local extracted_count=0
    
    # Look for common HuggingFace cache patterns (snapshots, refs, blobs)
    for cache_pattern in "snapshots" "refs" "blobs"; do
        find "${DOWNLOAD_DIR}" -type d -name "${cache_pattern}" -print0 2>/dev/null | while IFS= read -r -d '' cache_dir; do
            log "INFO" "Processing HuggingFace cache in: ${cache_dir}"
            
            # Extract model files with more comprehensive patterns
            while IFS= read -r -d '' model_file; do
                local filename=$(basename "$model_file")
                local target="${DOWNLOAD_DIR}/${filename}"
                
                # Skip if file already exists in target directory
                if [ -f "$target" ]; then
                    log "INFO" "Skipping already extracted file: ${filename}"
                    continue
                fi
                
                log "INFO" "Extracting ${filename} from cache"
                if cp -n "$model_file" "$target"; then
                    ((extracted_count++))
                    log "INFO" "Extracted: ${filename}"
                else
                    log "ERROR" "Failed to extract: ${filename}"
                fi
            done < <(find "$cache_dir" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" -o -name "*.pth" -o -name "*.pt" -o -name "*.gguf" -o -name "*.onnx" \) -print0)
        done
    done
    
    log "INFO" "Extracted ${extracted_count} files from HuggingFace cache directories"
    
    # Look for model files in nested directories (max depth 3)
    log "INFO" "Looking for model files in nested directories..."
    local nested_count=0
    
    find "${DOWNLOAD_DIR}" -mindepth 2 -maxdepth 3 -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" -o -name "*.pth" -o -name "*.pt" -o -name "*.gguf" -o -name "*.onnx" \) -print0 2>/dev/null | while IFS= read -r -d '' nested_file; do
        local filename=$(basename "$nested_file")
        local target="${DOWNLOAD_DIR}/${filename}"
        
        # Skip if file already exists in target directory
        if [ -f "$target" ]; then
            continue
        fi
        
        log "INFO" "Moving nested model file to top level: ${filename}"
        if cp -n "$nested_file" "$target"; then
            ((nested_count++))
        else
            log "ERROR" "Failed to move nested file: ${filename}"
        fi
    done
    
    log "INFO" "Moved ${nested_count} nested model files to top level directory"
    
    # Verify we have model files in the download directory before organization
    local final_count=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" -o -name "*.pth" -o -name "*.pt" -o -name "*.gguf" -o -name "*.onnx" \) | wc -l)
    if [ "$final_count" -eq 0 ]; then
        log "WARN" "No model files found in top-level directory after extraction - nothing to organize"
        return 0
    fi
    
    log "INFO" "Found ${final_count} model files at top level ready for organization"
    
    # Run organization script with error handling
    log "INFO" "Running organization script..."
    if /usr/local/bin/organise_downloads.sh "$DOWNLOAD_DIR"; then
        log "INFO" "Model organization completed successfully"
    else
        log "ERROR" "Model organization encountered errors"
        log "WARN" "Continuing despite organization errors"
    fi
    
    # Return success even if organization had issues
    return 0
}

# Main execution flow with enhanced resilience
main() {
    log "INFO" "Starting hardened ComfyUI container..."
    
    # Initialize all environment variables with validation
    initialize_variables
    
    # Debug mode settings from our parser
    if [ "${CONFIG[DEBUG_MODE]}" = "true" ]; then
        set -x  # Enable bash trace mode for debugging
        log "INFO" "🐛 Debug mode enabled (verbose output)"
    fi
    
    # Setup directories
    BASEDIR="/workspace"
    DOWNLOAD_DIR="${BASEDIR}/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    chmod 755 "$DOWNLOAD_DIR"

    # Start services
    local services_started=0
    
    # FileBrowser (non-critical)
    if [ "${CONFIG[FILEBROWSER]}" = "true" ]; then
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

    # Clean up HuggingFace cache to save space
    log "INFO" "Cleaning up HuggingFace cache directories..."
    
    # First clean up the dedicated HF cache directory if it exists
    if [ -d "${DOWNLOAD_DIR}/hf_cache" ]; then
        log "INFO" "Removing HuggingFace cache directory"
        rm -rf "${DOWNLOAD_DIR}/hf_cache" 2>/dev/null || log "WARN" "Failed to remove HF cache directory"
    fi
    
    # Then find and remove various HF cache patterns
    for cache_pattern in "snapshots" "refs" "blobs" ".cache" ".git"; do
        find "${DOWNLOAD_DIR}" -type d -name "${cache_pattern}" -exec rm -rf {} + 2>/dev/null || true
    done
    
    # Remove any empty directories
    find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

    # Display summary of configuration
    log "INFO" "Startup configuration summary:"
    for var_name in DEBUG_MODE USE_VOLUME FILEBROWSER; do
        value="${CONFIG[$var_name]}"
        if [ "$value" = "true" ]; then
            status="✅ Enabled"
        else
            status="❌ Disabled"
        fi
        log "INFO" "- ${var_name}: ${status}"
    done
    
    # Model download summary
    if [ -n "${CONFIG[CHECKPOINT_IDS_TO_DOWNLOAD]}" ] || [ -n "${CONFIG[LORA_IDS_TO_DOWNLOAD]}" ] || [ -n "${CONFIG[VAE_IDS_TO_DOWNLOAD]}" ]; then
        log "INFO" "- CivitAI downloads: ✅ Configured"
    else
        log "INFO" "- CivitAI downloads: ❌ Not configured"
    fi
    
    if [ -n "${CONFIG[HUGGINGFACE_REPOS]}" ]; then
        log "INFO" "- HuggingFace downloads: ✅ Configured"
    else
        log "INFO" "- HuggingFace downloads: ❌ Not configured"
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