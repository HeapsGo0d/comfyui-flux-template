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

# Logging setup
LOG_FILE="/tmp/organise_downloads_$(date +%Y%m%d_%H%M%S).log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== STARTING ORGANISE_DOWNLOADS ==="
echo "Timestamp: $(date)"
echo "PID: $$"
echo "User: $(whoami)"
echo "Host: $(hostname)"

# Check for GNU parallel
if ! command -v parallel &> /dev/null; then
    echo "[$(date +%T)] ⚠️  GNU parallel not found - falling back to sequential processing"
    PARALLEL_ENABLED=false
else
    echo "[$(date +%T)] ✅ GNU parallel found (version: $(parallel --version | head -n1))"
    PARALLEL_ENABLED=true
fi

DOWNLOAD_DIR="${1:-/workspace/downloads}"
echo "🗂️  Organizing model files from ${DOWNLOAD_DIR}"

# Debug: Show what we're working with
echo "[$(date +%T)] 🔍 Checking download directory structure..."
if [ -d "${DOWNLOAD_DIR}" ]; then
    echo "[$(date +%T)] ✅ Download directory exists: ${DOWNLOAD_DIR}"
    echo "[$(date +%T)] 📂 Directory contents (size: $(du -sh "${DOWNLOAD_DIR}" | cut -f1)):"
    ls -la "${DOWNLOAD_DIR}" || echo "[$(date +%T)] ⚠️  Could not list directory contents"
    
    echo ""
    echo "[$(date +%T)] 🔍 Looking for model files..."
    find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -printf "%p (%kk)\n" | head -10 || echo "[$(date +%T)] ⚠️  No model files found with find command"
else
    echo "❌ Directory ${DOWNLOAD_DIR} does not exist"
    echo "🔍 Debug: Checking parent directories..."
    ls -la /workspace/ || echo "⚠️  Could not list /workspace/"
    exit 0
fi

# Create all ComfyUI model directories
echo "📁 Creating ComfyUI model directories..."
mkdir -p /ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,embeddings,upscale_models}

# Counter for moved files
moved_count=0

# Function to safely move or symlink a file
move_or_link_file() {
    local src_file="$1"
    local dest_file="$2"
    local model_type="$3"
    
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
    
    # Try to create a symlink first (saves space), fallback to copy
    if ln -sf "$src_file" "$dest_file" 2>/dev/null; then
        echo "[$(date +%T)] 🔗 Symlinked ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/ (operation took ${SECONDS}s)"
        ((moved_count++))
        return 0
    fi
    
    # If symlink failed, try copy with verification
    if cp "$src_file" "$dest_file" && cmp -s "$src_file" "$dest_file"; then
        echo "[$(date +%T)] 📦 Verified copy ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/ (operation took ${SECONDS}s, speed: $(numfmt --to=iec "$(($(stat -c %s "$src_file") / SECONDS))")/s)"
        ((moved_count++))
        return 0
    else
        echo "[$(date +%T)] ❌ Failed to link/copy or verify: $src_file (exit code: $?, last error: $(tail -n1 "$LOG_FILE"))"
        [ -f "$dest_file" ] && rm -f "$dest_file"
        return 1
    fi
}

# Enhanced model detection function
classify_model() {
    local path_lower
    path_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$path_lower" in
        *lora*|*lycoris*)
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
            # Default to checkpoints for unknown types
            echo "/ComfyUI/models/checkpoints|Checkpoint" ;;
    esac
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
        
        if move_or_link_file "$filepath" "$dest_file" "$model_type"; then
            ((batch_success++))
        else
            ((batch_failures++))
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
export -f process_batch move_or_link_file classify_model
export -f process_single_file  # Now this function exists!

# Process all model files
echo "[$(date +%T)] 🔍 Scanning for model files (search depth: 1)..."
total_files=0

# Find and process all model files
if [ "$PARALLEL_ENABLED" = true ]; then
    echo "[$(date +%T)] ⚡ Processing files in parallel batches (parallel jobs: $(parallel --number-of-cores))..."
    # Create batches of 10 files each - simplified for flattened structure
    find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0 | \
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
    done < <(find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0)
fi

echo ""
echo "[$(date +%T)] 📊 Processing Summary:"
echo "[$(date +%T)]   Total files found: ${total_files}"
echo "[$(date +%T)]   Files organized: ${moved_count} ($(printf "%.1f" "$(echo "scale=2; $moved_count/$total_files*100" | bc)")%)"
echo "[$(date +%T)]   Log file: $LOG_FILE"

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

# Clean up temporary files created by parallel processing
[ -f "/tmp/parallel_joblog" ] && rm -f "/tmp/parallel_joblog"
find /tmp -name "parallel_*" -user "$(whoami)" -mtime +1 -exec rm -f {} \; 2>/dev/null || true

echo ""
echo "[$(date +%T)] ✅ Organization complete! (Total time: $(($(date +%s) - start_script_time))s)"

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
    echo "[$(date +%T)]   - Model files found: $(find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | wc -l)"
    
    # Additional debugging - check if files are in subdirectories
    echo "[$(date +%T)]   - Files in subdirectories:"
    find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -printf "%p (%kk, modified: %TY-%Tm-%Td %TH:%TM)\n" | head -5
fi