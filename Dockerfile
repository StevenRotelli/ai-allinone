# syntax=docker/dockerfile:1
# =============================================================================
# ai-allinone — ComfyUI + FaceFusion + DeepFaceLab-Revamped + JupyterLab
#
# Design rule: THE IMAGE OWNS THE ENVIRONMENT, THE VOLUME OWNS THE DATA.
# Nothing is pip-installed at boot and nothing executable lives on the network
# volume. That is deliberate — the previous setup kept python deps on the volume
# with PYTHONPATH pointing at them, which (a) let a stray torch shadow the
# CUDA-matched build and (b) meant a bad cleanup script could and did delete the
# data. Here the volume holds models, workflows, inputs and outputs only.
# =============================================================================
ARG CUDA_BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04
FROM ${CUDA_BASE_IMAGE}

ARG TORCH=2.8.0
ARG TORCHVISION=0.23.0
ARG TORCHAUDIO=2.8.0
ARG CUDA_VARIANT=cu128
ARG COMFYUI_REF=master
ARG FACEFUSION_REF=7247081
ARG DFL_REF=a9f29b7

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=0 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------------------------------------------------------------- system layer
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev python3-pip \
      git git-lfs curl wget ca-certificates xz-utils unzip zip \
      build-essential pkg-config \
      libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
      openssh-server rsync tmux nano jq procps \
    && rm -rf /var/lib/apt/lists/*

# ffmpeg: a STATIC build, never apt's.
# apt on 22.04/24.04 gives ffmpeg 4.4.2, which renders silently-black video that
# passes every size and duration check — FaceFusion output looks fine by every
# automated test and is blank. This is a known, previously-diagnosed failure.
RUN set -eux; \
    curl -fsSL -o /tmp/ff.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz; \
    mkdir -p /tmp/ff && tar -xJf /tmp/ff.tar.xz -C /tmp/ff --strip-components=1; \
    install -m755 /tmp/ff/ffmpeg /tmp/ff/ffprobe /usr/local/bin/; \
    rm -rf /tmp/ff /tmp/ff.tar.xz; \
    /usr/local/bin/ffmpeg -version | head -1

# ------------------------------------------------------------------ python env
RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" VIRTUAL_ENV=/opt/venv
RUN pip install --upgrade pip setuptools wheel

# Torch first, then FREEZE IT. Every pip install after this inherits
# PIP_CONSTRAINT, so no requirements file anywhere can upgrade, downgrade or
# replace torch. This is the structural fix for the whole shadowing problem
# class — it makes the failure impossible rather than merely documented.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install torch==${TORCH} torchvision==${TORCHVISION} torchaudio==${TORCHAUDIO} \
      --index-url https://download.pytorch.org/whl/${CUDA_VARIANT}
RUN pip freeze | grep -E "^(torch|torchvision|torchaudio)==" > /torch-constraint.txt \
    && cat /torch-constraint.txt
ENV PIP_CONSTRAINT=/torch-constraint.txt

# onnxruntime-gpu for CUDA 12.x comes from Microsoft's own index. The PyPI
# "onnxruntime-gpu" is built against a different CUDA and falls back to CPU
# silently — the detection and swap stages then run at a fraction of speed with
# no error to tell you why.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install onnxruntime-gpu onnx \
      --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ \
      --extra-index-url https://pypi.org/simple

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
      jupyterlab jupyter-server jupyter-server-terminals ipykernel \
      jupyterlab-lsp jupyterlab_code_formatter \
      numpy scipy opencv-python-headless pillow pyyaml tqdm \
      huggingface_hub hf_transfer gdown einops safetensors \
      diffusers accelerate peft transformers sentencepiece protobuf gguf ftfy

# ---------------------------------------------------------------------- comfyui
WORKDIR /opt
RUN git clone https://github.com/Comfy-Org/ComfyUI.git comfyui \
    && cd comfyui && git checkout ${COMFYUI_REF} \
    && git rev-parse HEAD > /comfyui-ref.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r /opt/comfyui/requirements.txt

# Node packs, all baked. The ADD re-reads a ref on every build so this layer
# cannot serve a stale cache forever and silently reship whatever commit the
# first build happened to resolve.
ADD https://api.github.com/repos/kijai/ComfyUI-KJNodes/git/refs/heads/main /pack-refs/kjnodes.json
COPY src/node_packs.txt /tmp/node_packs.txt
RUN set -eux; cd /opt/comfyui/custom_nodes; \
    grep -vE '^\s*(#|$)' /tmp/node_packs.txt | while read -r url; do \
      echo "--- $url"; git clone --depth 1 -q "$url" || echo "WARN: clone failed $url"; \
    done; \
    for req in /opt/comfyui/custom_nodes/*/requirements.txt; do \
      [ -f "$req" ] || continue; \
      echo "--- deps: $(dirname "$req")"; \
      grep -vE '^\s*(#|-e |git\+|https?://)' "$req" \
        | grep -viE '^\s*(torch|torchvision|torchaudio)\s*([;<>=!].*)?$' \
        > /tmp/req.txt || true; \
      [ -s /tmp/req.txt ] && pip install -r /tmp/req.txt || true; \
    done

# Node packs pin onnxruntime / onnxruntime-gpu from PyPI in their requirements,
# which clobbers the CUDA-12 build installed above. Reassert it last.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip uninstall -y onnxruntime onnxruntime-gpu || true; \
    pip install onnxruntime-gpu \
      --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ \
      --extra-index-url https://pypi.org/simple

# ------------------------------------------------------------------- facefusion
# Installed as an importable package: ai/pipeline imports `facefusion` directly,
# it is not only a CLI here. Its requirements pin CPU onnxruntime==1.30.0, so
# that line is stripped and the GPU build reasserted after.
RUN git clone https://github.com/facefusion/facefusion.git /opt/facefusion \
    && cd /opt/facefusion && git checkout ${FACEFUSION_REF} \
    && git rev-parse HEAD > /facefusion-ref.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    grep -viE '^\s*onnxruntime' /opt/facefusion/requirements.txt > /tmp/ff_req.txt \
    && pip install -r /tmp/ff_req.txt \
    && pip uninstall -y onnxruntime onnxruntime-gpu || true; \
    pip install onnxruntime-gpu \
      --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ \
      --extra-index-url https://pypi.org/simple
# Deliberately narrow: /opt/facefusion holds source only, no site-packages and
# no torch, so it cannot shadow anything. PYTHONPATH pointing at a directory
# that pip installs into is what caused the previous setup to shadow the
# CUDA-matched torch — do not extend this to a writable deps directory.
ENV PYTHONPATH=/opt/facefusion

# ------------------------------------------------------- matting + segmentation
RUN git clone --depth 1 https://github.com/pq-yang/MatAnyone.git /opt/matanyone \
 && git clone --depth 1 https://github.com/facebookresearch/sam2.git /opt/sam2
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -e /opt/sam2 || pip install /opt/sam2 || true; \
    [ -f /opt/matanyone/requirements.txt ] && \
      ( grep -viE '^\s*(torch|torchvision|torchaudio)' /opt/matanyone/requirements.txt > /tmp/ma.txt; \
        pip install -r /tmp/ma.txt ) || true

# ------------------------------------------------- DeepFaceLab-Revamped (DFM)
# CUDA-only, no Metal path, which is the whole reason training is a rented-GPU
# job. install.sh is uv-managed and self-contained; it relocates the real code
# to _internal/DeepFaceLab. Flags: --yes --no-pretrain are the non-interactive
# ones (install.sh forwards "$@"). Logs and comments are in Italian.
RUN git clone https://github.com/Cioscos/DeepFaceLab-Revamped.git /opt/dfl \
    && cd /opt/dfl && git checkout ${DFL_REF} \
    && git rev-parse HEAD > /dfl-ref.txt
RUN cd /opt/dfl && (bash install.sh --no-pretrain --yes || \
      echo "WARN: DFL install.sh returned non-zero; see /dfl-install.log") 2>&1 \
      | tee /dfl-install.log | tail -30

# ------------------------------------------------------------------- verify
# A build that quietly loses CUDA is worse than a failed build.
RUN set -eux; \
    python -c "import torch; assert torch.version.cuda, 'no CUDA in torch'; print('torch', torch.__version__, torch.version.cuda)"; \
    python -c "import torch, sys; print('torch from', torch.__file__)"; \
    python -c "import onnxruntime as o; ps=o.get_available_providers(); print('ort', o.__version__, ps); assert 'CUDAExecutionProvider' in ps, 'ort lost CUDA'"; \
    python -c "import cv2, numpy, scipy, PIL, yaml; print('pipeline deps ok')"; \
    ffmpeg -version | head -1

COPY src/start.sh src/volume_init.sh /opt/bin/
RUN chmod +x /opt/bin/start.sh /opt/bin/volume_init.sh

EXPOSE 8188 8888 7860 22
WORKDIR /workspace
CMD ["/opt/bin/start.sh"]
