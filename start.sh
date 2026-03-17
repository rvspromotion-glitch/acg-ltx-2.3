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

civit_download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"

  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[civitai] exists: $out"
    return 0
  fi

  echo "[civitai] downloading: $out"

  if command -v aria2c >/dev/null 2>&1; then
    # If we have a token, get the signed redirect URL first (R2 signed URLs fail with extra headers)
    local download_url="$url"
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      echo "[civitai] Getting signed download URL..."
      download_url=$(curl -sL -I -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -H "Authorization: Bearer ${CIVITAI_TOKEN}" \
        "$url" | grep -i "^location:" | tail -1 | sed 's/^location: //i' | tr -d '\r\n')

      if [ -z "$download_url" ]; then
        echo "[civitai] Failed to get redirect URL, using original"
        download_url="$url"
      fi
    fi

    local aria_opts=(
      -c -x 16 -s 16 -k 1M
      --allow-overwrite=true
      --file-allocation=none
      --max-tries=10
      --retry-wait=2
      --connect-timeout=30
      --timeout=60
      --max-connection-per-server=16
      --min-split-size=1M
      --split=16
      --stream-piece-selector=geom
      --optimize-concurrent-downloads=true
      --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      -d "$(dirname "$out")" -o "$(basename "$out")"
    )

    aria2c "${aria_opts[@]}" "$download_url"
  else
    local header=()
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      header+=( -H "Authorization: Bearer ${CIVITAI_TOKEN}" )
    fi

    curl -L --fail --retry 10 --retry-delay 2 -C - \
      -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
      "${header[@]}" \
      -o "$out" "$url"
  fi

  # If we got HTML (login page), delete it so you dont think its a model
  if command -v file >/dev/null 2>&1 && file "$out" | grep -qi "HTML"; then
    echo "[civitai] ERROR: got HTML instead of model (token missing/invalid/gated). Removing $out"
    rm -f "$out"
    return 1
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
  "${MODELS_DIR}/latent_upscale_models" \
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
    "savezipi9:https://github.com/rvspromotion-glitch/savezipi9.git" \
    "qwen_vl:https://github.com/1038lab/ComfyUI-QwenVL.git" \
    "LTX_nodes:https://github.com/Lightricks/ComfyUI-LTXVideo.git" \
    "LTX2_easy_prompt:https://github.com/seanhan19911990-source/LTX2EasyPrompt-LD.git" \
    "Depth_Crafter:https://github.com/akatz-ai/ComfyUI-DepthCrafter-Nodes.git" \
    "ComfyUI_Easy_Use:https://github.com/yolain/ComfyUI-Easy-Use.git" \
    "ComfyMath:https://github.com/evanspearman/ComfyMath.git"
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

cat > "${CUSTOM_NODES}/qwen_vl/custom_models.json" <<'EOF'
{
  "hf_models": {
    "Qwen3-VL-8B-Instruct-abliterated": {
      "repo_id": "huihui-ai/Huihui-Qwen3-VL-8B-Instruct-abliterated",
      "default": true,
      "quantized": false,
      "vram_requirement": {
        "full": 12.0,
        "8bit": 7.0,
        "4bit": 4.5
      }
    },
    "Qwen3-VL-32B-Instruct-abliterated": {
      "repo_id": "huihui-ai/Huihui-Qwen3-VL-32B-Instruct-abliterated",
      "default": false,
      "quantized": false,
      "vram_requirement": {
        "full": 28.0,
        "8bit": 14.0,
        "4bit": 8.5
      }
    },
    "Qwen2.5-VL-7B-Instruct-abliterated": {
      "repo_id": "huihui-ai/Qwen2.5-VL-7B-Instruct-abliterated",
      "default": false,
      "quantized": false,
      "vram_requirement": {
        "full": 28.0,
        "8bit": 14.0,
        "4bit": 8.5
      }
    },
    "Qwen2.5-VL-3B-Instruct-abliterated": {
      "repo_id": "huihui-ai/Qwen2.5-VL-3B-Instruct-abliterated",
      "default": false,
      "quantized": false,
      "vram_requirement": {
        "full": 28.0,
        "8bit": 14.0,
        "4bit": 8.5
      }
    }
  }
}
EOF
echo "[config] QwenVL custom_models.json written"

# Download ALL models in parallel
echo "[models] Downloading models (fully parallel)..."

download "https://huggingface.co/ai-toolkit/flux2_vae/resolve/main/ae.safetensors" \
  "${MODELS_DIR}/vae/ae2.safetensors" &
  
download "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp4mixed.safetensors" \
  "${MODELS_DIR}/clip/qwen_3_8b_fp4mixed.safetensors" &

download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_model.onnx" &

download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_data.bin" &

download "https://huggingface.co/onnx-community/yolov10m/resolve/main/onnx/model.onnx" \
  "${MODELS_DIR}/detection/yolov10m.onnx" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
  "${MODELS_DIR}/clip_vision/clip_vision_h.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384.safetensors" \
  "${MODELS_DIR}/loras/ltx-2.3-22b-distilled-lora-384-8steps-cfg1.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-dev.safetensors" \
  "${MODELS_DIR}/checkpoints/ltx-2.3-22b-dev.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled.safetensors" \
  "${MODELS_DIR}/checkpoints/ltx-2.3-22b-distilled-8s-cfg1.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors" \
  "${MODELS_DIR}/latent_upscale_models/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.0.safetensors" \
  "${MODELS_DIR}/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-temporal-upscaler-x2-1.0.safetensors" \
  "${MODELS_DIR}/latent_upscale_models/ltx-2.3-temporal-upscaler-x2-1.0.safetensors" &

download "https://huggingface.co/Phr00t/LTX2-Rapid-Merges/resolve/main/nsfw/ltx-2-19b-phr00tmerge-nsfw-v6.safetensors" \
  "${MODELS_DIR}/diffusion_models/ltx-2-19b-phr00tmerge-nsfw-v6.safetensors" &

download "https://huggingface.co/Phr00t/LTX2-Rapid-Merges/resolve/main/LORAs/povnsfw-v3-complete.safetensors" \
  "${MODELS_DIR}/loras/ltx-2-povnsfw-v3-complete.safetensors" &

download "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" \
  "${MODELS_DIR}/clip/gemma_3_12B_it_fp8_scaled.safetensors" &

download "https://huggingface.co/Kijai/LTXV2_comfy/resolve/main/VAE/LTX2_audio_vae_bf16.safetensors" \
  "${MODELS_DIR}/vae/LTX2_audio_vae_bf16.safetensors" &

download "https://huggingface.co/Kijai/LTXV2_comfy/resolve/main/VAE/LTX2_video_vae_bf16.safetensors" \
  "${MODELS_DIR}/vae/LTX2_video_vae_bf16.safetensors" &

download "https://huggingface.co/Kijai/LTXV2_comfy/resolve/main/text_encoders/ltx-2-19b-embeddings_connector_dev_bf16.safetensors" \
  "${MODELS_DIR}/clip/ltx-2-19b-embeddings_connector_dev_bf16.safetensors" &

download "https://huggingface.co/Kijai/LTXV2_comfy/resolve/main/loras/ltx-2-19b-distilled-lora-resized_dynamic_fro095_avg_rank_242_bf16.safetensors" \
  "${MODELS_DIR}/loras/ltx-2-19b-distilled-lora-resized_dynamic_fro095_avg_rank_242_bf16.safetensors" &

download "https://www.dropbox.com/scl/fi/u5pnegfvlykkm08qlcf83/4zzl1ck1n-trigger-peglora-LTX2.safetensors?rlkey=4uowf62slb0arezblaminirqn&st=qksqnd9x&dl=1" \
  "${MODELS_DIR}/loras/LTX2-4zzl1ck1n-Peg-LoRa.safetensors" &

download "https://www.dropbox.com/scl/fi/u0539uevebbjyh7livvly/AssLovers_000015000-LTX2.safetensors?rlkey=a39y7j00p5r5d4t0d5fe6mni4&st=03bs6iin&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Ass_Lovers.safetensors" &

download "https://www.dropbox.com/scl/fi/361eof5vxsv1gb5kr08zd/doggystyle_ltx_000004200.safetensors?rlkey=mgxd8chdptlu2mhzzcdlkh979&st=4vkcxzia&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Doggystyle.safetensors" &

download "https://www.dropbox.com/scl/fi/723yl4op59mmeua7ykx64/LTX2-i2v-SexThrust.safetensors?rlkey=zucykynadmougd74swedvmnfd&st=ylrvpopa&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Sex_Thrust.safetensors" &

download "https://www.dropbox.com/scl/fi/2zdrq7oigym9x6jmys8iu/LTX2-i2v-SexyMove.safetensors?rlkey=pugbht7u3wfk8kzdbxackmxc8&st=9ftal0rn&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Sexy_Move.safetensors" &

download "https://www.dropbox.com/scl/fi/vchflqd1j2twp31fizwbz/msltx-3fingering-step00005000_comfy.safetensors?rlkey=tqr9tgcuty4bjcn0l8onaz85g&st=uqp0m3vy&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Fingering.safetensors" &

download "https://www.dropbox.com/scl/fi/32fzp2u23xqgciywd8wb5/LTX2-i2v-OralSuite.safetensors?rlkey=o37lrst6l7ke8v3m3rcf86r8x&st=pku1w7pb&dl=1" \
  "${MODELS_DIR}/loras/LTX2-Oral_Suite.safetensors" &
  
download "https://huggingface.co/Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control/resolve/main/ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors" \
  "${MODELS_DIR}/loras/ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors" &

download "https://huggingface.co/Lightricks/LTX-2.3-22b-IC-LoRA-Motion-Track-Control/resolve/main/ltx-2.3-22b-ic-lora-motion-track-control-ref0.5.safetensors" \
  "${MODELS_DIR}/loras/ltx-2.3-22b-ic-lora-motion-track-control-ref0.5.safetensors" &

download "https://huggingface.co/mlabonne/gemma-3-12b-it-abliterated-v2-GGUF/resolve/main/gemma-3-12b-it-abliterated-v2.q8_0.gguf" \
  "${MODELS_DIR}/clip/gemma-3-12b-it-abliterated-Q8_0.gguf" &  

civit_download "https://civitai.com/api/download/models/2658598?type=Model&format=SafeTensor&size=pruned&fp=fp8" \
  "${MODELS_DIR}/checkpoints/2658598_fp8_pruned.safetensors" &

civit_download "https://civitai.com/api/download/models/2631758?type=Model&format=SafeTensor&size=pruned&fp=bf16" \
  "${MODELS_DIR}/checkpoints/flux_klein_9b_true_bf16.safetensors" &

civit_download "https://civitai.com/api/download/models/2677698?type=Model&format=SafeTensor" \
  "${MODELS_DIR}/checkpoints/flux_klein_9b_nsfw_lora.safetensors" &

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
