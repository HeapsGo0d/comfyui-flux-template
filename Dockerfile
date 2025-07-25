# ─── STAGE 1: Build environment ─────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0" \
    PYTHONUNBUFFERED=1

# Create non-root user
RUN useradd -m -s /bin/bash sduser

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev \
    git wget aria2 curl openssl unzip build-essential \
  && rm -rf /var/lib/apt/lists/*

# Python libs for builder (pins for stability)
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
      torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 && \
    pip3 install --no-cache-dir \
      xformers==0.0.27 --no-deps \
      jupyterlab==4.1.0 \
      huggingface_hub==0.17.1 \
      comfyui-manager \
      requests pillow numpy

# FileBrowser
RUN curl -fsSL \
    https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
  | tar -xz -C /usr/local/bin filebrowser \
  && chmod +x /usr/local/bin/filebrowser

# ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI

# CivitAI downloader
RUN git clone --depth 1 https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# ComfyUI deps
RUN cd /ComfyUI && pip3 install --no-cache-dir -r requirements.txt


# ─── STAGE 2: Runtime ───────────────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0" \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}"

# Minimal runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip git curl openssl \
  && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash sduser

# Copy FileBrowser binary
COPY --from=builder /usr/local/bin/filebrowser /usr/local/bin/

# Copy the ComfyUI & CivitAI code
COPY --from=builder /ComfyUI /ComfyUI
COPY --from=builder /CivitAI_Downloader /CivitAI_Downloader

# Copy builder’s pip executables (so we can pip install in runtime)
COPY --from=builder /usr/local/bin/pip* /usr/local/bin/

# Now install *all* the Python bits you need at runtime:
#  - torch & friends (same versions, GPU wheels)
#  - jupyterlab
#  - comfyui-manager, requests, pillow, huggingface_hub, aria2, xformers, numpy
RUN pip3 install --no-cache-dir \
      torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 && \
    pip3 install --no-cache-dir \
      jupyterlab==4.1.0 \
      comfyui-manager \
      huggingface_hub==0.17.1 \
      requests pillow numpy aria2 xformers==0.0.27

# Copy your entrypoint & helper scripts
COPY start.sh organise_downloads.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/organise_downloads.sh

# Workspace & permissions
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace \
  && chmod 755 /runpod-volume /workspace

# Switch to non-root
USER sduser
WORKDIR /ComfyUI

# Expose ports
EXPOSE 7860 8080 8888 3000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:7860 || exit 1

ENTRYPOINT ["start.sh"]
