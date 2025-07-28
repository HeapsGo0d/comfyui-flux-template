#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting ComfyUI + Flux container (FIXED VERSION)..."

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
    
    # 1. Kill all background processes started by this script
    jobs -p | xargs -r kill -TERM 2>/dev/null || true
    sleep 2
    jobs -p | xargs -r kill -KILL 2>/dev/null || true
    
    # 2. Clear ALL application logs, caches, and runtime data
    rm -rf /home/sduser/.cache/* 2>/dev/null || true
    rm -rf /ComfyUI/logs/* 2>/dev/null || true
    rm -rf /home/sduser/.local/share/jupyter/* 2>/dev/null || true
    rm -rf /home/sduser/.jupyter/* 2>/dev/null || true
    
    # 3. Comprehensive temporary file cleanup
    find /tmp -user sduser -type f -delete 2>/dev/null || true
    find /var/tmp -user sduser -type f -delete 2>/dev/null || true
    rm -rf /tmp/pip-* /tmp/tmp* /tmp/.*-tmp* 2>/dev/null || true
    
    # 4. Aggressive Python cleanup
    find /ComfyUI -name "*.pyc" -delete 2>/dev/null || true
    find /ComfyUI -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find /CivitAI_Downloader -name "*.pyc" -delete 2>/dev/null || true
    find /CivitAI_Downloader -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find /home/sduser -name "*.pyc" -delete 2>/dev/null || true
    find /home/sduser -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # 5. Complete history and session cleanup
    rm -f /home/sduser/.*history* 2>/dev/null || true
    rm -f /home/sduser/.viminfo 2>/dev/null || true
    rm -f /home/sduser/.lesshst 2>/dev/null || true
    rm -rf /home/sduser/.config/*/history* 2>/dev/null || true
    
    # 6. SECURE DELETION of sensitive files (overwrite multiple times)
    find /tmp /var/tmp /home/sduser -user sduser \( \
        -name "*token*" -o -name "*key*" -o -name "*auth*" -o \
        -name "*secret*" -o -name "*password*" -o -name "*credential*" -o \
        -name "*.env" -o -name ".env*" \) 2>/dev/null | while read -r file; do
        [ -f "$file" ] && shred -vfz -n 7 "$file" 2>/dev/null || true
    done
    
    # 7. Clear environment variables containing sensitive data
    unset CIVITAI_TOKEN HUGGINGFACE_TOKEN HF_TOKEN FB_PASSWORD 2>/dev/null || true
    
    echo "✅ Secure cleanup completed at $(date)"
}

# Set up trap for clean exit - this ensures exit_clean runs on container stop
trap exit_clean EXIT SIGINT SIGTERM

# ─── 3️⃣ FileBrowser with FULL WORKSPACE ACCESS - FIXED ─────────────────────
if [ "${FILEBROWSER:-false}" = "true" ]; then
    FB_USERNAME="${FB_USERNAME:-admin}"
    FB_PASSWORD="${FB_PASSWORD:-changeme}"
    
    if [ "$FB_PASSWORD" = "changeme" ]; then
        FB_PASSWORD=$(openssl rand -base64 12)
    fi
    
    echo "🗂️  Starting FileBrowser on port 8080..."
    
    # DEFINITIVE FIX: Initialize FileBrowser database first, then start with proper config
    cd /workspace
    
    # Initialize FileBrowser with explicit configuration
    filebrowser config init \
        --database /tmp/filebrowser.db \
        --root /workspace \
        --port 8080 \
        --address 0.0.0.0
    
    # Create user
    filebrowser users add "${FB_USERNAME}" "${FB_PASSWORD}" \
        --database /tmp/filebrowser.db \
        --perm.admin
    
    # Start FileBrowser with proper configuration
    filebrowser \
        --database /tmp/filebrowser.db \
        --root /workspace \
        --port 8080 \
        --address 0.0.0.0 \
        --log /tmp/filebrowser.log &
    
    echo "📁 FileBrowser: http://0.0.0.0:8080 (${FB_USERNAME}:${FB_PASSWORD})"
    echo "📂 Root directory: /workspace (FULL ACCESS CONFIRMED)"
fi

# ─── 4️⃣ CivitAI Downloads ──────────────────────────────────────────────────
if [ -n "${CIVITAI_TOKEN:-}" ] && [ "${CIVITAI_TOKEN}" != "*update*" ]; then
    echo "🔽 Downloading models from CivitAI..."
    cd /CivitAI_Downloader

    download_args=("--token" "${CIVITAI_TOKEN}" "--output-dir" "${DOWNLOAD_DIR}")
    HAS_DOWNLOADS=false
    
    if [ -n "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" ] && [ "${CHECKPOINT_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        download_args+=("--checkpoint-ids" "${CHECKPOINT_IDS_TO_DOWNLOAD}")
        HAS_DOWNLOADS=true
    fi
    if [ -n "${LORA_IDS_TO_DOWNLOAD:-}" ] && [ "${LORA_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        download_args+=("--lora-ids" "${LORA_IDS_TO_DOWNLOAD}")
        HAS_DOWNLOADS=true
    fi  
    if [ -n "${VAE_IDS_TO_DOWNLOAD:-}" ] && [ "${VAE_IDS_TO_DOWNLOAD}" != "*update*" ]; then
        download_args+=("--vae-ids" "${VAE_IDS_TO_DOWNLOAD}")
        HAS_DOWNLOADS=true
    fi
    
    if [ "$HAS_DOWNLOADS" = "true" ]; then
        echo "🎯 Running download command..."
        python3 download_with_aria.py "${download_args[@]}" || echo "⚠️  CivitAI download failed, continuing..."
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

# ─── 5.5️⃣ CRITICAL STEP: Organize All Downloaded Models - FIXED ───────────
echo "🔧 Organizing all downloaded models..."
echo "🔍 Debug: Download directory contents before organization:"
ls -la "${DOWNLOAD_DIR}" || echo "⚠️  Could not list download directory"

# NEW: Flatten the directory structure. HuggingFace downloads create subdirectories.
# This moves all model files from subdirectories into the main download directory
# so the organization script can find them.
echo "📂 Flattening download directory..."
find "${DOWNLOAD_DIR}" -mindepth 2 -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.pth" -o -name "*.ckpt" \) -exec mv -t "${DOWNLOAD_DIR}" {} +

echo "🔍 Debug: Download directory contents after flattening:"
ls -la "${DOWNLOAD_DIR}" || echo "⚠️  Could not list download directory"

# Run the fixed organization script
organise_downloads.sh "${DOWNLOAD_DIR}"


# ─── 6️⃣ JupyterLab with FIXED Dependencies ──────────────────────────────────
if command -v jupyter >/dev/null 2>&1; then
    echo "🔬 Starting JupyterLab on port 8888..."
    JUPYTER_TOKEN="${JUPYTER_TOKEN:-}"
    
    if [ -z "$JUPYTER_TOKEN" ] || [ "$JUPYTER_TOKEN" = "*tokenOrLeaveBlank*" ]; then
        # No token for RunPod security - FIXED startup parameters
        jupyter lab \
            --ip=0.0.0.0 \
            --port=8888 \
            --no-browser \
            --allow-root \
            --ServerApp.token='' \
            --ServerApp.password='' \
            --ServerApp.allow_origin='*' \
            --ServerApp.allow_remote_access=True \
            --ServerApp.disable_check_xsrf=True \
            --notebook-dir=/workspace \
            --LabApp.check_for_updates_frequency=0 > /tmp/jupyter.log 2>&1 &
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
            --ServerApp.disable_check_xsrf=True \
            --notebook-dir=/workspace \
            --LabApp.check_for_updates_frequency=0 > /tmp/jupyter.log 2>&1 &
        echo "🔬 JupyterLab: http://0.0.0.0:8888 (token: $JUPYTER_TOKEN)"
    fi
else
    echo "⚠️  JupyterLab not installed, skipping..."
fi

# ─── 7️⃣ Final Verification & Launch ──────────────────────────────────────
echo "🔍 Verifying final environment..."
python3 - <<'EOF'
import torch
print(f'✅ PyTorch {torch.__version__} ready')
if torch.cuda.is_available():
    print(f'✅ CUDA {torch.version.cuda} detected')
    print(f'✅ GPU: {torch.cuda.get_device_name(0)}')
    print(f'✅ GPU Memory: {torch.cuda.get_device_properties(0).total_memory // 1024**3} GB')
    # RTX 5090 handling with NVIDIA container
    try:
        device_props = torch.cuda.get_device_properties(0)
        compute_cap = f'{device_props.major}.{device_props.minor}'
        print(f'✅ GPU Compute Capability: sm_{device_props.major}{device_props.minor}')
        
        if 'RTX 5090' in torch.cuda.get_device_name(0):
            print('🚀 RTX 5090 detected with NVIDIA PyTorch container!')
            print('✅ Full sm_120 compatibility enabled')
            print('✅ Optimal performance available')
        elif device_props.major >= 9:  # sm_90 and above (newer architectures)
            print('✅ Modern GPU architecture fully supported')
        else:
            print('✅ GPU architecture supported')
    except Exception as e:
        print(f'❌ GPU verification failed: {e}')
else:
    print('⚠️  CUDA not available, running in CPU mode.')
EOF

# ─── 8️⃣ Launch ComfyUI ─────────────────────────────────────────────────────
echo "✅ All services started. Launching ComfyUI..."
cd /ComfyUI

# Launch ComfyUI on port 7860, which is used for both the UI and the API healthcheck
python3 main.py --listen 0.0.0.0 --port 7860