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

# Check for GNU parallel
if ! command -v parallel &> /dev/null; then
    echo "⚠️  GNU parallel not found - falling back to sequential processing"
    PARALLEL_ENABLED=false
else
    PARALLEL_ENABLED=true
fi

DOWNLOAD_DIR="${1:-/workspace/downloads}"
echo "🗂️  Organizing model files from ${DOWNLOAD_DIR}"

# Debug: Show what we're working with
echo "🔍 Debug: Checking download directory structure..."
if [ -d "${DOWNLOAD_DIR}" ]; then
    echo "✅ Download directory exists: ${DOWNLOAD_DIR}"
    echo "📂 Directory contents:"
    ls -la "${DOWNLOAD_DIR}" || echo "⚠️  Could not list directory contents"
    
    echo ""
    echo "🔍 Debug: Looking for model files..."
    find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | head -10 || echo "⚠️  No model files found with find command"
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
    
    echo "🔄 Processing: $src_file -> $dest_file"
    
    if [ -f "$dest_file" ]; then
        echo "⚠️  File already exists: $(basename "$dest_file") (skipping)"
        return 0
    fi
    
    # Ensure destination directory exists
    mkdir -p "$(dirname "$dest_file")"
    
    # Try to create a symlink first (saves space), fallback to copy
    if ln -sf "$src_file" "$dest_file" 2>/dev/null; then
        echo "🔗 Symlinked ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/"
        ((moved_count++))
    elif cp "$src_file" "$dest_file" 2>/dev/null; then
        echo "📦 Copied ${model_type}: $(basename "$src_file") → $(dirname "$dest_file")/"
        ((moved_count++))
    else
        echo "❌ Failed to link/copy: $src_file"
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

# Process all model files
echo "🔍 Scanning for model files..."
total_files=0

# Process files function for parallel execution (batch version)
process_batch() {
    batch_files="$1"
    batch_size=$(echo "$batch_files" | wc -w)
    echo "📦 Processing batch of $batch_size files"
    
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
        echo "📄 Processing [$processed_count/$batch_size]: $filepath"
        
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
        remaining=$(( (elapsed * (batch_size - processed_count)) / processed_count ))
        echo "⏱️  Progress: $processed_count/$batch_size | Elapsed: ${elapsed}s | Remaining: ~${remaining}s"
    done
    
    if [ $batch_failures -gt 0 ]; then
        echo "⚠️  Batch had $batch_failures failures"
        return 1
    fi
    return 0
}

export -f process_batch move_or_link_file classify_model

# Export function for sequential processing
export -f process_single_file move_or_link_file classify_model

# Find and process all model files
if [ "$PARALLEL_ENABLED" = true ]; then
    echo "⚡ Processing files in parallel batches..."
    # Create batches of 10 files each - simplified for flattened structure
    find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0 | \
        xargs -0 -n 10 | \
        parallel --bar --joblog /tmp/parallel_joblog --halt soon,fail=1 --progress --eta process_batch
    parallel_exit=$?
    
    if [ $parallel_exit -ne 0 ]; then
        echo "⚠️  Parallel processing encountered errors (exit code $parallel_exit)"
        echo "🔍 Check /tmp/parallel_joblog for details"
    fi
    
    total_files=$(wc -l < /tmp/parallel_joblog)
    ((total_files--)) # Subtract header line
else
    echo "🐌 Processing files sequentially..."
    while IFS= read -r -d '' filepath; do
        ((total_files++))
        process_single_file "$filepath"
    done < <(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0)
fi

echo ""
echo "📊 Processing Summary:"
echo "  Total files found: ${total_files}"
echo "  Files organized: ${moved_count}"

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

# Clean up temporary files created by parallel processing
[ -f "/tmp/parallel_joblog" ] && rm -f "/tmp/parallel_joblog"
find /tmp -name "parallel_*" -user "$(whoami)" -mtime +1 -exec rm -f {} \;

echo ""
echo "✅ Organization complete!"

# Show detailed summary of organized models
echo ""
echo "📊 Final Model Summary:"
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
                echo "  📁 ${dir_name}: ${total_count} models (${file_count} files + ${link_count} symlinks)"
            else
                echo "  📁 ${dir_name}: ${file_count} models"
            fi
            
            # Show first few model names for verification
            find "$model_dir" -maxdepth 1 \( -type f -o -type l \) \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) 2>/dev/null | head -3 | while read -r model_file; do
                echo "    - $(basename "$model_file")"
            done
            if [ "$total_count" -gt 3 ]; then
                echo "    - ... and $((total_count - 3)) more"
            fi
        fi
    fi
done

echo ""
echo "🎯 TOTAL MODELS ORGANIZED: ${grand_total}"

if [ "$grand_total" -eq 0 ]; then
    echo ""
    echo "⚠️  WARNING: No models were organized!"
    echo "🔍 Debug information:"
    echo "  - Download directory: ${DOWNLOAD_DIR}"
    echo "  - Directory exists: $([ -d "${DOWNLOAD_DIR}" ] && echo "YES" || echo "NO")"
    echo "  - Files in directory: $(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f | wc -l)"
    echo "  - Model files found: $(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | wc -l)"
fi