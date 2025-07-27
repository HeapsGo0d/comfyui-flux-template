#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
# IMPORTANT: Update this to your Docker Hub image name and tag.
readonly IMAGE_NAME="joyc0025/comfyui-flux:v4-definitive-fixed"

# ─── Pre-flight Checks ──────────────────────────────────────────────────────
: "${RUNPOD_API_KEY:?Error: Please set the RUNPOD_API_KEY environment variable.}"
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: This script requires 'jq'. Please install it (e.g., 'sudo apt-get install jq')." >&2
  exit 1
fi
if [[ -z "$IMAGE_NAME" ]]; then
    echo "❌ Error: IMAGE_NAME is not set. Please edit this script and set the variable." >&2
    exit 1
fi

# ─── Template Definition ────────────────────────────────────────────────────
# Define the multi-line readme content.
# Updated for accuracy based on the Dockerfile.
README_CONTENT=$(cat <<'EOF'
## ComfyUI-Flux Template (RTX 5090 Ready)

This template provides a robust environment for running ComfyUI with FLUX models, pre-configured with FileBrowser and JupyterLab for a complete workflow.

### Key Features:
- **Future-Proof GPU Support**: Built on NVIDIA's official PyTorch container (`24.04-py3`) for compatibility with the latest GPUs, including the RTX 40-series and readiness for future architectures like Blackwell (RTX 50-series).
- **Smart Model Organization**: An intelligent script automatically organizes downloaded models from any source (CivitAI, Hugging Face, direct uploads) into the correct ComfyUI directories.
- **Integrated Tools**: Comes with FileBrowser for easy file management across the entire workspace and JupyterLab for development and experimentation.
- **Maximum Security & Privacy**: A comprehensive cleanup script runs on exit to remove all user data, logs, caches, and command history, ensuring no trace is left behind.
- **Optimized Performance**: Leverages the latest versions of PyTorch and xformers for optimal performance.

### Services:
- **ComfyUI**: Port `7860` (Main UI)
- **FileBrowser**: Port `8080` (Full `/workspace` access)
- **JupyterLab**: Port `8888` (Development environment)

### Environment Variables:
- `USE_VOLUME`: Set to `true` to use a persistent volume for `/workspace`.
- `FILEBROWSER`: Set to `true` to enable the FileBrowser service.
- `FB_USERNAME`: FileBrowser username (default: `admin`).
- `FB_PASSWORD`: FileBrowser password (default: auto-generated).
- `CIVITAI_TOKEN`: Your CivitAI API token for model downloads.
- `CHECKPOINT_IDS_TO_DOWNLOAD`: Comma-separated list of checkpoint model IDs.
- `LORA_IDS_TO_DOWNLOAD`: Comma-separated list of LoRA model IDs.
- `VAE_IDS_TO_DOWNLOAD`: Comma-separated list of VAE model IDs.
- `HUGGINGFACE_TOKEN`: Your Hugging Face API token.
- `HUGGINGFACE_REPOS`: Comma-separated list of Hugging Face repos to download (default: `black-forest-labs/FLUX.1-dev`).
- `JUPYTER_TOKEN`: Custom JupyterLab token (optional; defaults to none for RunPod).

### 🔧 Model Organization:
Models are automatically organized into:
- `/ComfyUI/models/unet/` - FLUX transformers, UNets
- `/ComfyUI/models/clip/` - CLIP, T5 text encoders
- `/ComfyUI/models/vae/` - VAE models
- `/ComfyUI/models/loras/` - LoRA files
- `/ComfyUI/models/checkpoints/` - SD checkpoints
- `/ComfyUI/models/controlnet/` - ControlNet models
- `/ComfyUI/models/embeddings/` - Textual inversions

### 🛡️ Security Features:
- Non-root execution with sduser
- Complete trace elimination on exit (proper trap handling)
- Secure credential handling
- History and cache cleanup
- Memory and swap clearing

### 🔧 Technical Details:
- **Base Image**: `nvcr.io/nvidia/pytorch:24.04-py3`
- **Python**: `3.12`
- **PyTorch**: Latest version included in the NVIDIA container.
- **xformers**: Latest version for memory-efficient attention.
- **Security**: Runs as a non-root `sduser`. All services and data are sandboxed.
EOF
)

# Define the GraphQL mutation query.
GRAPHQL_QUERY=$(cat <<'EOF'
mutation saveTemplate($input: SaveTemplateInput!) {
  saveTemplate(input: $input) {
    id
    name
    imageName
    ports
    containerDiskInGb
    volumeInGb
    volumeMountPath
    env { key value }
  }
}
EOF
)

# ─── API Payload Construction ───────────────────────────────────────────────
# Use jq to build the 'input' object for the variables.
# Reduced containerDiskInGb to a more reasonable size.
INPUT_VARIABLES=$(jq -n \
  --arg name "ComfyUI-Flux-RTX5090" \
  --arg imageName "$IMAGE_NAME" \
  --argjson cDisk 25 \
  --argjson vGb 30 \
  --arg vPath "/workspace" \
  --arg dArgs "" \
  --arg ports "7860/http,8080/http,8888/http" \
  --arg readme "$README_CONTENT" \
  '{
    "input": {
      name: $name,
      imageName: $imageName,
      containerDiskInGb: $cDisk,
      volumeInGb: $vGb,
      volumeMountPath: $vPath,
      dockerArgs: $dArgs,
      ports: $ports,
      readme: $readme,
      env: [
        { "key": "USE_VOLUME", "value": "true" },
        { "key": "FILEBROWSER", "value": "true" },
        { "key": "FB_USERNAME", "value": "admin" },
        { "key": "FB_PASSWORD", "value": "{{ RUNPOD_SECRET_FILEBROWSER_PASSWORD }}" },
        { "key": "CIVITAI_TOKEN", "value": "{{ RUNPOD_SECRET_civitai.com }}" },
        { "key": "CHECKPOINT_IDS_TO_DOWNLOAD", "value": "*update*" },
        { "key": "LORA_IDS_TO_DOWNLOAD", "value": "*update*" },
        { "key": "VAE_IDS_TO_DOWNLOAD", "value": "*update*" },
        { "key": "HUGGINGFACE_TOKEN", "value": "{{ RUNPOD_SECRET_huggingface.co }}" },
        { "key": "HUGGINGFACE_REPOS", "value": "black-forest-labs/FLUX.1-dev" },
        { "key": "JUPYTER_TOKEN", "value": "*tokenOrLeaveBlank*" }
      ]
    }
  }')

# Use jq to assemble the final payload with the query and variables.
PAYLOAD=$(jq -n \
  --arg query "$GRAPHQL_QUERY" \
  --argjson variables "$INPUT_VARIABLES" \
  '{query: $query, variables: $variables}')

# ─── API Request ────────────────────────────────────────────────────────────
echo "🚀 Sending request to create/update RunPod template..."
echo "   Image: $IMAGE_NAME"

# Send the request and capture both body + status code
response=$(curl -s -w "\n%{http_code}" \
  -X POST "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD")

# ─── Response Handling ──────────────────────────────────────────────────────
# Parse response
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# Handle errors
if [ "$http_code" -ne 200 ]; then
  echo "❌ HTTP $http_code returned from RunPod API" >&2
  echo "Response body:" >&2
  echo "$body" | jq . >&2
  exit 1
fi

# Pretty-print success
echo "✅ Template created/updated successfully!"
echo "$body" | jq .
echo ""
echo "🎉 Template '$IMAGE_NAME' is ready to use on RunPod."