#!/usr/bin/env bash
set -euo pipefail

# 1️⃣ Ensure API key and jq are available
: "${RUNPOD_API_KEY:?Please set RUNPOD_API_KEY}"
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ This script requires 'jq'. Please install it (e.g., 'sudo apt-get install jq')." >&2
  exit 1
fi

# 2️⃣ Define the multi-line readme content with FIXES
README_CONTENT=$(cat <<'EOF'
## ComfyUI-Flux Template (RTX 5090 Compatible) - FIXED VERSION

This template runs ComfyUI with Flux models, including FileBrowser and JupyterLab.
**✅ FIXED: Full RTX 5090 support, proper FileBrowser access, stable JupyterLab**

### 🔧 Recent FIXES Applied:
- **RTX 5090 Support**: PyTorch nightly with sm_120 compatibility 
- **FileBrowser**: Full /workspace access (not just downloads)
- **JupyterLab**: Fixed httpx/anyio version conflicts 
- **Exit Cleanup**: Proper trap handling for secure cleanup
- **Model Detection**: Better model organization and verification

### Services:
- **ComfyUI**: Port 7860 (main interface)
- **FileBrowser**: Port 8080 (FULL /workspace access with proper auth) 
- **JupyterLab**: Port 8888 (development, fixed dependencies)

### 🚀 Key Features:
- **RTX 4090/5090 Support**: CUDA 12.4 with PyTorch nightly (sm_120 compatible)
- **Smart Model Organization**: Auto-detects and organizes all model types
- **HuggingFace Integration**: Downloads and symlinks FLUX.1-dev models
- **CivitAI Support**: Downloads checkpoints, LoRAs, VAEs with API token
- **Maximum Security**: Complete trace elimination on container exit (FIXED)
- **Optimized Performance**: Latest XFormers with CUDA acceleration

### Environment Variables:
- `USE_VOLUME`: Enable persistent storage (true/false)
- `FILEBROWSER`: Enable file browser (true/false)
- `FB_USERNAME`: FileBrowser username (default: admin)
- `FB_PASSWORD`: FileBrowser password (default: auto-generated)
- `CIVITAI_TOKEN`: CivitAI API token for model downloads
- `CHECKPOINT_IDS_TO_DOWNLOAD`: Comma-separated checkpoint IDs
- `LORA_IDS_TO_DOWNLOAD`: Comma-separated LoRA IDs  
- `VAE_IDS_TO_DOWNLOAD`: Comma-separated VAE IDs
- `HUGGINGFACE_TOKEN`: HuggingFace API token
- `HUGGINGFACE_REPOS`: Comma-separated repo names (default: FLUX.1-dev)
- `JUPYTER_TOKEN`: Custom Jupyter token (optional, defaults to none for RunPod)

### 🔧 Model Organization:
Models are automatically organized into:
- `/ComfyUI/models/unet/` - FLUX transformers, UNets
- `/ComfyUI/models/clip/` - CLIP, T5 text encoders
- `/ComfyUI/models/vae/` - VAE models
- `/ComfyUI/models/loras/` - LoRA files
- `/ComfyUI/models/checkpoints/` - SD checkpoints
- `/ComfyUI/models/controlnet/` - ControlNet models
- `/ComfyUI/models/embeddings/` - Textual inversions

### 🛡️ Security Features (FIXED):
- Non-root execution with sduser
- Complete trace elimination on exit (proper trap handling)
- Secure credential handling
- History and cache cleanup
- Memory and swap clearing

### 📁 FileBrowser Access (FIXED):
- **Full /workspace access** (not limited to downloads)
- Proper database configuration
- Secure authentication
- File management for all ComfyUI directories

### Volume:
- Mount path: `/workspace` 
- Recommended: 30GB+ for FLUX models
- FileBrowser provides full filesystem access

### 🔧 Technical Details:
- Base: CUDA 12.4 + Ubuntu 22.04
- PyTorch: Nightly build (RTX 5090 sm_120 compatible)
- XFormers: Latest version optimized for new GPUs
- Python: 3.10 with fixed dependency versions
- JupyterLab: 4.2.5 with compatible httpx/anyio versions
EOF
)

# 3️⃣ Define the GraphQL mutation query, using a variable placeholder '$input'.
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

# 4️⃣ Use jq to build the 'input' object for the variables.
INPUT_VARIABLES=$(jq -n \
  --arg name "ComfyUI-Flux-RTX5090-FIXED" \
  --arg imageName "joyc0025/comfyui-flux:v3-rtx5090-fixed" \
  --argjson cDisk 120 \
  --argjson vGb 0 \
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
        { key: "USE_VOLUME", value: "false" },
        { key: "FILEBROWSER", value: "true" },
        { key: "FB_USERNAME", value: "admin" },
        { key: "FB_PASSWORD", value: "{{ RUNPOD_SECRET_FILEBROWSER_PASSWORD }}" },
        { key: "CIVITAI_TOKEN", value: "{{ RUNPOD_SECRET_civitai.com }}" },
        { key: "CHECKPOINT_IDS_TO_DOWNLOAD", value: "*update*" },
        { key: "LORA_IDS_TO_DOWNLOAD", value: "*update*" },
        { key: "VAE_IDS_TO_DOWNLOAD", value: "*update*" },
        { key: "HUGGINGFACE_TOKEN", value: "{{ RUNPOD_SECRET_huggingface.co }}" },
        { key: "HUGGINGFACE_REPOS", value: "black-forest-labs/FLUX.1-dev" },
        { key: "JUPYTER_TOKEN", value: "*tokenOrLeaveBlank*" }
      ]
    }
  }')

# 5️⃣ Use jq to assemble the final payload with the query and variables.
PAYLOAD=$(jq -n \
  --arg query "$GRAPHQL_QUERY" \
  --argjson variables "$INPUT_VARIABLES" \
  '{query: $query, variables: $variables}')

# 6️⃣ Send the request and capture both body + status
response=$(curl -s -w "\n%{http_code}" \
  -X POST "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD")

# 7️⃣ Parse response
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# 8️⃣ Handle errors
if [ "$http_code" -ne 200 ]; then
  echo "❌ HTTP $http_code returned from RunPod API" >&2
  echo "Response body:" >&2
  echo "$body" | jq . >&2
  exit 1
fi

# 9️⃣ Pretty-print success
echo "✅ Template created successfully!"
echo "$body" | jq .
echo ""
echo "🚀 FIXED issues in this version:"
echo "  ✅ RTX 5090 support (PyTorch nightly with sm_120)"
echo "  ✅ FileBrowser with FULL /workspace access"
echo "  ✅ JupyterLab with fixed httpx/anyio versions"
echo "  ✅ Proper exit cleanup with trap handling"
echo "  ✅ Enhanced model organization and detection"
echo "  ✅ Better error handling and logging"