#!/usr/bin/env bash
set -euo pipefail

# 1️⃣ Ensure API key and jq are available
: "${RUNPOD_API_KEY:?Please set RUNPOD_API_KEY}"
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ This script requires 'jq'. Please install it (e.g., 'sudo apt-get install jq')." >&2
  exit 1
fi

# 2️⃣ Define the multi-line readme content. No escaping needed.
README_CONTENT=$(cat <<'EOF'
## ComfyUI-Flux Template

This template runs ComfyUI with Flux models, including optional FileBrowser and JupyterLab.

### Services:
- **ComfyUI**: Port 7860 (main interface)
- **FileBrowser**: Port 8080 (file management) 
- **JupyterLab**: Port 8888 (development, no token required)

### Environment Variables:
- `USE_VOLUME`: Enable persistent storage (true/false)
- `FILEBROWSER`: Enable file browser (true/false)
- `FB_USERNAME`: FileBrowser username (default: admin)
- `FB_PASSWORD`: FileBrowser password (default: changeme)
- `CIVITAI_TOKEN`: CivitAI API token for model downloads
- `CHECKPOINT_IDS_TO_DOWNLOAD`: Comma-separated checkpoint IDs
- `LORA_IDS_TO_DOWNLOAD`: Comma-separated LoRA IDs  
- `VAE_IDS_TO_DOWNLOAD`: Comma-separated VAE IDs
- `HUGGINGFACE_TOKEN`: HuggingFace API token
- `HUGGINGFACE_REPOS`: Comma-separated repo names (default: FLUX.1-dev)
- `JUPYTER_TOKEN`: Custom Jupyter token (optional, defaults to none for RunPod)

### Features:
- Auto-organizes downloaded models into correct ComfyUI folders
- Maximum security - leaves no trace on container exit
- CUDA support for RTX 4090/5090
- XFormers optimization included

### Volume:
- Mount path: `/workspace` 
- Recommended: 20GB+ for model storage
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
  --arg name "ComfyUI-Flux-Template" \
  --arg imageName "joyc0025/comfyui-flux:v1" \
  --argjson cDisk 100 \
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
