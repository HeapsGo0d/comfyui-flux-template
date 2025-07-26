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

# Function to safely move or symlink a file
move_or_link_file() {
    local src_file="$1"
    local dest_file="$2"
    local model_type="$3"
    
    if [ -f "$dest_file" ]; then
        echo "⚠️  File already exists: $(basename "$dest_file") (skipping)"
        return 0
    fi
    
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

# Find and organize .safetensors files
find "${DOWNLOAD_DIR}" -type f -name "*.safetensors" | while read -r filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    filename="$(basename "$filepath")"
    filename_lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"
    
    # Enhanced pattern matching for better model detection
    if [[ "$filename_lower" == *"vae"* ]]; then
        dest_dir="/ComfyUI/models/vae"
        model_type="VAE"
    elif [[ "$filename_lower" == *"flux"* ]] || [[ "$filename_lower" == *"unet"* ]] || [[ "$filename_lower" == *"dit"* ]]; then
        dest_dir="/ComfyUI/models/unet"
        model_type="UNET/Flux"
    elif [[ "$filename_lower" == *"clip"* ]] || [[ "$filename_lower" == *"t5"* ]]; then
        dest_dir="/ComfyUI/models/clip"
        model_type="CLIP"
    elif [[ "$filename_lower" == *"lora"* ]] || [[ "$filename_lower" == *"lycoris"* ]]; then
        dest_dir="/ComfyUI/models/loras"
        model_type="LoRA"
    elif [[ "$filename_lower" == *"embedding"* ]] || [[ "$filename_lower" == *"textual_inversion"* ]] || [[ "$filename_lower" == *"ti_"* ]]; then
        dest_dir="/ComfyUI/models/embeddings"
        model_type="Embedding"
    elif [[ "$filename_lower" == *"controlnet"* ]] || [[ "$filename_lower" == *"control_"* ]]; then
        dest_dir="/ComfyUI/models/controlnet"
        model_type="ControlNet"
    elif [[ "$filename_lower" == *"upscaler"* ]] || [[ "$filename_lower" == *"esrgan"* ]] || [[ "$filename_lower" == *"realesrgan"* ]]; then
        dest_dir="/ComfyUI/models/upscale_models"
        model_type="Upscaler"
    else
        # Default to checkpoints for unknown types
        dest_dir="/ComfyUI/models/checkpoints"
        model_type="Checkpoint"
    fi
    
    # Create destination directory if it doesn't exist
    mkdir -p "$dest_dir"
    
    # Move or link the file
    dest_file="${dest_dir}/${filename}"
    move_or_link_file "$filepath" "$dest_file" "$model_type"
done

# Also handle .ckpt files (legacy checkpoint format)
find "${DOWNLOAD_DIR}" -type f -name "*.ckpt" | while read -r filepath; do
    if [ ! -f "$filepath" ]; then
        continue
    fi
    
    filename="$(basename "$filepath")"
    filename_lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"
    
    # Better classification for .ckpt files
    if [[ "$filename_lower" == *"vae"* ]]; then
        dest_dir="/ComfyUI/models/vae"
        model_type="VAE"
    elif [[ "$filename_lower" == *"controlnet"* ]]; then
        dest_dir="/ComfyUI/models/controlnet"
        model_type="ControlNet"
    else
        dest_dir="/ComfyUI/models/checkpoints"
        model_type="Checkpoint"
    fi
    
    dest_file="${dest_dir}/${filename}"
    mkdir -p "$dest_dir"
    move_or_link_file "$filepath" "$dest_file" "$model_type"
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
    elif [[ "$filename_lower" == *"clip"* ]] || [[ "$filename_lower" == *"t5"* ]]; then
        dest_dir="/ComfyUI/models/clip"
        model_type="CLIP"
    elif [[ "$filename_lower" == *"flux"* ]] || [[ "$filename_lower" == *"unet"* ]]; then
        dest_dir="/ComfyUI/models/unet"
        model_type="UNET"
    elif [[ "$filename_lower" == *"controlnet"* ]]; then
        dest_dir="/ComfyUI/models/controlnet"
        model_type="ControlNet"
    else
        dest_dir="/ComfyUI/models/checkpoints"
        model_type="Checkpoint"
    fi
    
    dest_file="${dest_dir}/${filename}"
    mkdir -p "$dest_dir"
    move_or_link_file "$filepath" "$dest_file" "$model_type"
done

# Handle Hugging Face cached models (they're in subdirectories)
if [ -d "${DOWNLOAD_DIR}/models--black-forest-labs--FLUX.1-dev" ] || [ -d "${DOWNLOAD_DIR}/models--" ]; then
    echo "🤗 Processing Hugging Face cached models..."
    
    # Find all model files in HF cache structure
    find "${DOWNLOAD_DIR}" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.pt" \) | while read -r filepath; do
        if [ ! -f "$filepath" ]; then
            continue
        fi
        
        filename="$(basename "$filepath")"
        filename_lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"
        
        # Skip if already processed above
        if [[ "$filepath" == "${DOWNLOAD_DIR}/"*.* ]]; then
            continue
        fi
        
        # Classify HF models based on path and filename
        if [[ "$filepath" == *"text_encoder"* ]] || [[ "$filename_lower" == *"clip"* ]] || [[ "$filename_lower" == *"t5"* ]]; then
            dest_dir="/ComfyUI/models/clip"
            model_type="CLIP/Text Encoder"
        elif [[ "$filepath" == *"vae"* ]] || [[ "$filename_lower" == *"vae"* ]]; then
            dest_dir="/ComfyUI/models/vae"
            model_type="VAE"
        elif [[ "$filepath" == *"transformer"* ]] || [[ "$filename_lower" == *"flux"* ]] || [[ "$filename_lower" == *"dit"* ]]; then
            dest_dir="/ComfyUI/models/unet"
            model_type="Flux Transformer"
        else
            # Default for unknown HF models
            dest_dir="/ComfyUI/models/checkpoints"
            model_type="HF Model"
        fi
        
        dest_file="${dest_dir}/${filename}"
        mkdir -p "$dest_dir"
        move_or_link_file "$filepath" "$dest_file" "$model_type"
    done
fi

# Clean up empty directories
find "${DOWNLOAD_DIR}" -type d -empty -delete 2>/dev/null || true

echo "✅ Organization complete! Moved/linked ${moved_count} model files"

# Show summary of organized models
echo ""
echo "📊 Model Summary:"
for model_dir in /ComfyUI/models/*/; do
    if [ -d "$model_dir" ]; then
        file_count=$(find "$model_dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.bin" \) 2>/dev/null | wc -l)
        link_count=$(find "$model_dir" -maxdepth 1 -type l 2>/dev/null | wc -l)
        total_count=$((file_count + link_count))
        
        if [ "$total_count" -gt 0 ]; then
            dir_name=$(basename "$model_dir")
            if [ "$link_count" -gt 0 ]; then
                echo "  ${dir_name}: ${total_count} models (${file_count} files + ${link_count} symlinks)"
            else
                echo "  ${dir_name}: ${file_count} models"
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