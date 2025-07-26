# ─── Single-Stage Build with Stable Dependencies ───────────────────────────
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}" \
    CUDA_VISIBLE_DEVICES=0

# Create non-root user first for security
RUN useradd -m -s /bin/bash sduser

# Install system dependencies with retry logic for network stability
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-dev \
        git wget aria2 curl openssl unzip \
        build-essential libglib2.0-0 \
        libjpeg-dev libpng-dev \
        libsm6 libxext6 libxrender-dev libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip to latest
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel

# ✅ STABLE PyTorch Installation (RTX 5090 Compatible)
# PyTorch 2.5.1 stable has full RTX 5090 support - no nightly needed!
RUN pip3 install --no-cache-dir \
    torch==2.5.1+cu124 torchvision==0.20.1+cu124 torchaudio==2.5.1+cu124 \
    --index-url https://download.pytorch.org/whl/cu124

# Verify PyTorch installation immediately
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} installed'); print(f'✅ CUDA available: {torch.cuda.is_available()}')" || \
    (echo "❌ PyTorch installation failed" && exit 1)

# Install stable, compatible dependencies in logical order
RUN pip3 install --no-cache-dir \
    # Core scientific computing
    numpy>=1.24.0 \
    pillow>=9.0.0 \
    # Networking with version constraints to avoid conflicts
    urllib3==1.26.18 \
    requests>=2.28.0 \
    certifi>=2022.12.7 \
    # ML frameworks (order matters for dependency resolution)
    transformers>=4.35.0 \
    accelerate>=0.24.0 \
    huggingface_hub>=0.19.0 \
    einops>=0.7.0

# Install xformers with CUDA 12.4 support (stable version)
RUN pip3 install --no-cache-dir xformers==0.0.28.post2

# Install Jupyter with fixed dependencies
RUN pip3 install --no-cache-dir \
    # Fix the httpx issue you encountered
    httpx==0.24.1 \
    # Jupyter with compatible versions
    jupyterlab==4.0.12 \
    jupyter-server==2.12.5 \
    # Additional useful packages
    comfyui-manager \
    joblib

# Verify all critical imports work
RUN python3 -c "import torch, transformers, PIL, requests, urllib3, xformers; print('✅ All critical packages verified')"

# Install FileBrowser
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser

# Clone repositories (without --depth 1 to avoid git describe issues)
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
    echo 'HISTFILESIZE=0' >> /home/sduser/.bashrc && \
    echo 'unset HISTFILE' >> /home/sduser/.bashrc && \
    echo 'set +o history' >> /home/sduser/.bashrc && \
    echo 'export PYTHONDONTWRITEBYTECODE=1' >> /home/sduser/.bashrc && \
    echo 'export PYTHONHASHSEED=random' >> /home/sduser/.bashrc && \
    echo 'export PYTHONUNBUFFERED=1' >> /home/sduser/.bashrc && \
    echo 'umask 077' >> /home/sduser/.bashrc && \
    echo 'shopt -u histappend' >> /home/sduser/.bashrc && \
    echo 'export LESSHISTFILE=-' >> /home/sduser/.bashrc && \
    echo 'export MYSQL_HISTFILE=/dev/null' >> /home/sduser/.bashrc && \
    echo 'export SQLITE_HISTORY=/dev/null' >> /home/sduser/.bashrc && \
    echo 'export NODE_REPL_HISTORY=""' >> /home/sduser/.bashrc && \
    mkdir -p /home/sduser/.config /home/sduser/.local/share && \
    chmod 700 /home/sduser/.config /home/sduser/.local /home/sduser/.local/share && \
    chmod 600 /home/sduser/.bashrc && \
    touch /home/sduser/.hushlogin && \
    chown -R sduser:sduser /home/sduser

# Switch to non-root user
USER sduser

# Final verification that everything works as sduser
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} ready for RTX 5090')"

# Expose all necessary ports
EXPOSE 7860 8080 8888

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 >/dev/null || exit 1

ENTRYPOINT ["start.sh"]