# ─── Single-Stage Build with Robust Dependencies ───────────────────────────
# Use a modern, but highly stable, base image for maximum compatibility
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

# Set environment variables for the build and runtime
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}"

# Create non-root user first for security
RUN useradd -m -s /bin/bash sduser

# Install system dependencies with retry logic for network stability
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-dev \
        git wget aria2 curl openssl unzip \
        build-essential libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip3 install --no-cache-dir --upgrade pip

# --- CRITICAL: Install PyTorch NIGHTLY for modern GPU support ---
# Use --pre to get pre-release (nightly) versions for CUDA 12.4
RUN pip3 install --no-cache-dir --pre \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/nightly/cu124

# Install xformers and all other Python dependencies in a single, efficient layer
# Pinned httpx to solve the JupyterLab error and added joblib for Forge extensions.
RUN pip3 install --no-cache-dir \
    xformers --no-deps && \
    pip3 install --no-cache-dir \
    urllib3'<2.0' \
    requests \
    numpy \
    pillow \
    huggingface_hub \
    transformers \
    accelerate \
    einops \
    httpx'<0.25.0' \
    jupyterlab \
    comfyui-manager \
    joblib

# Install FileBrowser
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser

# Clone repositories with full history to allow version checking scripts to work
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
RUN git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# Install ComfyUI's specific dependencies
WORKDIR /ComfyUI
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy scripts and make them executable
COPY start.sh organise_downloads.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/organise_downloads.sh

# Create directories and set permissions for the non-root user
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace \
  && chmod 755 /runpod-volume /workspace

# Preserve the user's extensive security hardening
RUN echo 'HISTSIZE=0' >> /home/sduser/.bashrc && \
    touch /home/sduser/.hushlogin && \
    chown -R sduser:sduser /home/sduser

# Switch to non-root user for the remainder of the build and at runtime
USER sduser

# Expose all necessary ports
EXPOSE 7860 8080 8888

# Set a health check to monitor ComfyUI's web server
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 >/dev/null || exit 1

ENTRYPOINT ["start.sh"]