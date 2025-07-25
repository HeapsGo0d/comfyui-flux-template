#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting ComfyUI + Flux container..."

# ... (Sections 1-4 are unchanged) ...
# ... (I have removed them for brevity but they are still there) ...


# ─── 5️⃣ Hugging Face Downloads ─────────────────────────────────────────────
echo "🤗 Downloading models from Hugging Face..."

# CHANGED: Added this line to ensure huggingface_hub is installed and available.
# This is a robust way to fix the "ModuleNotFoundError".
echo "🔧 Verifying huggingface_hub installation..."
python3 -m pip install huggingface_hub

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

# ... (The rest of the script, sections 6-8, are unchanged) ...

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
try:
    from PIL import Image
    print("✅ PIL/Pillow is available")
except ImportError as e:
    print(f"❌ PIL/Pillow missing: {e}")
    print("🔧 Installing Pillow...")
    import subprocess
    subprocess.run([sys.executable, "-m", "pip", "install", "pillow"], check=True)
    print("✅ Pillow installed successfully")

try:
    import torch
    print(f"✅ PyTorch {torch.__version__} is available")
except ImportError as e:
    print(f"❌ PyTorch missing: {e}")

try:
    import transformers
    print(f"✅ Transformers is available")
except ImportError as e:
    print(f"❌ Transformers missing: {e}")
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