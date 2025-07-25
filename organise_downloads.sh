#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_DIR="${1:-/workspace/downloads}"
echo "🗂️  Organizing .safetensors files from ${DOWNLOAD_DIR}"

# Check if directory exists
if [ ! -d "${DOWNLOAD_DIR}" ]; then
    echo "⚠️  Directory ${DOWNLOAD_DIR} does not exist, skipping organization"
    exit 0
fi

# Counter for moved files
moved_count=0

# Find and organize .safetensors files
find "${DOWNLOAD_DIR}" -type f -name "*.safetensors" | while read -r filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    filename="$(basename "$filepath")"
    filename_lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"
    
    # Determine destination based on filename patterns
    if [[ "$filename_lower" == *"vae"* ]]; then
        dest_dir="/ComfyUI/models/vae"
        model_type="VAE"
    elif [[ "$filename_lower" == *"flux"* ]] || [[ "$filename_lower" == *"unet"* ]]; then
        dest_dir="/ComfyUI/models/unet"
        model_type="UNET/Flux"
    elif [[ "$filename_lower" == *"clip"* ]]; then
        dest_dir="/ComfyUI/models/clip"
        model_type="CLIP"
    elif [[ "$filename_lower" == *"lora"* ]]; then
        dest_dir="/ComfyUI/models/loras"
        model_type="LoRA"
    elif [[ "$filename_lower" == *"embedding"* ]] || [[ "$filename_lower" == *"textual_inversion"* ]]; then
        dest_dir="/ComfyUI/models/embeddings"
        model_type="Embedding"
    elif [[ "$filename_lower" == *"controlnet"* ]]; then
        dest_dir="/ComfyUI/models/controlnet"
        model_type="ControlNet"
    else
        # Default to checkpoints for unknown types
        dest_dir="/ComfyUI/models/checkpoints"
        model_type="Checkpoint"
    fi
    
    # Create destination directory if it doesn't exist
    mkdir -p "$dest_dir"
    
    # Check if file already exists at destination
    dest_file="${dest_dir}/${filename}"
    if [ -f "$dest_file" ]; then
        echo "⚠️  File already exists: ${filename} (skipping)"
        continue
    fi
    
    # Move the file
    echo "📦 Moving ${model_type}: ${filename} → ${dest_dir}/"
    if mv "$filepath" "$dest_file"; then
        ((moved_count++))
    else
        echo "❌ Failed to move: $filepath"
    fi
done

# Also handle .ckpt files (legacy checkpoint format)
find "${DOWNLOAD_DIR}" -type f -name "*.ckpt" | while read -r filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    filename="$(basename "$filepath")"
    dest_dir="/ComfyUI/models/checkpoints"
    dest_file="${dest_dir}/${filename}"
    
    mkdir -p "$dest_dir"
    
    if [ -f "$dest_file" ]; then
        echo "⚠️  File already exists: ${filename} (skipping)"
        continue
    fi
    
    echo "📦 Moving Checkpoint: ${filename} → ${dest_dir}/"
    if mv "$filepath" "$dest_file"; then
        ((moved_count++))
    else
        echo "❌ Failed to move: $filepath"
    fi
done

# Handle .pt and .pth files (PyTorch models)
find "${DOWNLOAD_DIR}" -type f \( -name "*.pt" -o -name "*.pth" \) | while read -r filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    filename="$(basename "$filepath")"
    filename_lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"
    
    if [[ "$filename_lower" == *"vae"* ]]; then
        dest_dir="/ComfyUI/models/vae"
        model_type="VAE"
    elif [[ "$filename_lower" == *"clip"* ]]; then
        dest_dir="/ComfyUI/models/clip"
        model_type="CLIP"
    else
        dest_dir="/ComfyUI/models/checkpoints"
        model_type="Checkpoint"
    fi
    
    dest_file="${dest_dir}/${filename}"
    mkdir -p "$dest_dir"
    
    if [ -f "$dest_file" ]; then
        echo "⚠️  File already exists: ${filename} (skipping)"
        continue
    fi
    
    echo "📦 Moving ${model_type}: ${filename} → ${dest_dir}/"
    if mv "$filepath" "$dest_file"; then
        ((moved_count++))
    else
        echo "❌ Failed to move: $filepath"
    fi
done

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

echo "✅ Organization complete! Moved ${moved_count} model files"

# Show summary of organized models
echo ""
echo "📊 Model Summary:"
for model_dir in /ComfyUI/models/*/; do
    if [ -d "$model_dir" ]; then
        count=$(find "$model_dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" \) | wc -l)
        if [ "$count" -gt 0 ]; then
            dir_name=$(basename "$model_dir")
            echo "  ${dir_name}: ${count} files"
        fi
    fi
done