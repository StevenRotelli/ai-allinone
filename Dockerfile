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
# onnxruntime-gpu MUST come from Microsoft's cuda-12 feed AND be pinned, and the
# feed must be the ONLY index. That feed's newest build is 1.29.0; PyPI has
# 1.32.0, which is built for CUDA 13. pip takes the highest version across all
# indexes, so the old `--extra-index-url https://pypi.org/simple` here silently
# won with PyPI's CUDA-13 wheel on a CUDA-12.8 base. The damage was invisible to
# get_available_providers() (CUDAExecutionProvider is compiled in and still
# listed) and only showed up when a real InferenceSession was created:
#   libcublasLt.so.13: cannot open shared object file
#   Failed to create CUDAExecutionProvider. Require cuDNN 9.* and CUDA 13.*
#   session providers: ['CPUExecutionProvider']
# i.e. FaceFusion silently on CPU. Caught on pod sy3az8qk25olqk.
ARG ORT_VERSION=1.29.0
ARG ORT_INDEX=https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/

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

# onnx itself is an ordinary PyPI package; only onnxruntime-gpu is special.
RUN --mount=type=cache,target=/root/.cache/pip pip install onnx
# --no-deps because the feed carries no dependency wheels; ort's requirements
# (flatbuffers, numpy, packaging, protobuf) are already satisfied above, and
# adding PyPI as a fallback index is exactly the mistake described at ORT_INDEX.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-deps --index-url ${ORT_INDEX} onnxruntime-gpu==${ORT_VERSION}

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
        | grep -viE '^\s*opencv[-_](python|contrib[-_]python)\s*([;<>=!].*)?$' \
        > /tmp/req.txt || true; \
      [ -s /tmp/req.txt ] && pip install -r /tmp/req.txt || true; \
    done

# facebook/sam2 is a `git+` line in ComfyUI-Impact-Pack's requirements, and the
# loop above strips git+ deliberately. Without it Impact Pack boots with
# "The SAM2 functionality is unavailable". Installed with --no-deps and its
# real deps named explicitly: hydra-core pins antlr4-python3-runtime==4.9.*,
# and letting pip take the newest (4.13.2) yields
#   Exception: Could not deserialize ATN with version 3 (expected 4)
# at import. omegaconf is NOT listed here: the image already has it, and adding
# a second copy is how a working one gets shadowed.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-deps "git+https://github.com/facebookresearch/sam2" \
 && pip install --no-deps hydra-core "antlr4-python3-runtime==4.9.3" iopath portalocker \
 && python -c "from sam2.build_sam import build_sam2; print('sam2 ok')"


# Node packs pin onnxruntime / onnxruntime-gpu from PyPI in their requirements,
# which clobbers the CUDA-12 build installed above. Reassert it last.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip uninstall -y onnxruntime onnxruntime-gpu || true; \
    pip install --no-deps --index-url ${ORT_INDEX} onnxruntime-gpu==${ORT_VERSION}

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
    pip install --no-deps --index-url ${ORT_INDEX} onnxruntime-gpu==${ORT_VERSION}
# Deliberately narrow: /opt/facefusion holds source only, no site-packages and
# no torch, so it cannot shadow anything. PYTHONPATH pointing at a directory
# that pip installs into is what caused the previous setup to shadow the
# CUDA-matched torch — do not extend this to a writable deps directory.
ENV PYTHONPATH=/opt/facefusion

# ------------------------------------------------------- matting + segmentation
# No standalone sam2 clone here. ComfyUI-segment-anything-2 vendors its own
# sam2/ package and sam2_configs/, and a grep for "import sam2" across all 26
# node packs returns nothing — so a second copy bought us only a silent
# failure: the old `pip install -e /opt/sam2 || pip install /opt/sam2 || true`
# failed on a missing hydra and `|| true` swallowed it, leaving an /opt/sam2
# that looked installed and imported nowhere. Verified on pod sy3az8qk25olqk.
# MatAnyone gets no pip install, deliberately. It has no requirements.txt (the
# old line here hid that behind `[ -f ... ] || true`, so nothing was ever
# installed from it), and its pyproject.toml declares the training and GUI
# stack — PySide6, gradio, cchardet, netifaces, pycocotools, a git-sourced
# thinplate — for an inference entrypoint that imports none of it. That is
# hundreds of megabytes plus cchardet, which does not build on current Python.
# Checked on pod sy3az8qk25olqk: inference_matanyone.py's top-level imports are
# PIL, cv2, imageio, numpy, torch, tqdm and its own package, all already
# present. The verify layer below asserts exactly that, which is a tighter
# contract than installing a requirements file would have been.
RUN git clone --depth 1 https://github.com/pq-yang/MatAnyone.git /opt/matanyone

# ------------------------------------------------- DeepFaceLab-Revamped (DFM)
# CUDA-only, no Metal path, which is the whole reason training is a rented-GPU
# job.
#
# install.sh is NOT used. It is uv-managed and self-contained: it downloads its
# own CPython 3.11 and its own torch, then demands 15 GB free. On the GitHub
# hosted runner that preflight failed with "spazio insufficiente in /opt/dfl:
# 7.5 GB liberi, ne servono almeno 15.0 GB" and the old `|| echo WARN` here
# swallowed the failure — the image shipped with a bare git clone whose
# main.py died on `No module named 'colorama'`. Found on pod sy3az8qk25olqk.
#
# The repo already separates its deps: requirements/base.txt is the real list
# (colorama, onnx, scikit-image, numexpr, pyqt5, pillow, ...) while cuda.txt
# holds ONLY torch==2.13.0 from the cu130 index. We already have CUDA torch, so
# base.txt is installed and cuda.txt is skipped outright. Measured on the pod:
# 4 seconds, 7 small wheels, torch untouched at 2.8.0+cu128. PIP_CONSTRAINT
# would reject that torch 2.13.0 regardless, which is the point of pinning it.
RUN git clone https://github.com/Cioscos/DeepFaceLab-Revamped.git /opt/dfl \
    && cd /opt/dfl && git checkout ${DFL_REF} \
    && git rev-parse HEAD > /dfl-ref.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux; cd /opt/dfl; pip install -r requirements/base.txt

# ------------------------------------------------------------------- verify
# A build that quietly loses CUDA is worse than a failed build.
COPY src/verify_imports.py src/check_ort_cuda.sh src/check_node_packs.py /opt/bin/

# Every pipeline the image exists to run is asserted here. The first version of
# this layer checked only torch/ort/cv2/ffmpeg and therefore passed a build in
# which DeepFaceLab and sam2 were both broken. Nothing below may use `|| true`.
RUN set -eux; \
    python -c "import torch; assert torch.version.cuda, 'no CUDA in torch'; print('torch', torch.__version__, torch.version.cuda)"; \
    python -c "import torch, sys; print('torch from', torch.__file__)"; \
    python -c "import onnxruntime as o; ps=o.get_available_providers(); print('ort', o.__version__, ps); assert 'CUDAExecutionProvider' in ps, 'ort lost CUDA'"; \
    python -c "import onnxruntime as o, sys; assert o.__version__ == '${ORT_VERSION}', 'ort is %s, not the pinned CUDA-12 build' % o.__version__"; \
    bash /opt/bin/check_ort_cuda.sh; \
    python -c "import cv2, numpy, scipy, PIL, yaml; print('pipeline deps ok')"; \
    ffmpeg -version | head -1; \
    cd /opt/facefusion && python -c "import facefusion; print('facefusion import ok')"; \
    cd /opt/matanyone && python -c "import matanyone; print('matanyone import ok')"; \
    python /opt/bin/verify_imports.py /opt/matanyone/inference_matanyone.py; \
    cd /opt/dfl && python main.py --help > /tmp/dfl.txt; \
    grep -q exportdfm /tmp/dfl.txt; grep -q train /tmp/dfl.txt; \
    echo "dfl main.py ok (train + exportdfm present)"; \
    cd /opt/comfyui && python -c "import folder_paths; print('comfyui importable')"; \
    python /opt/bin/check_node_packs.py /tmp/node_packs.txt /opt/comfyui/custom_nodes; \
    python -c "import ultralytics, segment_anything, piexif, dill; print('impact pack deps ok')"; \
    python -c "from sam2.build_sam import build_sam2; print('sam2 ok')"; \
    python -c "import importlib.util as u; assert u.find_spec('nvvfx'), 'nvidia-vfx missing'; print('nvvfx present')"; \
    python -c "import omegaconf, hydra; print('omegaconf', omegaconf.__version__, '+ hydra ok')"

COPY src/start.sh src/volume_init.sh /opt/bin/
RUN chmod +x /opt/bin/start.sh /opt/bin/volume_init.sh

EXPOSE 8188 8888 7860 22
WORKDIR /workspace
CMD ["/opt/bin/start.sh"]
