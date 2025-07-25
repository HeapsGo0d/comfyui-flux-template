#!/usr/bin/env bash
set -euo pipefail

# 1️⃣ Base directory
if [ "${USE_VOLUME:-false}" = "true" ]; then
  BASEDIR="/runpod-volume"
else
  BASEDIR="/workspace"
fi
DOWNLOAD_DIR="${BASEDIR}/downloads"
mkdir -p "${DOWNLOAD_DIR}"

# 2️⃣ Cleanup on exit
exit_clean() {
  echo "🧹 Cleaning cache and logs..."
  rm -rf /home/sduser/.cache/*
  rm -rf /ComfyUI/logs/*
}
trap exit_clean SIGINT SIGTERM EXIT

# 3️⃣ FileBrowser (optional)
if [ "${FILEBROWSER:-false}" = "true" ]; then
  filebrowser \
    --root "${BASEDIR}" \
    --port 8080 \
    --username "${FILEBROWSER_USERNAME:-admin}" \
    --password "${FILEBROWSER_PASSWORD:-admin}" &
fi

# 4️⃣ CivitAI Downloads
if [ -n "${CIVITAI_TOKEN:-}" ]; then
  echo "🔽 Downloading from CivitAI..."
  cd /CivitAI_Downloader
  python3 download_with_aria.py \
    --token "${CIVITAI_TOKEN}" \
    --checkpoint-ids "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" \
    --vae-ids "${VAE_IDS_TO_DOWNLOAD:-}" \
    --lora-ids "${LORA_IDS_TO_DOWNLOAD:-}"
  cd -
  organise_downloads.sh "${DOWNLOAD_DIR}"
fi

# 5️⃣ Hugging Face Downloads
if [ -n "${HUGGINGFACE_TOKEN:-}" ]; then
  echo "🔽 Downloading from Hugging Face..."
  python3 - <<EOF
from huggingface_hub import snapshot_download
import os
os.environ["HF_TOKEN"] = "${HUGGINGFACE_TOKEN}"
repos = os.getenv("HUGGINGFACE_REPOS","black-forest-labs/FLUX.1-dev")
for repo in repos.split(","):
    snapshot_download(repo, cache_dir="${DOWNLOAD_DIR}", token=os.environ["HF_TOKEN"])
EOF
  organise_downloads.sh "${DOWNLOAD_DIR}"
fi

# 6️⃣ Launch JupyterLab
JUPYTER_TOKEN=${JUPYTER_TOKEN:-$(openssl rand -base64 16)}
jupyter lab \
  --ip=0.0.0.0 \
  --no-browser \
  --NotebookApp.token="${JUPYTER_TOKEN}" &
echo "✨ JupyterLab at http://0.0.0.0:8888?token=${JUPYTER_TOKEN}"

# 7️⃣ Launch ComfyUI
cd /ComfyUI
if [ -f launch.py ]; then
  python3 launch.py
elif [ -f main.py ]; then
  python3 main.py
elif [ -f app.py ]; then
  python3 app.py
elif [ -f server.js ]; then
  node server.js
else
  echo "❌ No entrypoint found" >&2
  exit 1
fi
