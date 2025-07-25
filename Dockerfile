# ─── STAGE 1: Build environment ─────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0"

# Create non-root user
RUN useradd -m -s /bin/bash sduser

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip git wget aria2 curl openssl unzip \
  && rm -rf /var/lib/apt/lists/*

# Python libs (pinned)
RUN pip3 install --no-cache-dir \
    torch==2.3.1+cu121 \
    torchvision==0.18.1+cu121 \
    torchaudio==2.3.1+cu121 \
    xformers==0.0.27 --no-deps \
    jupyterlab==4.1.0 \
    huggingface_hub==0.17.1 \
    comfyui-manager==0.3.5

# FileBrowser official binary
RUN curl -fsSL \
    "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
  | tar -xz -C /usr/local/bin filebrowser \
  && chmod +x /usr/local/bin/filebrowser

# Clone ComfyUI at a stable tag
RUN git clone --branch v1.0.0 \
    https://github.com/comfyanonymous/ComfyUI.git /ComfyUI

# Clone CivitAI downloader
RUN git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /CivitAI_Downloader

# Copy helper scripts
COPY organise_downloads.sh start.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/organise_downloads.sh /usr/local/bin/start.sh

# Prepare directories & permissions
RUN mkdir -p /runpod-volume /workspace/downloads \
  && chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace

# ─── STAGE 2: Runtime ───────────────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TORCH_CUDA_ARCH_LIST="8.9;9.0"

# Bring in user, Python & binaries from builder
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/lib/python3.*/site-packages /usr/local/lib/python3.*/site-packages
COPY --from=builder /ComfyUI /ComfyUI
COPY --from=builder /CivitAI_Downloader /CivitAI_Downloader
RUN useradd -m -s /bin/bash sduser

# Restore permissions
RUN chown -R sduser:sduser /ComfyUI /CivitAI_Downloader /runpod-volume /workspace

USER sduser
WORKDIR /ComfyUI

# Expose ports
EXPOSE 7860 8080 8888 3000

ENTRYPOINT ["start.sh"]
