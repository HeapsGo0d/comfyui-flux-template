#!/usr/bin/env bash
set -euo pipefail

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
    find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | head -10 || echo "⚠️  No model files found with find command"
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

# Find all model files and process them
while IFS= read -r -d '' filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    ((total_files++))
    echo "📄 Found file: $filepath"
    
    # Get classification
    classification=$(classify_model "$filepath")
    dest_dir=$(echo "$classification" | cut -d'|' -f1)
    model_type=$(echo "$classification" | cut -d'|' -f2)
    
    filename="$(basename "$filepath")"
    dest_file="${dest_dir}/${filename}"
    
    move_or_link_file "$filepath" "$dest_file" "$model_type"
    
done < <(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) -print0)

echo ""
echo "📊 Processing Summary:"
echo "  Total files found: ${total_files}"
echo "  Files organized: ${moved_count}"

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

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
    echo "  - Files in directory: $(find "${DOWNLOAD_DIR}" -type f | wc -l)"
    echo "  - Model files found: $(find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) | wc -l)"
fi