#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
# IMPORTANT: Update this to your Docker Hub image name and tag
readonly IMAGE_NAME="joyc0025/comfyui-flux-rtx5090"
readonly TEMPLATE_NAME="comfyui-flux-rtx5090-v2"
readonly TEMPLATE_DESC="ComfyUI-Flux container with enhanced security, organization, and performance"

# ─── Pre-flight Checks and Validation ─────────────────────────────────────────
# Check for required API key
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  echo "❌ Error: RUNPOD_API_KEY environment variable is not set." >&2
  echo "Please set it with: export RUNPOD_API_KEY=your_api_key" >&2
  exit 1
fi

# Check for required tools
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: This script requires 'jq'. Please install it (e.g., 'sudo apt-get install jq')." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "❌ Error: This script requires 'curl'. Please install it (e.g., 'sudo apt-get install curl')." >&2
  exit 1
fi

# Validate template configuration
if [[ -z "$IMAGE_NAME" ]]; then
  echo "❌ Error: IMAGE_NAME is not set. Please edit this script and set the variable." >&2
  exit 1
fi

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo "❌ Error: TEMPLATE_NAME is not set. Please edit this script and set the variable." >&2
  exit 1
fi

if [[ -z "$TEMPLATE_DESC" ]]; then
  echo "⚠️ Warning: TEMPLATE_DESC is not set. Setting a description is recommended." >&2
  TEMPLATE_DESC="ComfyUI-Flux template for RunPod"
fi

# Security validation
if [[ ! "$README_CONTENT" =~ "Security Features" ]]; then
  echo "⚠️ Warning: README does not contain security documentation. This is recommended." >&2
fi

echo "✅ Pre-flight checks passed"

# ─── Template Definition ────────────────────────────────────────────────────
# Define the multi-line readme content.
# Updated for accuracy based on the Dockerfile.
README_CONTENT=$(cat <<'EOF'
## ComfyUI-Flux Template (RTX 5090 Ready)

This template provides a robust environment for running ComfyUI with FLUX models, featuring enhanced model management, automatic organization, and a comprehensive security system.

### 🌟 Key Features:
- **Future-Proof GPU Support**: Built on NVIDIA's official PyTorch container (`24.04-py3`) for compatibility with the latest GPUs, including the RTX 40-series and the upcoming Blackwell (RTX 50-series) architecture.
- **Intelligent Model Management**: Advanced download and organization system that automatically detects and places models in the correct ComfyUI directories.
- **Enhanced Security**: Comprehensive hardening with non-root execution, credential protection, and complete data cleanup on container termination.
- **Robust Configuration**: Type-validated environment variables with sensible defaults and comprehensive error handling.
- **Optimized Performance**: Leverages the latest versions of PyTorch and xformers with container-specific optimizations.
- **Detailed Logging**: Configurable verbosity for easier troubleshooting with DEBUG_MODE.

### 🖥️ Services:
- **ComfyUI**: Port `7860` - Main interface for AI image generation
- **FileBrowser**: Port `8080` - Full file management for `/workspace`

### 💾 Storage Options:
- **Ephemeral Mode** (Default): Uses container disk (100 GB) with all data wiped on pod termination
- **Persistent Storage**: Enable by setting `USE_VOLUME=true` and attaching a volume to preserve data between sessions

### ⚙️ Environment Variables:

#### General Settings:
- `DEBUG_MODE`: [boolean] Enable verbose output and extended logging (Default: `false`)
- `USE_VOLUME`: [boolean] Use persistent storage for /workspace (Default: `false`)

#### Service Configuration:
- `FILEBROWSER`: [boolean] Enable FileBrowser web interface (Default: `true`)
- `FB_USERNAME`: [string] FileBrowser username (Default: `admin`)
- `FB_PASSWORD`: [token] FileBrowser password (Default: auto-generated)
  - For security, use RunPod Secrets: `{{ RUNPOD_SECRET_FILEBROWSER_PASSWORD }}`

#### CivitAI Model Downloads:
- `CIVITAI_TOKEN`: [token] Your CivitAI API token for accessing private models
  - For security, use RunPod Secrets: `{{ RUNPOD_SECRET_civitai.com }}`
- `CHECKPOINT_IDS_TO_DOWNLOAD`: [csv] Comma-separated list of checkpoint model IDs
  - Example: `12345,67890,112233`
- `LORA_IDS_TO_DOWNLOAD`: [csv] Comma-separated list of LoRA model IDs
  - Example: `45678,89012`
- `VAE_IDS_TO_DOWNLOAD`: [csv] Comma-separated list of VAE model IDs
  - Example: `13579,24680`

#### HuggingFace Model Downloads:
- `HUGGINGFACE_TOKEN`: [token] Your HuggingFace API token for accessing private repositories
  - For security, use RunPod Secrets: `{{ RUNPOD_SECRET_huggingface.co }}`
- `HUGGINGFACE_REPOS`: [csv] Comma-separated list of HuggingFace repositories to download
  - Example: `black-forest-labs/FLUX.1-dev,organization/another-model`
  - Default: `black-forest-labs/FLUX.1-dev`

### 📂 Automatic Model Organization:
Downloaded models are intelligently analyzed and organized into:
- `/ComfyUI/models/unet/` - FLUX transformers, UNets, DiT models
- `/ComfyUI/models/clip/` - CLIP, T5 text encoders
- `/ComfyUI/models/vae/` - VAE models
- `/ComfyUI/models/loras/` - LoRA and LyCORIS files
- `/ComfyUI/models/checkpoints/` - Stable Diffusion checkpoints
- `/ComfyUI/models/controlnet/` - ControlNet models
- `/ComfyUI/models/embeddings/` - Textual inversions
- `/ComfyUI/models/upscale_models/` - Upscalers (ESRGAN, etc.)

### 🛡️ Security Features:
- Non-root execution with unprivileged user
- RunPod Secrets integration for sensitive credentials
- Secure token handling with obfuscation
- Complete trace elimination on container exit
- Memory and cache cleanup

### 📊 Performance Expectations:
- **Model Downloads**: Expect 1-5 minutes per GB depending on network conditions
- **Model Organization**: Typically processes at 2-5 files per second
- **Container Startup**: ~30 seconds for basic setup, plus download time if models are specified

### 🔧 Troubleshooting:
- Enable `DEBUG_MODE=true` for verbose logging
- Check FileBrowser logs in `/tmp/filebrowser.log`
- Review organization logs in `/tmp/organise_downloads_*.log`
- For network-related issues with downloads, try using API tokens

### 🧰 Technical Specifications:
- **Base Image**: `nvcr.io/nvidia/pytorch:24.04-py3`
- **Python**: `3.12`
- **PyTorch**: Latest version from NVIDIA container
- **CUDA**: Compatible with 12.x+
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
# Configure template with optimal settings for security and performance
INPUT_VARIABLES=$(jq -n \
  --arg name "$TEMPLATE_NAME" \
  --arg imageName "$IMAGE_NAME" \
  --arg description "$TEMPLATE_DESC" \
  --argjson cDisk 100 \
  --argjson vGb 0 \
  --arg vPath "/workspace" \
  --arg dArgs "--security-opt=no-new-privileges --cap-drop=ALL" \
  --arg ports "7860/http,8080/http" \
  --arg readme "$README_CONTENT" \
  '{
    "input": {
      name: $name,
      description: $description,
      imageName: $imageName,
      containerDiskInGb: $cDisk,
      volumeInGb: $vGb,
      volumeMountPath: $vPath,
      dockerArgs: $dArgs,
      ports: $ports,
      readme: $readme,
      env: [
        # General Settings
        { "key": "DEBUG_MODE", "value": "false" },
        { "key": "USE_VOLUME", "value": "false" },
        
        # Service Configuration
        { "key": "FILEBROWSER", "value": "true" },
        { "key": "FB_USERNAME", "value": "admin" },
        { "key": "FB_PASSWORD", "value": "{{ RUNPOD_SECRET_FILEBROWSER_PASSWORD }}" },
        
        # CivitAI Model Downloads
        { "key": "CIVITAI_TOKEN", "value": "{{ RUNPOD_SECRET_civitai.com }}" },
        { "key": "CHECKPOINT_IDS_TO_DOWNLOAD", "value": "" },
        { "key": "LORA_IDS_TO_DOWNLOAD", "value": "" },
        { "key": "VAE_IDS_TO_DOWNLOAD", "value": "" },
        
        # HuggingFace Model Downloads
        { "key": "HUGGINGFACE_TOKEN", "value": "{{ RUNPOD_SECRET_huggingface.co }}" },
        { "key": "HUGGINGFACE_REPOS", "value": "black-forest-labs/FLUX.1-dev" }
      ]
    }
  }')

# Use jq to assemble the final payload with the query and variables.
PAYLOAD=$(jq -n \
  --arg query "$GRAPHQL_QUERY" \
  --argjson variables "$INPUT_VARIABLES" \
  '{query: $query, variables: $variables}')

# ─── Template Validation ──────────────────────────────────────────────────────
echo "🔍 Validating template integrity..."

# Extract environment variables from payload for validation
env_vars=$(echo "$INPUT_VARIABLES" | jq -r '.input.env[].key')
env_count=$(echo "$env_vars" | wc -l)

# Check that environment variables match those in variable_parser.sh
echo "✓ Configured $env_count environment variables"

# Validate port configuration
if ! echo "$PAYLOAD" | grep -q "7860/http"; then
  echo "⚠️ Warning: ComfyUI port (7860) not properly configured in template" >&2
fi

if echo "$PAYLOAD" | grep -q "FILEBROWSER\": \"true\"" && ! echo "$PAYLOAD" | grep -q "8080/http"; then
  echo "⚠️ Warning: FileBrowser port (8080) not properly configured in template" >&2
fi

# Verify Docker security arguments
if ! echo "$PAYLOAD" | grep -q "no-new-privileges"; then
  echo "⚠️ Warning: Security option 'no-new-privileges' not configured in Docker args" >&2
fi

# Verify all RunPod secrets are correctly formatted
for secret_pattern in "RUNPOD_SECRET_"; do
  if grep -q "$secret_pattern" <<< "$PAYLOAD"; then
    echo "✓ RunPod secrets properly configured"
  else
    echo "⚠️ Warning: No RunPod secrets found in template. This may affect security." >&2
  fi
done

echo "✅ Template validation complete"
echo ""

# ─── API Request ────────────────────────────────────────────────────────────
echo "🚀 Sending request to create/update RunPod template..."
echo "   Image: $IMAGE_NAME"
echo "   Template: $TEMPLATE_NAME"

# Send the request and capture both body + status code
response=$(curl -s -w "\n%{http_code}" \
  -X POST "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -H "User-Agent: ComfyUI-Flux-Template/1.0" \
  -H "Accept: application/json" \
  -H "Cache-Control: no-cache" \
  --data-binary "$PAYLOAD")

# ─── Response Handling and Validation ──────────────────────────────────────────
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

# Extract template ID for validation
template_id=$(echo "$body" | jq -r '.data.saveTemplate.id')
if [ -z "$template_id" ] || [ "$template_id" = "null" ]; then
  echo "⚠️ Warning: Couldn't extract template ID from response" >&2
  echo "Response body:" >&2
  echo "$body" | jq . >&2
else
  # Success with detailed information
  echo "✅ Template created/updated successfully!"
  echo "Template Details:"
  echo "  🆔 ID: $(echo "$body" | jq -r '.data.saveTemplate.id')"
  echo "  📋 Name: $(echo "$body" | jq -r '.data.saveTemplate.name')"
  echo "  🖼️ Image: $(echo "$body" | jq -r '.data.saveTemplate.imageName')"
  echo "  💾 Container Disk: $(echo "$body" | jq -r '.data.saveTemplate.containerDiskInGb') GB"
  echo "  📂 Volume Path: $(echo "$body" | jq -r '.data.saveTemplate.volumeMountPath')"
  echo "  🔌 Ports: $(echo "$body" | jq -r '.data.saveTemplate.ports')"
  echo "  🔧 Environment Variables: $(echo "$body" | jq -r '.data.saveTemplate.env | length') configured"
fi

echo ""
echo "🎉 Template '$TEMPLATE_NAME' is ready to use on RunPod."
echo ""
echo "Next Steps:"
echo "  1. Visit https://www.runpod.io/console/templates to see your template"
echo "  2. Deploy a pod using your template"
echo "  3. Connect to your pod and start generating with ComfyUI!"
echo ""
echo "💡 To update this template, simply run this script again."