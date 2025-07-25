#!/usr/bin/env bash
DOWNLOAD_DIR="${1:-/workspace/downloads}"
echo "Organising .safetensors from ${DOWNLOAD_DIR}"

find "${DOWNLOAD_DIR}" -type f -name "*.safetensors" | while read -r f; do
  fname="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
  if [[ "$fname" == *vae* ]]; then
    dest="/ComfyUI/models/vae/"
  elif [[ "$fname" == *flux* || "$fname" == *unet* ]]; then
    dest="/ComfyUI/models/unet/"
  elif [[ "$fname" == *clip* ]]; then
    dest="/ComfyUI/models/clip/"
  elif [[ "$fname" == *lora* ]]; then
    dest="/ComfyUI/models/lora/"
  else
    dest="/ComfyUI/models/checkpoints/"
  fi
  echo "Moving $f → $dest"
  mkdir -p "$dest"
  mv "$f" "$dest"
done
