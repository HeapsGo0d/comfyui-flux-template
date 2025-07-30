#!/usr/bin/env bash
# Security Considerations:
# 1. Input Validation:
#    - Validates download directory exists (lines 16-30)
#    - Checks file existence before operations (lines 47, 112)
# 2. Error Handling:
#    - set -euo pipefail ensures script exits on errors (line 2)
#    - Individual operation error handling (lines 63-64, 140-144)
# 3. Safe File Operations:
#    - Uses symlinks first to avoid duplication (lines 56-61)
#    - Validates destination paths (lines 47-50)
# 4. Parallel Processing Safety:
#    - Job logging for debugging (lines 157, 162)
#    - Process isolation via GNU parallel
# 5. Cleanup:
#    - Removes empty directories (line 181)
#    - Temporary files cleaned in separate step (todo)

set -euo pipefail

# Default values
DRY_RUN=false
DOWNLOAD_DIR="/workspace/downloads"
VERBOSE=false
MIN_FREE_SPACE_GB=10  # Minimum required free space in GB

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --download-dir=*)
            DOWNLOAD_DIR="${1#*=}"
            shift
            ;;
        --min-free-space=*)
            MIN_FREE_SPACE_GB="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [DOWNLOAD_DIR]"
            echo ""
            echo "Options:"
            echo "  --dry-run            Test run without actually moving files"
            echo "  --verbose            Enable verbose output"
            echo "  --download-dir=DIR   Specify download directory (default: /workspace/downloads)"
            echo "  --min-free-space=GB  Minimum required free space in GB (default: 10)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            # Positional argument - download directory
            DOWNLOAD_DIR="$1"
            shift
            ;;
    esac
done

# Logging setup
LOG_FILE="/tmp/organise_downloads_$(date +%Y%m%d_%H%M%S).log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

# Start timestamp for measuring total execution time
start_script_time=$(date +%s)

echo "=== STARTING ORGANISE_DOWNLOADS ==="
echo "Timestamp: $(date)"
echo "PID: $$"
echo "User: $(whoami)"
echo "Host: $(hostname)"
echo "Dry run mode: ${DRY_RUN}"

# Check for GNU parallel
if ! command -v parallel &> /dev/null; then
    echo "[$(date +%T)] ⚠️  GNU parallel not found - falling back to sequential processing"
    PARALLEL_ENABLED=false
else
    echo "[$(date +%T)] ✅ GNU parallel found (version: $(parallel --version | head -n1))"
    PARALLEL_ENABLED=true
fi

# Function to validate the environment before starting
validate_environment() {
    local validated=true
    local total_model_count=0
    
    echo "🔍 Validating environment before organization..."
    
    # 1. Check if download directory exists and has content
    if [ ! -d "${DOWNLOAD_DIR}" ]; then
        echo "❌ Error: Download directory ${DOWNLOAD_DIR} does not exist"
        echo "🔍 Debug: Checking parent directories..."
        local parent_dir=$(dirname "${DOWNLOAD_DIR}")
        if [ -d "$parent_dir" ]; then
            echo "📁 Parent directory exists: $parent_dir"
            echo "📂 Contents of parent directory:"
            ls -la "$parent_dir" | head -10
        else
            echo "❌ Parent directory $parent_dir does not exist either"
        fi
        validated=false
    else
        echo "✅ Download directory exists: ${DOWNLOAD_DIR}"
        
        # Check if directory is empty
        if [ -z "$(ls -A "${DOWNLOAD_DIR}")" ]; then
            echo "⚠️  Warning: Download directory is empty"
            validated=false
        else
            echo "✅ Download directory has content (size: $(du -sh "${DOWNLOAD_DIR}" | cut -f1))"
        fi
        
        # Count model files
        total_model_count=$(find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | wc -l)
        
        if [ "$total_model_count" -eq 0 ]; then
            echo "⚠️  Warning: No model files found in download directory"
            validated=false
        else
            echo "✅ Found $total_model_count model files"
        fi
    fi
    
    # 2. Check for HuggingFace cache structure
    local hf_dirs=$(find "${DOWNLOAD_DIR}" -path "*/models--*" -type d 2>/dev/null | wc -l)
    if [ "$hf_dirs" -gt 0 ]; then
        echo "✅ Found HuggingFace cache structure ($hf_dirs directories)"
        local hf_snapshot_dirs=$(find "${DOWNLOAD_DIR}" -path "*/models--*/snapshots/*" -type d 2>/dev/null | wc -l)
        echo "   - HuggingFace snapshot directories: $hf_snapshot_dirs"
    else
        echo "ℹ️  No HuggingFace cache structure detected"
    fi
    
    # 3. Check available disk space
    local dest_dir="/ComfyUI/models"
    if [ -d "$dest_dir" ]; then
        local available_space_kb=$(df -k "$dest_dir" | tail -1 | awk '{print $4}')
        local available_space_gb=$(echo "scale=2; $available_space_kb/1024/1024" | bc)
        local required_space_gb=$(echo "scale=2; $MIN_FREE_SPACE_GB" | bc)
        
        echo "💾 Available space in destination: ${available_space_gb}GB (minimum required: ${required_space_gb}GB)"
        
        if (( $(echo "$available_space_gb < $required_space_gb" | bc -l) )); then
            echo "❌ Error: Insufficient disk space in destination directory"
            validated=false
        else
            echo "✅ Sufficient disk space available"
        fi
    else
        echo "⚠️  Warning: Destination directory $dest_dir does not exist yet"
    fi
    
    # Return validation result
    if [ "$validated" = true ]; then
        return 0
    else
        return 1
    fi
}

echo "🗂️  Organizing model files from ${DOWNLOAD_DIR}"

# Debug: Show what we're working with
echo "[$(date +%T)] 🔍 Checking download directory structure..."
if [ -d "${DOWNLOAD_DIR}" ]; then
    echo "[$(date +%T)] ✅ Download directory exists: ${DOWNLOAD_DIR}"
    echo "[$(date +%T)] 📂 Directory contents (size: $(du -sh "${DOWNLOAD_DIR}" | cut -f1)):"
    ls -la "${DOWNLOAD_DIR}" || echo "[$(date +%T)] ⚠️  Could not list directory contents"
    
    echo ""
    echo "[$(date +%T)] 🔍 Looking for model files (recursive search up to 4 levels deep)..."
    find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -printf "%p (%kk)\n" | head -10 || echo "[$(date +%T)] ⚠️  No model files found with find command"
else
    echo "❌ Directory ${DOWNLOAD_DIR} does not exist"
    echo "🔍 Debug: Checking parent directories..."
    ls -la /workspace/ || echo "⚠️  Could not list /workspace/"
    exit 0
fi

# Run validation before proceeding
echo "[$(date +%T)] 🔍 Running pre-organization validation..."
if ! validate_environment; then
    echo "[$(date +%T)] ⚠️  Pre-organization validation failed"
    if [ "$DRY_RUN" = false ]; then
        echo "[$(date +%T)] ❓ Do you want to proceed anyway? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "[$(date +%T)] 🛑 Organization aborted by user"
            exit 0
        fi
        echo "[$(date +%T)] ⚠️  Proceeding despite validation warnings..."
    else
        echo "[$(date +%T)] ℹ️  Continuing in dry-run mode..."
    fi
else
    echo "[$(date +%T)] ✅ Pre-organization validation passed"
fi

# Create all ComfyUI model directories
echo "📁 Creating ComfyUI model directories..."
mkdir -p /ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,embeddings,upscale_models}

# Counters for statistics
moved_count=0
failed_count=0
hf_model_count=0
skipped_count=0

# Associative arrays for more detailed statistics
declare -A success_by_type
declare -A failure_by_type
declare -A source_dirs

# Initialize statistics arrays
for type in "Checkpoint" "LoRA" "VAE" "CLIP" "UNET/Flux" "ControlNet" "Embedding" "Upscaler"; do
    success_by_type["$type"]=0
    failure_by_type["$type"]=0
done

# Function to safely move or symlink a file
move_or_link_file() {
    local src_file="$1"
    local dest_file="$2"
    local model_type="$3"
    
    # For HuggingFace cached models, extract a better filename
    if is_huggingface_cache "$src_file"; then
        local original_dest_file="$dest_file"
        local hf_model_info=$(extract_hf_model_info "$src_file")
        local file_ext="${src_file##*.}"
        
        # Use the HF model info for the filename if we could extract it
        if [ -n "$hf_model_info" ] && [ "$hf_model_info" != "$(basename "$src_file")" ]; then
            dest_file="$(dirname "$dest_file")/${hf_model_info}.${file_ext}"
            echo "[$(date +%T)] 🔄 Renamed HF model: $(basename "$src_file") -> $(basename "$dest_file")"
        fi
    fi
    
    echo "[$(date +%T)] 🔄 Processing: $(basename "$src_file") (size: $(du -h "$src_file" | cut -f1)) -> $dest_file"
    
    # Validate source file exists and is readable
    if [ ! -f "$src_file" ]; then
        echo "[$(date +%T)] ❌ Source file missing: $src_file"
        return 1
    fi
    
    if [ ! -r "$src_file" ]; then
        echo "[$(date +%T)] ❌ Source file not readable: $src_file (permissions: $(stat -c "%A %U %G" "$src_file"))"
        return 1
    fi
    
    # Check for existing destination
    if [ -f "$dest_file" ]; then
        echo "[$(date +%T)] ⚠️  File already exists: $(basename "$dest_file") (size: $(du -h "$dest_file" | cut -f1), mtime: $(stat -c "%y" "$dest_file")) (skipping)"
        ((skipped_count++))
        return 0
    fi
    
    # Ensure destination directory exists
    mkdir -p "$(dirname "$dest_file")" || {
        echo "❌ Failed to create destination directory: $(dirname "$dest_file")"
        return 1
    }
    
    # Verify available space
    local required_space=$(du -k "$src_file" | cut -f1)
    local available_space=$(df -k "$(dirname "$dest_file")" | tail -1 | awk '{print $4}')
    
    if [ "$required_space" -gt "$available_space" ]; then
        echo "[$(date +%T)] ❌ Insufficient space: Need $(numfmt --to=iec "$((required_space * 1024))"), only $(numfmt --to=iec "$((available_space * 1024))") available in $(dirname "$dest_file")"
        return 1
    fi
    
    # In dry run mode, only simulate operations
    if [ "$DRY_RUN" = true ]; then
        echo "[$(date +%T)] 🔸 [DRY RUN] Would ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/"
        ((moved_count++))
        return 0
    fi
    
    # Try to create a symlink first (saves space), fallback to copy
    if ln -sf "$src_file" "$dest_file" 2>/dev/null; then
        echo "[$(date +%T)] 🔗 Symlinked ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/ (operation took ${SECONDS}s)"
        ((moved_count++))
        return 0
    fi
    
    # If symlink failed, try copy with verification
    if cp "$src_file" "$dest_file" && cmp -s "$src_file" "$dest_file"; then
        # Calculate copy speed
        local file_size=$(stat -c "%s" "$src_file")
        local speed="N/A"
        if [ $SECONDS -gt 0 ]; then
            speed=$(numfmt --to=iec "$((file_size / SECONDS))")/s
        fi
        
        echo "[$(date +%T)] 📦 Verified copy ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/ (operation took ${SECONDS}s, speed: $speed)"
        ((moved_count++))
        return 0
    else
        local error_code=$?
        local error_msg=$(tail -n1 "$LOG_FILE")
        echo "[$(date +%T)] ❌ Failed to link/copy or verify: $src_file"
        echo "[$(date +%T)]    - Error code: $error_code"
        echo "[$(date +%T)]    - Error message: $error_msg"
        echo "[$(date +%T)]    - File permissions: $(stat -c "%A %U %G" "$src_file")"
        echo "[$(date +%T)]    - Destination permissions: $(stat -c "%A %U %G" "$(dirname "$dest_file")")"
        
        ((failed_count++))
        [ -f "$dest_file" ] && rm -f "$dest_file"
        return 1
    fi
}

# Function to check if a path is part of a HuggingFace cache
is_huggingface_cache() {
    local path="$1"
    
    # Check for HuggingFace cache directory pattern
    if [[ "$path" =~ models--.*--.*/(snapshots|refs)/[^/]+/ ]]; then
        return 0  # True - it is a HF cache path
    else
        return 1  # False - not a HF cache path
    fi
}

# Function to extract model name from HuggingFace cache path
extract_hf_model_info() {
    local path="$1"
    
    # Extract org and model name from HF path format: models--{org}--{model}/snapshots/{hash}/
    if [[ "$path" =~ models--([^-]+)--([^/]+)/(snapshots|refs)/[^/]+/ ]]; then
        local org="${BASH_REMATCH[1]}"
        local model="${BASH_REMATCH[2]}"
        
        # Replace double hyphens with single hyphens
        org="${org//-/_}"
        model="${model//-/_}"
        
        echo "${org}_${model}"
    else
        # If we can't parse it, just return the filename
        basename "$path"
    fi
}

# Enhanced model detection function
classify_model() {
    local filepath="$1"
    local path_lower
    path_lower=$(echo "$filepath" | tr '[:upper:]' '[:lower:]')
    local filename
    filename=$(basename "$filepath" | tr '[:upper:]' '[:lower:]')
    
    # Check file size for additional classification hints
    local filesize
    if [ -f "$filepath" ]; then
        filesize=$(stat -c "%s" "$filepath")
    else
        filesize=0
    fi
    
    # HuggingFace model detection logic
    if is_huggingface_cache "$filepath"; then
        echo "[$(date +%T)] 🤗 Detected HuggingFace cache structure: $filepath"
        
        # Extract model info and use it for better classification
        local model_info
        model_info=$(extract_hf_model_info "$filepath")
        
        # Check for specific model types in the path or filename
        if [[ "$path_lower" =~ lora|adapter|lycoris ]]; then
            echo "/ComfyUI/models/loras|LoRA (HF: $model_info)"
        elif [[ "$path_lower" =~ vae|decoder|autoencoder ]]; then
            echo "/ComfyUI/models/vae|VAE (HF: $model_info)"
        elif [[ "$path_lower" =~ clip|text.?encoder|t5 ]]; then
            echo "/ComfyUI/models/clip|CLIP (HF: $model_info)"
        elif [[ "$path_lower" =~ control.?net ]]; then
            echo "/ComfyUI/models/controlnet|ControlNet (HF: $model_info)"
        elif [[ "$path_lower" =~ upscaler|esrgan|realesrgan ]]; then
            echo "/ComfyUI/models/upscale_models|Upscaler (HF: $model_info)"
        elif [[ "$path_lower" =~ embedding|textual.?inversion|ti_ ]]; then
            echo "/ComfyUI/models/embeddings|Embedding (HF: $model_info)"
        elif [[ "$path_lower" =~ unet|flux|dit|transformer ]]; then
            echo "/ComfyUI/models/unet|UNET/Flux (HF: $model_info)"
        else
            # Check file size for additional hints
            if [ "$filesize" -lt 500000000 ]; then # Less than ~500MB
                # Smaller files are more likely LoRAs, VAEs, etc.
                if [ "$filesize" -lt 50000000 ]; then # Less than ~50MB
                    echo "/ComfyUI/models/embeddings|Embedding (HF: $model_info)"
                else
                    echo "/ComfyUI/models/loras|LoRA (HF: $model_info)"
                fi
            else
                # Default to checkpoint for larger unknown HF models
                echo "/ComfyUI/models/checkpoints|Checkpoint (HF: $model_info)"
            fi
        fi
    else
        # Regular model classification (non-HF)
        case "$path_lower" in
            *lora*|*lycoris*|*adapter*)
                echo "/ComfyUI/models/loras|LoRA" ;;
            *embedding*|*textual_inversion*|*ti_*)
                echo "/ComfyUI/models/embeddings|Embedding" ;;
            *controlnet*|*control_*)
                echo "/ComfyUI/models/controlnet|ControlNet" ;;
            *upscaler*|*esrgan*|*realesrgan*)
                echo "/ComfyUI/models/upscale_models|Upscaler" ;;
            *vae*)
                echo "/ComfyUI/models/vae|VAE" ;;
            *clip*|*t5*|*text_encoder*)
                echo "/ComfyUI/models/clip|CLIP" ;;
            *flux*|*unet*|*dit*|*transformer*)
                echo "/ComfyUI/models/unet|UNET/Flux" ;;
            *)
                # Check file size for additional hints
                if [ "$filesize" -lt 500000000 ]; then # Less than ~500MB
                    # Smaller files are more likely specialized models
                    if [ "$filesize" -lt 50000000 ]; then # Less than ~50MB
                        echo "/ComfyUI/models/embeddings|Embedding (size-based)"
                    else
                        echo "/ComfyUI/models/loras|LoRA (size-based)"
                    fi
                else
                    # Default to checkpoints for larger unknown types
                    echo "/ComfyUI/models/checkpoints|Checkpoint"
                fi
                ;;
        esac
    fi
}

# Function to process a single file (needed for sequential processing)
process_single_file() {
    local filepath="$1"
    
    if [ ! -f "$filepath" ]; then
        echo "[$(date +%T)] ⚠️  File does not exist: $filepath (last modified: $([ -e "$filepath" ] && stat -c "%y" "$filepath" || echo "N/A"))"
        return 0
    fi
    
    echo "[$(date +%T)] 📄 Processing: $(basename "$filepath") (size: $(du -h "$filepath" | cut -f1))"
    
    # Get classification
    classification=$(classify_model "$filepath")
    dest_dir=$(echo "$classification" | cut -d'|' -f1)
    model_type=$(echo "$classification" | cut -d'|' -f2)
    
    filename="$(basename "$filepath")"
    dest_file="${dest_dir}/${filename}"
    
    if move_or_link_file "$filepath" "$dest_file" "$model_type"; then
        return 0
    else
        return 1
    fi
}

# Process files function for parallel execution (batch version)
process_batch() {
    local batch_files="$1"
    batch_size=$(echo "$batch_files" | wc -w)
    echo "[$(date +%T)] 📦 Processing batch of $batch_size files (total size: $(du -ch $batch_files | grep total | cut -f1))"
    
    batch_success=0
    batch_failures=0
    
    # Progress tracking variables
    processed_count=0
    start_time=$(date +%s)
    
    for filepath in $batch_files; do
        if [ ! -f "$filepath" ]; then
            continue
        fi
        
        ((processed_count++))
        echo "[$(date +%T)] 📄 Processing [$processed_count/$batch_size]: $(basename "$filepath") (size: $(du -h "$filepath" | cut -f1))"
        
        # Get classification
        classification=$(classify_model "$filepath")
        dest_dir=$(echo "$classification" | cut -d'|' -f1)
        model_type=$(echo "$classification" | cut -d'|' -f2)
        
        filename="$(basename "$filepath")"
        dest_file="${dest_dir}/${filename}"
        
        # Track source directory for reporting
        src_dir=$(dirname "$filepath")
        source_dirs["$src_dir"]=$((${source_dirs["$src_dir"]:-0} + 1))
        
        # Track HF models
        if [[ "$model_type" == *"HF:"* ]]; then
            ((hf_model_count++))
        fi
        
        if move_or_link_file "$filepath" "$dest_file" "$model_type"; then
            ((batch_success++))
            
            # Extract base model type (remove HF prefix if present)
            local base_type="${model_type%% (*}"
            success_by_type["$base_type"]=$((${success_by_type["$base_type"]:-0} + 1))
        else
            ((batch_failures++))
            
            # Extract base model type (remove HF prefix if present)
            local base_type="${model_type%% (*}"
            failure_by_type["$base_type"]=$((${failure_by_type["$base_type"]:-0} + 1))
        fi
        
        # Calculate and display progress
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        if [ $processed_count -gt 0 ]; then
            remaining=$(( (elapsed * (batch_size - processed_count)) / processed_count ))
            echo "[$(date +%T)] ⏱️  Progress: $processed_count/$batch_size ($(printf "%.1f" "$(echo "scale=2; $processed_count/$batch_size*100" | bc)")%) | Elapsed: ${elapsed}s | Remaining: ~${remaining}s | Rate: $(printf "%.1f" "$(echo "scale=2; $processed_count/$elapsed" | bc)") files/s"
        fi
    done
    
    if [ $batch_failures -gt 0 ]; then
        echo "[$(date +%T)] ⚠️  Batch had $batch_failures failures (success rate: $(printf "%.1f" "$(echo "scale=2; ($batch_size-$batch_failures)/$batch_size*100" | bc)")%)"
        return 1
    fi
    return 0
}

# Export functions for parallel processing
export -f process_batch move_or_link_file classify_model is_huggingface_cache extract_hf_model_info
export -f process_single_file  # Now this function exists!

# Process all model files
echo "[$(date +%T)] 🔍 Scanning for model files (search depth: 4)..."
total_files=0

# Find and process all model files
if [ "$PARALLEL_ENABLED" = true ]; then
    echo "[$(date +%T)] ⚡ Processing files in parallel batches (parallel jobs: $(parallel --number-of-cores))..."
    # Create batches of 10 files each - with recursive search up to 4 levels deep
    find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0 | \
        xargs -0 -n 10 | \
        parallel --bar --joblog /tmp/parallel_joblog --halt soon,fail=1 --progress --eta process_batch
    parallel_exit=$?
    
    if [ $parallel_exit -ne 0 ]; then
        echo "[$(date +%T)] ⚠️  Parallel processing encountered errors (exit code $parallel_exit)"
        echo "[$(date +%T)] 🔍 Check /tmp/parallel_joblog for details"
        echo "[$(date +%T)] Last 5 errors from joblog:"
        tail -n 5 /tmp/parallel_joblog | while read -r line; do
            echo "[$(date +%T)]   $line"
        done
    fi
    
    # Count total files processed
    if [ -f /tmp/parallel_joblog ]; then
        total_files=$(wc -l < /tmp/parallel_joblog)
        ((total_files--)) # Subtract header line
    fi
else
    echo "[$(date +%T)] 🐌 Processing files sequentially (PID: $$)..."
    while IFS= read -r -d '' filepath; do
        ((total_files++))
        process_single_file "$filepath"
    done < <(find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0)
fi

echo ""
echo "[$(date +%T)] 📊 Processing Summary:"
echo "[$(date +%T)]   Total files found: ${total_files}"
echo "[$(date +%T)]   Files organized: ${moved_count} ($(printf "%.1f" "$(echo "scale=2; $moved_count/$total_files*100" | bc)")%)"
echo "[$(date +%T)]   Failed operations: ${failed_count}"
echo "[$(date +%T)]   HuggingFace models detected: ${hf_model_count}"
echo "[$(date +%T)]   Skipped (already exists): ${skipped_count}"
echo "[$(date +%T)]   Log file: $LOG_FILE"

# Display detailed statistics by model type
echo ""
echo "[$(date +%T)] 📊 Model Type Statistics:"
for type in "${!success_by_type[@]}"; do
    total_of_type=$((${success_by_type["$type"]:-0} + ${failure_by_type["$type"]:-0}))
    if [ "$total_of_type" -gt 0 ]; then
        success_rate=$(printf "%.1f" "$(echo "scale=2; ${success_by_type[$type]}/$total_of_type*100" | bc)")
        echo "[$(date +%T)]   - $type: ${success_by_type[$type]} succeeded, ${failure_by_type[$type]} failed ($success_rate% success rate)"
    fi
done

# Display top source directories
echo ""
echo "[$(date +%T)] 📊 Top Source Directories:"
for src_dir in "${!source_dirs[@]}"; do
    if [ "${source_dirs[$src_dir]}" -gt 0 ]; then
        echo "[$(date +%T)]   - $src_dir: ${source_dirs[$src_dir]} files"
    fi
done | sort -rn -k5 | head -5  # Sort by count (numerically) and show top 5

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

# Clean up temporary files created by parallel processing
[ -f "/tmp/parallel_joblog" ] && rm -f "/tmp/parallel_joblog"
find /tmp -name "parallel_*" -user "$(whoami)" -mtime +1 -exec rm -f {} \; 2>/dev/null || true

# Calculate total execution time
end_script_time=$(date +%s)
total_script_time=$((end_script_time - start_script_time))
hours=$((total_script_time / 3600))
minutes=$(( (total_script_time % 3600) / 60 ))
seconds=$((total_script_time % 60))

echo ""
if [ $hours -gt 0 ]; then
    echo "[$(date +%T)] ✅ Organization complete! (Total time: ${hours}h ${minutes}m ${seconds}s)"
elif [ $minutes -gt 0 ]; then
    echo "[$(date +%T)] ✅ Organization complete! (Total time: ${minutes}m ${seconds}s)"
else
    echo "[$(date +%T)] ✅ Organization complete! (Total time: ${seconds}s)"
fi

# Add execution summary
success_rate=0
if [ $total_files -gt 0 ]; then
    success_rate=$(printf "%.1f" "$(echo "scale=2; $moved_count/$total_files*100" | bc)")
fi

# Determine overall status
if [ $failed_count -eq 0 ] && [ $moved_count -gt 0 ]; then
    echo "[$(date +%T)] 🟢 All operations completed successfully! ($moved_count files, $success_rate% success rate)"
elif [ $failed_count -gt 0 ] && [ $moved_count -gt 0 ]; then
    echo "[$(date +%T)] 🟡 Some operations failed ($failed_count failures, $moved_count successes, $success_rate% success rate)"
elif [ $moved_count -eq 0 ]; then
    echo "[$(date +%T)] 🔴 No files were successfully organized. Check errors above."
fi

# Show detailed summary of organized models
echo ""
echo "[$(date +%T)] 📊 Final Model Summary:"
grand_total=0

for model_dir in /ComfyUI/models/*/; do
    if [ -d "$model_dir" ]; then
        file_count=$(find "$model_dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) 2>/dev/null | wc -l)
        link_count=$(find "$model_dir" -maxdepth 1 -type l 2>/dev/null | wc -l)
        total_count=$((file_count + link_count))
        
        if [ "$total_count" -gt 0 ]; then
            dir_name=$(basename "$model_dir")
            grand_total=$((grand_total + total_count))
            
            if [ "$link_count" -gt 0 ]; then
                echo "[$(date +%T)]   📁 ${dir_name}: ${total_count} models (${file_count} files + ${link_count} symlinks, total size: $(du -sh "$model_dir" | cut -f1))"
            else
                echo "[$(date +%T)]   📁 ${dir_name}: ${file_count} models (total size: $(du -sh "$model_dir" | cut -f1))"
            fi
            
            # Show first few model names for verification
            find "$model_dir" -maxdepth 1 \( -type f -o -type l \) \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) 2>/dev/null | head -3 | while read -r model_file; do
                echo "[$(date +%T)]     - $(basename "$model_file") (size: $(du -h "$model_file" | cut -f1), mtime: $(stat -c "%y" "$model_file"))"
            done
            if [ "$total_count" -gt 3 ]; then
                echo "    - ... and $((total_count - 3)) more"
            fi
        fi
    fi
done

echo ""
echo "[$(date +%T)] 🎯 TOTAL MODELS ORGANIZED: ${grand_total} (total size: $(du -sh /ComfyUI/models | cut -f1))"

if [ "$grand_total" -eq 0 ]; then
    echo ""
    echo "[$(date +%T)] ⚠️  WARNING: No models were organized!"
    echo "[$(date +%T)] 🔍 Debug information:"
    echo "[$(date +%T)]   - Download directory: ${DOWNLOAD_DIR}"
    echo "[$(date +%T)]   - Directory exists: $([ -d "${DOWNLOAD_DIR}" ] && echo "YES (size: $(du -sh "${DOWNLOAD_DIR}" | cut -f1))" || echo "NO")"
    echo "[$(date +%T)]   - Files in directory: $(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f | wc -l)"
    echo "[$(date +%T)]   - Model files found: $(find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | wc -l)"
    echo "[$(date +%T)]   - HuggingFace cache directories: $(find "${DOWNLOAD_DIR}" -path "*/models--*" -type d | wc -l)"
    
    # Additional debugging - check if files are in subdirectories
    echo "[$(date +%T)]   - Files in subdirectories:"
    find "${DOWNLOAD_DIR}" -maxdepth 4 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -printf "%p (%kk, modified: %TY-%Tm-%Td %TH:%TM)\n" | head -5
    
    # Check specifically for HuggingFace cache structure
    echo "[$(date +%T)]   - Checking for HuggingFace cache structure:"
    find "${DOWNLOAD_DIR}" -path "*/models--*" -type d | head -5
    find "${DOWNLOAD_DIR}" -path "*/models--*/snapshots/*" -type d | head -5
fi