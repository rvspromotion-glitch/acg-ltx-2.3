#!/usr/bin/env bash
set -euo pipefail

STARTUP_START=$(date +%s)

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

# Fix DNS resolution issues
echo "[network] Checking DNS configuration..."
if ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  echo "[network] Adding Google DNS..."
  {
    echo "nameserver 8.8.8.8"
    echo "nameserver 8.8.4.4"
    echo "nameserver 1.1.1.1"
  } >> /etc/resolv.conf
fi

# Wait for network readiness
echo "[network] Waiting for network..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && \
     (getent hosts pypi.org >/dev/null 2>&1 || nslookup pypi.org >/dev/null 2>&1); then
    echo "[network] Network ready!"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  [ $WAIT_COUNT -lt $MAX_WAIT ] && sleep 1
done

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"
PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-slim}"
BAKED_DIR="${COMFYUI_BAKED:-/opt/ComfyUI}"

mkdir -p "$(dirname "$COMFY_DIR")" "$PERSIST_DIR"

# Restore ComfyUI from baked if needed
if [ ! -f "${COMFY_DIR}/main.py" ] && [ -f "${BAKED_DIR}/main.py" ]; then
  echo "[setup] Restoring ComfyUI from baked image..."
  rm -rf "${COMFY_DIR}"
  cp -a "${BAKED_DIR}" "${COMFY_DIR}"
fi

if [ ! -f "${COMFY_DIR}/main.py" ]; then
  echo "[fatal] ComfyUI not found!"
  exit 1
fi

mkdir -p "${CUSTOM_NODES}" "${MODELS_DIR}"

# Persistent pip cache
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
mkdir -p "$PIP_CACHE_DIR"

# Hard constraints
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
protobuf<5
opencv-python<4.12
transformers>=4.39.3
mediapipe==0.10.14
sageattention
EOF

export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

# Only install if versions are wrong (skip if already correct)
SKIP_PIP_INSTALL=0
python3 - <<'PY' && SKIP_PIP_INSTALL=1 || true
import sys
try:
    import numpy
    import mediapipe
    assert numpy.__version__.startswith('1.')
    assert mediapipe.__version__ == '0.10.14'
    sys.exit(0)
except:
    sys.exit(1)
PY

if [ "$SKIP_PIP_INSTALL" = "0" ]; then
  echo "[pip] Installing core dependencies..."
  pip install -q --upgrade --prefer-binary --retries 5 --timeout 60 \
    -c "$CONSTRAINTS_FILE" \
    "numpy<2" "protobuf<5" "opencv-python<4.12" \
    "mediapipe==0.10.14" "sageattention" || true
else
  echo "[pip] Core dependencies already correct, skipping"
fi

echo "[debug] Versions:"
python3 - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy
print("numpy:", numpy.__version__)
try:
    import mediapipe
    print("mediapipe:", mediapipe.__version__)
except:
    print("mediapipe: not installed")
PY

# Helpers
download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[models] exists: $out"
    return 0
  fi
  echo "[models] downloading: $out"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x 16 -s 16 -k 1M \
      --allow-overwrite=true \
      --file-allocation=none \
      --max-tries=8 \
      --retry-wait=2 \
      --timeout=60 \
      --max-connection-per-server=16 \
      --min-split-size=1M \
      -d "$(dirname "$out")" -o "$(basename "$out")" \
      "$url" 2>&1 | grep -v "^Download Results:" || true
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 8 --retry-delay 2 --max-time 300 -C - -o "$out" "$url"
  else
    wget -c -O "$out" "$url"
  fi
}

safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0
  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf)([<=> ].*)?$' "$req" > "$tmpreq" || true
  pip install -q --prefer-binary --retries 5 --timeout 60 -c "$CONSTRAINTS_FILE" -r "$tmpreq" 2>/dev/null || true
  rm -f "$tmpreq"
}

# Model directories
mkdir -p \
  "${MODELS_DIR}/checkpoints" \
  "${MODELS_DIR}/clip" \
  "${MODELS_DIR}/clip_vision" \
  "${MODELS_DIR}/controlnet" \
  "${MODELS_DIR}/detection" \
  "${MODELS_DIR}/diffusion_models" \
  "${MODELS_DIR}/embeddings" \
  "${MODELS_DIR}/loras" \
  "${MODELS_DIR}/onnx" \
  "${MODELS_DIR}/unet" \
  "${MODELS_DIR}/upscale_models" \
  "${MODELS_DIR}/vae" \
  "${MODELS_DIR}/vae/pixel_space"

# Cache custom nodes on persistent volume
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE"
UPDATE_NODES="${UPDATE_NODES:-0}"

# Clone ALL nodes in parallel (not batches!)
echo "[nodes] Cloning custom nodes (fully parallel)..."
(
  cd "$REPO_CACHE"

  # All nodes launch at once
  for repo in \
    "ComfyUI-Manager:https://github.com/ltdrdata/ComfyUI-Manager.git" \
    "ComfyUI-Impact-Pack:https://github.com/ltdrdata/ComfyUI-Impact-Pack.git" \
    "ComfyUI-Impact-Subpack:https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git" \
    "ComfyUI-KJNodes:https://github.com/kijai/ComfyUI-KJNodes.git" \
    "ComfyUI-VideoHelperSuite:https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" \
    "ComfyUI-WanVideoWrapper:https://github.com/kijai/ComfyUI-WanVideoWrapper.git" \
    "ComfyUI-GGUF:https://github.com/city96/ComfyUI-GGUF.git" \
    "ComfyUI_essentials:https://github.com/cubiq/ComfyUI_essentials.git" \
    "a-person-mask-generator:https://github.com/djbielejeski/a-person-mask-generator.git" \
    "ComfyUI-VFI:https://github.com/Fannovel16/ComfyUI-VFI.git" \
    "ComfyUI-Custom-Scripts:https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" \
    "comfyui_controlnet_aux:https://github.com/Fannovel16/comfyui_controlnet_aux.git" \
    "rgthree-comfy:https://github.com/rgthree/rgthree-comfy.git" \
    "ComfyUI-Frame-Interpolation:https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git" \
    "RES4LYF:https://github.com/ClownsharkBatwing/RES4LYF.git" \
    "DJZ-Nodes:https://github.com/MushroomFleet/DJZ-Nodes.git" \
    "ComfyUI-WanAnimatePreprocess:https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git" \
    "ComfyUI-segment-anything-2:https://github.com/kijai/ComfyUI-segment-anything-2.git" \
    "comfyui-tensorops:https://github.com/un-seen/comfyui-tensorops.git" \
    "ComfyUI-NovaNoiser:https://github.com/Aloukik21/ComfyUI-NovaNoiser.git" \
    "savezipi9:https://github.com/rvspromotion-glitch/savezipi9.git"
  do
    name="${repo%%:*}"
    url="${repo#*:}"
    (
      if [ ! -d "${name}/.git" ]; then
        echo "[nodes] cloning ${name}..."
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true git \
          -c http.extraHeader= \
          -c credential.helper= \
          -c core.askPass= \
          clone --depth 1 --progress "$url" "$name" 2>&1 | grep -v "Checking out files" || true
      elif [ "$UPDATE_NODES" = "1" ]; then
        echo "[nodes] updating ${name}..."
        git -C "$name" pull --rebase 2>/dev/null || true
      fi
    ) &
  done
  wait
)

echo "[nodes] Creating symlinks..."
# Symlink all nodes
for dir in "${REPO_CACHE}"/*; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  case "$name" in
    savezipi9)
      # Special handling: symlink subdirectories
      ln -sfn "${dir}/Save-ZIP-I9" "${CUSTOM_NODES}/Save-ZIP-I9"
      ln -sfn "${dir}/batch-utility-i9" "${CUSTOM_NODES}/batch-utility-i9"
      ;;
    *)
      ln -sfn "$dir" "${CUSTOM_NODES}/${name}"
      ;;
  esac
done

echo "[nodes] All nodes ready!"

# Download ALL models in parallel
echo "[models] Downloading models (fully parallel)..."

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
  "${MODELS_DIR}/diffusion_models/z_image_turbo_bf16.safetensors" &

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
  "${MODELS_DIR}/vae/ae.safetensors" &

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" \
  "${MODELS_DIR}/clip/qwen_3_4b.safetensors" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/1x-ITF-SkinDiffDetail-Lite-v1.pth" \
  "${MODELS_DIR}/upscale_models/1x-ITF-SkinDiffDetail-Lite-v1.pth" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/RealESRGAN_x4plus.pth" \
  "${MODELS_DIR}/upscale_models/RealESRGAN_x4plus.pth" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth" \
  "${MODELS_DIR}/upscale_models/4x-UltraSharp.pth" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_foolhardy_Remacri.pth" \
  "${MODELS_DIR}/upscale_models/4x_foolhardy_Remacri.pth" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_NMKD-Superscale-SP_178000_G.pth" \
  "${MODELS_DIR}/upscale_models/4x_NMKD-Superscale-SP_178000_G.pth" &

download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4xNomos8kDAT.pth" \
  "${MODELS_DIR}/upscale_models/4xNomos8kDAT.pth" &

download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_model.onnx" &

download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_data.bin" &

download "https://huggingface.co/onnx-community/yolov10m/resolve/main/onnx/model.onnx" \
  "${MODELS_DIR}/detection/yolov10m.onnx" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
  "${MODELS_DIR}/clip_vision/clip_vision_h.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_animate_14B_bf16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
  "${MODELS_DIR}/vae/wan_2.1_vae.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors" \
  "${MODELS_DIR}/clip/umt5_xxl_fp16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" \
  "${MODELS_DIR}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" \
  "${MODELS_DIR}/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" &

download "https://huggingface.co/NSFW-API/NSFW_Wan_14b/resolve/main/nsfw_wan_14b_e15.safetensors" \
  "${MODELS_DIR}/diffusion_models/nsfw_wan_14b_e15.safetensors" &

# Wait for all downloads
wait
echo "[models] Downloads completed!"

# Create symlinks
mkdir -p "${MODELS_DIR}/vae/pixel_space" "${MODELS_DIR}/unet"
ln -sf "../ae.safetensors" "${MODELS_DIR}/vae/pixel_space/z-index-ae.safetensors" 2>/dev/null || true
ln -sf "../diffusion_models/z_image_turbo_bf16.safetensors" "${MODELS_DIR}/unet/z_image_turbo_bf16.safetensors" 2>/dev/null || true

# Character LoRA from env var
if [ -n "${CHAR_LORA_URL:-}" ]; then
  echo "[models] Downloading character LoRA..."
  CHAR_LORA_FILENAME=$(basename "$CHAR_LORA_URL" | sed 's/\?.*$//')
  [ -z "$CHAR_LORA_FILENAME" ] && CHAR_LORA_FILENAME="character_lora.safetensors"
  download "$CHAR_LORA_URL" "${MODELS_DIR}/loras/${CHAR_LORA_FILENAME}"
fi

# Install node requirements (only once)
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"

if [ "$INSTALL_NODE_REQS" = "1" ]; then
  if [ ! -f "$REQ_MARK" ] || [ "$UPDATE_NODES" = "1" ]; then
    echo "[pip] Installing node requirements (once)..."
    for dir in "${REPO_CACHE}"/*; do
      [ -d "$dir" ] || continue
      req="${dir}/requirements.txt"
      if [ -f "$req" ]; then
        echo "  - $(basename "$dir")/requirements.txt"
        safe_pip_install_req "$req"
      fi
      # Handle savezipi9 subdirectories
      if [ "$(basename "$dir")" = "savezipi9" ]; then
        for subdir in "$dir"/*; do
          [ -d "$subdir" ] || continue
          req="${subdir}/requirements.txt"
          if [ -f "$req" ]; then
            echo "  - savezipi9/$(basename "$subdir")/requirements.txt"
            safe_pip_install_req "$req"
          fi
        done
      fi
    done
    touch "$REQ_MARK"
  else
    echo "[pip] Node requirements already installed (skip)"
  fi
fi

# Final safety check
pip install -q --upgrade --prefer-binary --retries 5 --timeout 60 \
  -c "$CONSTRAINTS_FILE" "numpy<2" "mediapipe==0.10.14" 2>/dev/null || true

# Start JupyterLab
echo "[jupyter] Starting JupyterLab..."
jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
  --ServerApp.token='' --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.root_dir="${COMFY_DIR}" \
  >/workspace/jupyter.log 2>&1 &

echo "==================================="
echo "Launching ComfyUI"
echo "==================================="

STARTUP_END=$(date +%s)
STARTUP_DURATION=$((STARTUP_END - STARTUP_START))
echo "[startup] Total startup time: ${STARTUP_DURATION}s"
echo "==================================="

cd "${COMFY_DIR}"
exec python3 main.py --listen 0.0.0.0 --port 8188
