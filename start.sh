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
mkdir -p /ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,embeddings}

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
    
    # 9. SECURE DELETION of sensitive files (overwrite multiple times)
    find /tmp /var/tmp /home/sduser -user sduser \( \
        -name "*token*" -o -name "*key*" -o -name "*auth*" -o \
        -name "*secret*" -o -name "*password*" -o -name "*credential*" -o \
        -name "*.env" -o -name ".env*" \) 2>/dev/null | while read -r file; do
        [ -f "$file" ] && shred -vfz -n 7 "$file" 2>/dev/null || true
    done
    
    # 10. Clear environment variables containing sensitive data
    unset CIVITAI_TOKEN HUGGINGFACE_TOKEN HF_TOKEN FB_PASSWORD 2>/dev/null || true
    
    echo "✅ [exit_clean] Finished secure cleanup at $(date)"
}
trap exit_clean SIGINT SIGTERM EXIT

# ─── 3️⃣ FileBrowser (Optional) ─────────────────────────────────────────────
if [ "${FILEBROWSER:-false}" = "true" ]; then
    FB_PASSWORD="${FB_PASSWORD:-changeme}"
    if [ "$FB_PASSWORD" = "changeme" ]; then
        FB_PASSWORD=$(openssl rand -base64 12)
    fi
    
    echo "🗂️  Starting FileBrowser on port 8080 (root: /workspace)..."
    filebrowser --root /workspace --port 8080 --address 0.0.0.0 --username "admin" --password "${FB_PASSWORD}" &
    echo "📁 FileBrowser: http://<your-pod-ip>:8080 (admin:${FB_PASSWORD})"
fi

# ─── 4️⃣ CivitAI Downloads ──────────────────────────────────────────────────
if [ -n "${CIVITAI_TOKEN:-}" ] && [ "${CIVITAI_TOKEN}" != "*update*" ]; then
    echo "🔽 Downloading models from CivitAI..."
    cd /CivitAI_Downloader
    
    DOWNLOAD_CMD="python3 download_with_aria.py --token ${CIVITAI_TOKEN} --output-dir ${DOWNLOAD_DIR}"
    HAS_DOWNLOADS=false
    
    if [ -n "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" ]; then
        DOWNLOAD_CMD+=" --checkpoint-ids ${CHECKPOINT_IDS_TO_DOWNLOAD}"
        HAS_DOWNLOADS=true
    fi
    if [ -n "${LORA_IDS_TO_DOWNLOAD:-}" ]; then
        DOWNLOAD_CMD+=" --lora-ids ${LORA_IDS_TO_DOWNLOAD}"
        HAS_DOWNLOADS=true
    fi
    if [ -n "${VAE_IDS_TO_DOWNLOAD:-}" ]; then
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
python3 - <<EOF
import os
from huggingface_hub import snapshot_download

if os.getenv("HUGGINGFACE_TOKEN"):
    os.environ["HF_TOKEN"] = os.getenv("HUGGINGFACE_TOKEN")

repos = os.getenv("HUGGINGFACE_REPOS", "black-forest-labs/FLUX.1-dev").strip()

if repos:
    for repo in repos.split(","):
        repo = repo.strip()
        if repo:
            try:
                print(f"📦 Downloading {repo}...")
                snapshot_download(repo_id=repo, cache_dir="${DOWNLOAD_DIR}", resume_download=True)
                print(f"✅ Downloaded {repo}")
            except Exception as e:
                print(f"❌ Failed to download {repo}: {e}")
EOF

# ─── 5.5️⃣ CRITICAL STEP: Organize All Downloaded Models ───────────────────
echo "🔧 Organizing all downloaded models..."
organise_downloads.sh "${DOWNLOAD_DIR}"

# Show a final summary of all organized models.
echo ""
echo "📊 Final Model Summary:"
for model_dir in /ComfyUI/models/*/; do
    if [ -d "$model_dir" ]; then
        count=$(find "$model_dir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            echo "  $(basename "$model_dir"): ${count} models"
        fi
    fi
done

# ─── 6️⃣ JupyterLab (Optional) ──────────────────────────────────────────────
if command -v jupyter >/dev/null 2>&1; then
    echo "🔬 Starting JupyterLab on port 8888..."
    jupyter lab \
        --ip=0.0.0.0 \
        --port=8888 \
        --no-browser \
        --ServerApp.token='' \
        --ServerApp.password='' \
        --ServerApp.allow_origin='*' \
        --ServerApp.allow_remote_access=True &
fi

# ─── 7️⃣ Final Verification & Launch ──────────────────────────────────────
echo "🔍 Verifying final environment..."
python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} with CUDA {torch.version.cuda} is ready.')"

cd /ComfyUI
echo "🎨 Starting ComfyUI..."
exec python3 launch.py --listen 0.0.0.0 --port 7860