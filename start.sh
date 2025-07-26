#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting ComfyUI + Flux container..."

# ─── 1️⃣ Directory Setup ───────────────────────────────────────────────────
if [ "${USE_VOLUME:-false}" = "true" ]; then
    BASEDIR="/runpod-volume"
    echo "📁 Using persistent volume: ${BASEDIR}"
else
    BASEDIR="/workspace"
    echo "📁 Using workspace: ${BASEDIR}"
fi

DOWNLOAD_DIR="${BASEDIR}/downloads"
mkdir -p "${DOWNLOAD_DIR}"

# Create ComfyUI model directories
mkdir -p /ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,embeddings,upscale_models}

# ─── 2️⃣ MAXIMUM Security/Privacy Cleanup - Leave No Trace ─────────────────
exit_clean() {
    echo "🔒 Starting comprehensive no-trace cleanup..."
    
    # 1. Clear ALL application logs, caches, and runtime data
    rm -rf /home/sduser/.cache/* 2>/dev/null || true
    rm -rf /ComfyUI/logs/* 2>/dev/null || true
    rm -rf /home/sduser/.local/share/jupyter/* 2>/dev/null || true
    rm -rf /home/sduser/.jupyter/* 2>/dev/null || true
    
    # 2. Comprehensive temporary file cleanup
    find /tmp -user sduser -type f -delete 2>/dev/null || true
    find /var/tmp -user sduser -type f -delete 2>/dev/null || true
    rm -rf /tmp/pip-* /tmp/tmp* /tmp/.*-tmp* 2>/dev/null || true
    
    # 3. Aggressive Python cleanup
    find /ComfyUI -name "*.pyc" -delete 2>/dev/null || true
    find /ComfyUI -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find /CivitAI_Downloader -name "*.pyc" -delete 2>/dev/null || true
    find /CivitAI_Downloader -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find /home/sduser -name "*.pyc" -delete 2>/dev/null || true
    find /home/sduser -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # 4. Complete history and session cleanup
    rm -f /home/sduser/.*history* 2>/dev/null || true
    rm -f /home/sduser/.viminfo 2>/dev/null || true
    rm -f /home/sduser/.lesshst 2>/dev/null || true
    rm -rf /home/sduser/.config/*/history* 2>/dev/null || true
    
    # 5. SECURE DELETION of sensitive files (overwrite multiple times)
    find /tmp /var/tmp /home/sduser -user sduser \( \
        -name "*token*" -o -name "*key*" -o -name "*auth*" -o \
        -name "*secret*" -o -name "*password*" -o -name "*credential*" -o \
        -name "*.env" -o -name ".env*" \) 2>/dev/null | while read -r file; do
        [ -f "$file" ] && shred -vfz -n 7 "$file" 2>/dev/null || true
    done
    
    # 6. Clear environment variables containing sensitive data
    unset CIVITAI_TOKEN HUGGINGFACE_TOKEN HF_TOKEN FB_PASSWORD 2>/dev/null || true
    
    echo "✅ [exit_clean] Finished secure cleanup at $(date)"
}
trap exit_clean SIGINT SIGTERM EXIT

# ─── 3️⃣ FileBrowser (Optional) ─────────────────────────────────────────────
if [ "${FILEBROWSER:-false}" = "true" ]; then
    FB_USERNAME="${FB_USERNAME:-admin}"
    FB_PASSWORD="${FB_PASSWORD:-changeme}"
    
    if [ "$FB_PASSWORD" = "changeme" ]; then
        FB_PASSWORD=$(openssl rand -base64 12)
    fi
    
    echo "🗂️  Starting FileBrowser on port 8080 (root: /workspace)..."
    filebrowser --root /workspace --port 8080 --address 0.0.0.0 --username "${FB_USERNAME}" --password "${FB_PASSWORD}" --noauth=false &
    echo "📁 FileBrowser: http://0.0.0.0:8080 (${FB_USERNAME}:${FB_PASSWORD})"
fi

# ─── 4️⃣ CivitAI Downloads ──────────────────────────────────────────────────
if [ -n "${CIVITAI_TOKEN:-}" ] && [ "${CIVITAI_TOKEN}" != "*update*" ]; then
    echo "🔽 Downloading models from CivitAI..."
    cd /CivitAI_Downloader
    
    DOWNLOAD_CMD="python3 download_with_aria.py --token ${CIVITAI_TOKEN} --output-dir ${DOWNLOAD_DIR}"
    HAS_DOWNLOADS=false
    
    if [ -n "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" ] && [ "${CHECKPOINT_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        DOWNLOAD_CMD+=" --checkpoint-ids ${CHECKPOINT_IDS_TO_DOWNLOAD}"
        HAS_DOWNLOADS=true
    fi
    if [ -n "${LORA_IDS_TO_DOWNLOAD:-}" ] && [ "${LORA_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        DOWNLOAD_CMD+=" --lora-ids ${LORA_IDS_TO_DOWNLOAD}"
        HAS_DOWNLOADS=true
    fi  
    if [ -n "${VAE_IDS_TO_DOWNLOAD:-}" ] && [ "${VAE_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        DOWNLOAD_CMD+=" --vae-ids ${VAE_IDS_TO_DOWNLOAD}"
        HAS_DOWNLOADS=true
    fi
    
    if [ "$HAS_DOWNLOADS" = "true" ]; then
        echo "🎯 Running download command..."
        eval ${DOWNLOAD_CMD} || echo "⚠️  CivitAI download failed, continuing..."
    else
        echo "⚠️  No valid CivitAI model IDs specified, skipping..."
    fi
    
    cd - > /dev/null
else
    echo "⚠️  No CivitAI token provided, skipping CivitAI downloads..."
fi

# ─── 5️⃣ Hugging Face Downloads ─────────────────────────────────────────────
echo "🤗 Downloading models from Hugging Face..."

# Ensure huggingface_hub is available
python3 -c "import huggingface_hub; print('✅ huggingface_hub available')" || \
    python3 -m pip install --user huggingface_hub

python3 - <<EOF
import os
from huggingface_hub import snapshot_download

# Set token if available
if "${HUGGINGFACE_TOKEN:-}" and "${HUGGINGFACE_TOKEN}" != "*tokenOrLeaveBlank*":
    os.environ["HF_TOKEN"] = "${HUGGINGFACE_TOKEN}"

repos = os.getenv("HUGGINGFACE_REPOS", "black-forest-labs/FLUX.1-dev").strip()

if repos:
    for repo in repos.split(","):
        repo = repo.strip()
        if repo:
            try:
                print(f"📦 Downloading {repo}...")
                snapshot_download(
                    repo_id=repo, 
                    cache_dir="${DOWNLOAD_DIR}", 
                    resume_download=True,
                    token=os.environ.get("HF_TOKEN")
                )
                print(f"✅ Downloaded {repo}")
            except Exception as e:
                print(f"❌ Failed to download {repo}: {e}")
                continue
EOF

# ─── 5.5️⃣ CRITICAL STEP: Organize All Downloaded Models ───────────────────
echo "🔧 Organizing all downloaded models..."
organise_downloads.sh "${DOWNLOAD_DIR}"

# Show a final summary of all organized models
echo ""
echo "📊 Final Model Summary:"
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
        fi
    fi
done

# ─── 6️⃣ JupyterLab (Optional) ──────────────────────────────────────────────
if command -v jupyter >/dev/null 2>&1; then
    echo "🔬 Starting JupyterLab on port 8888..."
    JUPYTER_TOKEN="${JUPYTER_TOKEN:-}"
    
    if [ -z "$JUPYTER_TOKEN" ] || [ "$JUPYTER_TOKEN" = "*tokenOrLeaveBlank*" ]; then
        # No token for RunPod security
        jupyter lab \
            --ip=0.0.0.0 \
            --port=8888 \
            --no-browser \
            --allow-root \
            --ServerApp.token='' \
            --ServerApp.password='' \
            --ServerApp.allow_origin='*' \
            --ServerApp.allow_remote_access=True \
            --ServerApp.disable_check_xsrf=True &
        echo "🔬 JupyterLab: http://0.0.0.0:8888 (no token required)"
    else
        jupyter lab \
            --ip=0.0.0.0 \
            --port=8888 \
            --no-browser \
            --allow-root \
            --ServerApp.token="$JUPYTER_TOKEN" \
            --ServerApp.allow_origin='*' \
            --ServerApp.allow_remote_access=True \
            --ServerApp.disable_check_xsrf=True &
        echo "🔬 JupyterLab: http://0.0.0.0:8888 (token: $JUPYTER_TOKEN)"
    fi
else
    echo "⚠️  JupyterLab not installed, skipping..."
fi

# ─── 7️⃣ Final Verification & Launch ──────────────────────────────────────
echo "🔍 Verifying final environment..."
python3 -c "
import torch
print(f'✅ PyTorch {torch.__version__} ready')
if torch.cuda.is_available():
    print(f'✅ CUDA {torch.version.cuda} detected')
    print(f'✅ GPU: {torch.cuda.get_device_name(0)}')
    print(f'✅ GPU Memory: {torch.cuda.get_device_properties(0).total_memory // 1024**3}GB')
else:
    print('⚠️  CUDA not available')
"

# Try to import ComfyUI to verify everything is working
python3 -c "
try:
    import comfy.utils
    print('✅ ComfyUI imports successful')
except ImportError as e:
    print(f'⚠️  ComfyUI import issue: {e}')
    print('This might be normal - will try to start anyway')
"

cd /ComfyUI
echo "🎨 Starting ComfyUI on port 7860..."

# Auto-detect the correct entrypoint
if [ -f launch.py ]; then
    echo "🚀 Found launch.py, starting..."
    exec python3 launch.py --listen 0.0.0.0 --port 7860
elif [ -f main.py ]; then
    echo "🚀 Found main.py, starting..."  
    exec python3 main.py --listen 0.0.0.0 --port 7860
elif [ -f app.py ]; then
    echo "🚀 Found app.py, starting..."
    exec python3 app.py --listen 0.0.0.0 --port 7860
else
    echo "❌ No valid entrypoint found (launch.py, main.py, app.py)" >&2
    echo "📂 Available files:"
    ls -la
    exit 1
fi