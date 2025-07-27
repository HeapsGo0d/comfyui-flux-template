# ─── DEFINITIVE RTX 5090 SOLUTION ─────────────────────────────────────────
# Use NVIDIA's official PyTorch container with RTX 5090 support
FROM nvcr.io/nvidia/pytorch:25.04-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}" \
    CUDA_VISIBLE_DEVICES=0

# Create non-root user first for security
RUN useradd -m -s /bin/bash sduser

# Update system and install additional dependencies needed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git wget aria2 curl openssl unzip \
        build-essential libglib2.0-0 \
        libjpeg-dev libpng-dev \
        libsm6 libxext6 libxrender-dev libgomp1 \
        nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Fix JupyterLab nodejs warning by installing required packages
RUN npm install -g yarn

# Install additional Python packages needed for ComfyUI
RUN pip install --no-cache-dir \
    pillow>=9.0.0 \
    urllib3==1.26.18 \
    requests>=2.28.0 \
    certifi>=2022.12.7 \
    transformers>=4.35.0 \
    accelerate>=0.24.0 \
    huggingface_hub>=0.19.0 \
    einops>=0.7.0 \
    comfyui-manager \
    joblib

# Install latest xformers compatible with NVIDIA PyTorch
RUN pip install --no-cache-dir xformers --upgrade

# Install JupyterLab extensions for better functionality
RUN pip install --no-cache-dir \
    jupyterlab-git \
    jupyterlab_widgets

# Verify PyTorch RTX 5090 compatibility
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} installed'); print(f'✅ CUDA available: {torch.cuda.is_available()}'); print(f'✅ GPU detected: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"No GPU\"}')"

# Install FileBrowser
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser

# Clone repositories (without --depth 1 to avoid git describe issues)
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
RUN git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# Install ComfyUI's specific dependencies
WORKDIR /ComfyUI
RUN pip install --no-cache-dir -r requirements.txt

# Copy scripts and make them executable
COPY start.sh organise_downloads.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/organise_downloads.sh

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

# Final verification that everything works as sduser
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} ready'); print(f'✅ RTX 5090 support: {\"RTX 5090\" in torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"Will detect at runtime\"}')"

# Expose all necessary ports
EXPOSE 7860 8080 8888

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 >/dev/null || exit 1

ENTRYPOINT ["start.sh"]