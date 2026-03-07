FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV COMFYUI_PATH=/workspace/ComfyUI
ENV COMFYUI_BAKED=/opt/ComfyUI

RUN apt-get update && apt-get install -y \
    git wget curl aria2 \
    libgl1 libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Install core dependencies with correct versions to avoid conflicts
RUN pip install --no-cache-dir "numpy<2" "protobuf<5" "opencv-python<4.12"

# Upgrade PyTorch stack to latest for CUDA 12.8 (do once in Dockerfile, not at runtime)
RUN pip install --no-cache-dir --upgrade --prefer-binary \
    --index-url https://download.pytorch.org/whl/cu128 \
    torch torchvision torchaudio xformers

# Install application dependencies
RUN pip install --no-cache-dir ultralytics jupyterlab sentencepiece \
    mediapipe==0.10.14 sageattention onnxruntime-gpu google-generativeai

# Install Manager-style deps that custom nodes commonly need
RUN pip install --no-cache-dir ftfy "accelerate>=1.2.1" einops \
    "diffusers>=0.33.0" "librosa>=0.9.0" "tqdm>=4.62.0" numba soundfile

# Pre-install ALL common custom node dependencies (prevents 1h runtime install)
RUN pip install --no-cache-dir \
    scikit-image scipy scikit-learn \
    matplotlib seaborn pyqt5 \
    pillow piexif lpips \
    timm segment-anything \
    transformers tokenizers safetensors \
    opencv-contrib-python insightface \
    imageio imageio-ffmpeg av \
    kornia albumentations \
    omegaconf pyyaml \
    requests aiohttp \
    huggingface-hub \
    onnx \
    spandrel

# Bake ComfyUI into /opt (won't be hidden by /workspace mount)
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI && \
    pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888
CMD ["/start.sh"]
