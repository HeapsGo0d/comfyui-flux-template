# ─── STAGE 1: Build environment ─────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0" \
    PYTHONUNBUFFERED=1

# Create non-root user
RUN useradd -m -s /bin/bash sduser

# System dependencies (minimal)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev \
    git wget aria2 curl openssl unzip \
    build-essential \
    libjpeg-dev libpng-dev \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean

# Python libraries (pinned versions for stability)
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
      torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 && \
    pip3 install --no-cache-dir \
      xformers==0.0.27 --no-deps \
      jupyterlab==4.1.0 \
      "huggingface_hub>=0.20" \
      comfyui-manager \
      requests pillow numpy aria2 transformers accelerate \
      einops

# Install FileBrowser
RUN curl -fsSL \
    "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser \
  && chmod +x /usr/local/bin/filebrowser

# Clone ComfyUI (stable version)
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI

# Clone CivitAI downloader
RUN git clone --depth 1 \
    https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# Install ComfyUI dependencies
RUN cd /ComfyUI && pip3 install --no-cache-dir -r requirements.txt

# ─── STAGE 2: Runtime ───────────────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0" \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}"

# Install minimal runtime dependencies INCLUDING image libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    git curl openssl \
    libjpeg-dev libpng-dev \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean

# Create non-root user
RUN useradd -m -s /bin/bash sduser

# Copy from builder stage
COPY --from=builder /usr/local/bin/filebrowser /usr/local/bin/
COPY --from=builder /usr/local/lib/python3.*/site-packages /usr/local/lib/python3.*/site-packages
COPY --from=builder /usr/local/bin/pip*            /usr/local/bin/
COPY --from=builder /ComfyUI                       /ComfyUI
COPY --from=builder /CivitAI_Downloader             /CivitAI_Downloader

# Copy scripts
COPY start.sh organise_downloads.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/organise_downloads.sh

# Create directories and set permissions
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace \
  && chmod 755 /runpod-volume /workspace

# Maximum security hardening - leave no trace
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

# CHANGED: Added this block to fix the permission error
# This ensures sduser owns all files in its home directory before we switch to it.
RUN chown -R sduser:sduser /home/sduser

# Switch to non-root user
USER sduser
WORKDIR /ComfyUI

# Expose ports
EXPOSE 7860 8080 8888 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 || exit 1

ENTRYPOINT ["start.sh"]