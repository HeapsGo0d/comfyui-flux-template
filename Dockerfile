# ─── Single-Stage Build with Robust Dependencies ───────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0" \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}"

# Create non-root user first
RUN useradd -m -s /bin/bash sduser

# System dependencies with retry logic
RUN for i in 1 2 3; do \
        apt-get update && break || sleep 30; \
    done && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-dev \
        git wget aria2 curl openssl unzip \
        build-essential \
        libjpeg-dev libpng-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Upgrade pip and install Python packages with robust dependency resolution
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel

# Install PyTorch first (most critical)
RUN pip3 install --no-cache-dir \
    torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
    --index-url https://download.pytorch.org/whl/cu121

# Verify PyTorch installation immediately
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} installed successfully')"

# Create a comprehensive requirements file to handle all dependencies at once
RUN echo "urllib3>=1.21.1" > /tmp/requirements.txt && \
    echo "requests>=2.25.1" >> /tmp/requirements.txt && \
    echo "certifi>=2017.4.17" >> /tmp/requirements.txt && \
    echo "charset-normalizer>=2.0.0" >> /tmp/requirements.txt && \
    echo "idna>=2.5" >> /tmp/requirements.txt && \
    echo "numpy>=1.21.0" >> /tmp/requirements.txt && \
    echo "pillow>=8.0.0" >> /tmp/requirements.txt && \
    echo "huggingface_hub>=0.20" >> /tmp/requirements.txt && \
    echo "transformers>=4.20.0" >> /tmp/requirements.txt && \
    echo "accelerate>=0.20.0" >> /tmp/requirements.txt && \
    echo "einops>=0.6.0" >> /tmp/requirements.txt && \
    echo "jupyterlab==4.1.0" >> /tmp/requirements.txt && \
    echo "comfyui-manager" >> /tmp/requirements.txt

# Install all dependencies with proper resolution
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt

# Install xformers separately (it's finicky)
RUN pip3 install --no-cache-dir xformers==0.0.27 --no-deps

# Verify all critical imports step by step
RUN python3 -c "import urllib3; print('✅ urllib3 available')"
RUN python3 -c "import requests; print('✅ requests available')"
RUN python3 -c "import torch; print(f'✅ PyTorch {torch.__version__} available')"
RUN python3 -c "import PIL; print('✅ PIL available')"
RUN python3 -c "import transformers; print('✅ transformers available')"
RUN python3 -c "import torch, transformers, PIL, requests, urllib3; print('✅ All critical packages verified')"

# Install FileBrowser
RUN curl -fsSL \
    "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser \
  && chmod +x /usr/local/bin/filebrowser

# Clone repositories
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
RUN git clone --depth 1 \
    https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# Install ComfyUI dependencies (this should work now since base deps are solid)
RUN cd /ComfyUI && pip3 install --no-cache-dir -r requirements.txt

# Copy scripts
COPY start.sh organise_downloads.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/organise_downloads.sh

# Create directories and set permissions
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace \
  && chmod 755 /runpod-volume /workspace

# Security hardening
RUN echo 'HISTSIZE=0'          >> /home/sduser/.bashrc && \
    echo 'HISTFILESIZE=0'      >> /home/sduser/.bashrc && \
    echo 'unset HISTFILE'      >> /home/sduser/.bashrc && \
    echo 'set +o history'      >> /home/sduser/.bashrc && \
    echo 'export PYTHONDONTWRITEBYTECODE=1' >> /home/sduser/.bashrc && \
    echo 'export PYTHONHASHSEED=random'     >> /home/sduser/.bashrc && \
    echo 'export PYTHONUNBUFFERED=1'        >> /home/sduser/.bashrc && \
    echo 'umask 077'                       >> /home/sduser/.bashrc && \
    echo 'shopt -u histappend'             >> /home/sduser/.bashrc && \
    echo 'export LESSHISTFILE=-'           >> /home/sduser/.bashrc && \
    echo 'export MYSQL_HISTFILE=/dev/null' >> /home/sduser/.bashrc && \
    echo 'export SQLITE_HISTORY=/dev/null' >> /home/sduser/.bashrc && \
    echo 'export NODE_REPL_HISTORY=""'     >> /home/sduser/.bashrc && \
    mkdir -p /home/sduser/.config /home/sduser/.local/share && \
    chmod 700 /home/sduser/.config /home/sduser/.local /home/sduser/.local/share && \
    chmod 600 /home/sduser/.bashrc && \
    touch /home/sduser/.hushlogin

# Final ownership fix
RUN chown -R sduser:sduser /home/sduser

# Final comprehensive verification
RUN python3 -c "import torch, transformers, comfy.utils; print('✅ All imports including ComfyUI successful')" || \
    (echo "❌ Critical import failure!" && python3 -c "import sys; print('Python path:', sys.path)" && exit 1)

# Switch to non-root user
USER sduser
WORKDIR /ComfyUI

# Expose ports
EXPOSE 7860 8080 8888 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 || exit 1

ENTRYPOINT ["start.sh"]