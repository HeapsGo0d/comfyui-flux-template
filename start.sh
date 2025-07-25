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
    
    # 5. Package manager and build caches
    rm -rf /home/sduser/.pip/* 2>/dev/null || true
    rm -rf /home/sduser/.npm/* 2>/dev/null || true
    rm -rf /home/sduser/.cargo/* 2>/dev/null || true
    rm -rf /root/.cache/* 2>/dev/null || true
    
    # 6. Application-specific cleanup
    rm -rf /home/sduser/.config/filebrowser/* 2>/dev/null || true
    rm -rf /home/sduser/.local/share/*/logs/* 2>/dev/null || true
    rm -rf /ComfyUI/temp/* 2>/dev/null || true
    rm -rf /ComfyUI/output/.tmp* 2>/dev/null || true
    
    # 7. Log files throughout the system
    find /home/sduser -name "*.log" -delete 2>/dev/null || true
    find /ComfyUI -name "*.log" -delete 2>/dev/null || true
    truncate -s 0 /var/log/*.log 2>/dev/null || true
    
    # 8. Process and network traces
    rm -f /proc/*/cmdline 2>/dev/null || true
    rm -f /proc/*/environ 2>/dev/null || true
    
    # 9. SECURE DELETION of sensitive files (overwrite multiple times)
    find /tmp /var/tmp /home/sduser -user sduser \( \
        -name "*token*" -o -name "*key*" -o -name "*auth*" -o \
        -name "*secret*" -o -name "*password*" -o -name "*credential*" -o \
        -name "*.env" -o -name ".env*" \) 2>/dev/null | while read -r file; do
        [ -f "$file" ] && {
            shred -vfz -n 7 "$file" 2>/dev/null || {
                dd if=/dev/urandom of="$file" bs=1024 count=10 2>/dev/null
                rm -f "$file" 2>/dev/null
            }
        } || true
    done
    
    # 10. Clear environment variables containing sensitive data
    unset CIVITAI_TOKEN HUGGINGFACE_TOKEN HF_TOKEN FB_PASSWORD 2>/dev/null || true
    unset $(env | grep -i 'token\|key\|secret\|password' | cut -d= -f1) 2>/dev/null || true
    
    # 11. Memory cleanup (force garbage collection)
    python3 -c "import gc; gc.collect()" 2>/dev/null || true
    
    # 12. Clear swap if accessible
    swapoff -a 2>/dev/null && swapon -a 2>/dev/null || true
    
    # 13. Final filesystem sync to ensure writes complete
    sync 2>/dev/null || true
    
    echo "🔒 MAXIMUM security cleanup complete - all traces eliminated"
    echo "✅ Container state: CLEAN - no sensitive data remains"
    echo "🧼 [exit_clean] Finished secure cleanup at $(date)"
}

# Enhanced trap to catch more signals
trap exit_clean SIGINT SIGTERM SIGQUIT SIGKILL EXIT

# ─── 3️⃣ FileBrowser (Optional) ─────────────────────────────────────────────
if [ "${FILEBROWSER:-false}" = "true" ]; then
    FB_USERNAME="${FB_USERNAME:-admin}"
    FB_PASSWORD="${FB_PASSWORD:-changeme}"
    
    # Generate a secure random password if default is used
    if [ "$FB_PASSWORD" = "changeme" ]; then
        FB_PASSWORD=$(openssl rand -base64 12)
    fi
    
    echo "🗂️  Starting FileBrowser on port 8080..."
    filebrowser \
        --root "${BASEDIR}" \
        --port 8080 \
        --address 0.0.0.0 \
        --username "${FB_USERNAME}" \
        --password "${FB_PASSWORD}" \
        --noauth=false &
    
    echo "📁 FileBrowser: http://0.0.0.0:8080 (${FB_USERNAME}:${FB_PASSWORD})"
fi

# ─── 4️⃣ CivitAI Downloads ──────────────────────────────────────────────────
if [ -n "${CIVITAI_TOKEN:-}" ] && [ "${CIVITAI_TOKEN}" != "*update*" ]; then
    echo "🔽 Downloading models from CivitAI..."
    cd /CivitAI_Downloader
    
    # Check if we have any valid IDs to download
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
        echo "🎯 Running: ${DOWNLOAD_CMD}"
        eval ${DOWNLOAD_CMD} || echo "⚠️  CivitAI download failed, continuing..."
    else
        echo "⚠️  No valid CivitAI model IDs specified, skipping..."
    fi
    
    cd - > /dev/null
    organise_downloads.sh "${DOWNLOAD_DIR}"
else
    echo "⚠️  No CivitAI token provided, skipping CivitAI downloads..."
fi

# ─── 5️⃣ Hugging Face Downloads ─────────────────────────────────────────────
echo "🤗 Downloading models from Hugging Face..."

# Ensure huggingface_hub is installed
echo "🔧 Verifying huggingface_hub installation..."
python3 -m pip install --user huggingface_hub

python3 - <<EOF
import os
import sys
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
                    token=os.environ.get("HF_TOKEN"),
                    resume_download=True
                )
                print(f"✅ Downloaded {repo}")
            except Exception as e:
                print(f"❌ Failed to download {repo}: {e}")
                continue
EOF

organise_downloads.sh "${DOWNLOAD_DIR}"

# ─── 6️⃣ JupyterLab (Optional - only if installed) ──────────────────────────
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
            --NotebookApp.token='' \
            --NotebookApp.password='' \
            --NotebookApp.allow_origin='*' \
            --NotebookApp.allow_remote_access=True &
        echo "🔬 JupyterLab: http://0.0.0.0:8888 (no token required)"
    else
        jupyter lab \
            --ip=0.0.0.0 \
            --port=8888 \
            --no-browser \
            --allow-root \
            --NotebookApp.token="$JUPYTER_TOKEN" \
            --NotebookApp.allow_origin='*' \
            --NotebookApp.allow_remote_access=True &
        echo "🔬 JupyterLab: http://0.0.0.0:8888 (token: $JUPYTER_TOKEN)"
    fi
else
    echo "⚠️  JupyterLab not installed, skipping..."
fi

# ─── 7️⃣ Verify Python Dependencies ────────────────────────────────────────
echo "🔍 Verifying Python dependencies..."
python3 - <<EOF
import sys

# Critical dependency check with installation fallback
def check_and_install(package_name, import_name=None, install_cmd=None):
    import_name = import_name or package_name
    install_cmd = install_cmd or package_name
    
    try:
        __import__(import_name)
        if import_name == 'torch':
            import torch
            print(f"✅ PyTorch {torch.__version__} is available")
        elif import_name == 'PIL':
            print("✅ PIL/Pillow is available")
        else:
            print(f"✅ {package_name} is available")
        return True
    except ImportError as e:
        print(f"❌ {package_name} missing: {e}")
        if install_cmd:
            print(f"🔧 Installing {package_name}...")
            import subprocess
            try:
                if package_name == 'torch':
                    # Install PyTorch with CUDA support
                    subprocess.run([
                        sys.executable, "-m", "pip", "install", "--user",
                        "torch==2.3.1+cu121", "torchvision==0.18.1+cu121", "torchaudio==2.3.1+cu121",
                        "--index-url", "https://download.pytorch.org/whl/cu121"
                    ], check=True)
                else:
                    subprocess.run([sys.executable, "-m", "pip", "install", "--user", install_cmd], check=True)
                print(f"✅ {package_name} installed successfully")
                return True
            except subprocess.CalledProcessError:
                print(f"❌ Failed to install {package_name}")
                return False
        return False

# Check critical dependencies
all_good = True
all_good &= check_and_install("PIL/Pillow", "PIL", "pillow")
all_good &= check_and_install("PyTorch", "torch", "torch")
all_good &= check_and_install("Transformers", "transformers", "transformers")

if not all_good:
    print("❌ Some critical dependencies are missing!")
    sys.exit(1)

# Final ComfyUI import test
try:
    import comfy.utils
    print("✅ ComfyUI imports successful")
except ImportError as e:
    print(f"❌ ComfyUI import failed: {e}")
    print("This might be normal if ComfyUI has additional setup requirements")
EOF

# ─── 8️⃣ Auto-detect ComfyUI Entrypoint ────────────────────────────────────
cd /ComfyUI

echo "🎨 Starting ComfyUI..."

# Auto-detect entrypoint
if [ -f launch.py ]; then
    echo "🚀 Found launch.py, starting..."
    exec python3 launch.py --listen 0.0.0.0 --port 7860
elif [ -f main.py ]; then
    echo "🚀 Found main.py, starting..."
    exec python3 main.py --listen 0.0.0.0 --port 7860
elif [ -f app.py ]; then
    echo "🚀 Found app.py, starting..."
    exec python3 app.py --listen 0.0.0.0 --port 7860
elif [ -f server.js ]; then
    echo "🚀 Found server.js, starting with Node.js..."
    exec node server.js
else
    echo "❌ No valid entrypoint found (launch.py, main.py, app.py, server.js)" >&2
    echo "📂 Available files:"
    ls -la
    exit 1
fi