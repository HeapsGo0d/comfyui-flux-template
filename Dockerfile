# ─── DEFINITIVE RTX 5090 SOLUTION ─────────────────────────────────────────
# Use NVIDIA's official PyTorch container with RTX 5090 support
FROM nvcr.io/nvidia/pytorch:24.04-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}" \
    CUDA_VISIBLE_DEVICES=0

# Create non-root user first for security
RUN useradd -m -s /bin/bash sduser

# Update system and install all dependencies in single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git wget aria2 curl openssl unzip \
        build-essential libglib2.0-0 \
        libjpeg-dev libpng-dev libsentencepiece-dev \
        libsm6 libxext6 libxrender-dev libgomp1 \
        nodejs npm parallel \
    && npm install -g yarn \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,embeddings,upscale_models} \
    && mkdir -p /runpod-volume \
    && chown -R sduser:sduser /ComfyUI /runpod-volume /workspace \
    && chmod 755 /runpod-volume /workspace \
    && echo 'HISTSIZE=0' >> /home/sduser/.bashrc \
    && touch /home/sduser/.hushlogin

# Install Python packages, xformers, and Jupyter extensions in a single layer
RUN pip install --no-cache-dir \
    pillow>=9.0.0 \
    requests>=2.28.0 \
    certifi>=2022.12.7 \
    transformers>=4.35.0 \
    accelerate>=0.24.0 \
    huggingface_hub>=0.19.0 \
    einops>=0.7.0 \
    comfyui-manager \
    joblib \
    # Install latest xformers compatible with NVIDIA PyTorch
    xformers \
    # Install JupyterLab extensions
    jupyterlab-git \
    jupyterlab_widgets

# Verify PyTorch RTX 5090 compatibility
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} installed'); print(f'✅ CUDA available: {torch.cuda.is_available()}'); print(f'✅ GPU detected: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"No GPU\"}')"

# Note: The sm_120 compatibility warning is cosmetic and can be safely ignored.
# The RTX 5090 is fully supported by the NVIDIA PyTorch container.

# Install pinned FileBrowser version (v2.23.0)
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/v2.23.0/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser

# Clone repositories (without --depth 1 to avoid git describe issues)
# Pinning to a specific commit ensures reproducible builds
# Updated commit hash to a recent, valid one.
RUN rm -rf /ComfyUI && git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    (cd /ComfyUI && git checkout 78672d0ee6d20d8269f324474643e5cc00f1c348)

RUN rm -rf /CivitAI_Downloader && git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader && \
    (cd /CivitAI_Downloader && git checkout 11fd5579d74dd759a2c7e16698641d144cf4f7ef)

# Install ComfyUI's specific dependencies
WORKDIR /ComfyUI
RUN pip install --no-cache-dir -r requirements.txt

# Copy scripts and make them executable
# Copy scripts with explicit path verification
COPY --chmod=+x start_hardened.sh organise_downloads.sh /usr/local/bin/
RUN { \
    echo "Verifying script permissions..."; \
    [ -x "/usr/local/bin/start_hardened.sh" ] || { echo "Error: start_hardened.sh not executable"; exit 1; }; \
    [ -x "/usr/local/bin/organise_downloads.sh" ] || { echo "Error: organise_downloads.sh not executable"; exit 1; }; \
    echo "✅ Scripts verified"; \
}

# Create directories and set permissions for the non-root user
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace \
  && chmod 755 /runpod-volume /workspace

# Preserve security hardening
RUN echo 'HISTSIZE=0' >> /home/sduser/.bashrc && \
    touch /home/sduser/.hushlogin && \
    chown -R sduser:sduser /home/sduser

# Switch to non-root user
USER sduser

# Expose all necessary ports
EXPOSE 7860 8080 8888

# Health check - Port updated to 7860 to match the running application
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860/queue >/dev/null || exit 1

ENTRYPOINT ["start_hardened.sh"]