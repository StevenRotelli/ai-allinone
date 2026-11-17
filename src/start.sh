#!/usr/bin/env bash
# Entrypoint. Runs as PID 1, so RunPod's injected secrets are in this process's
# environment and every child inherits them — no /proc/1/environ dance needed.
#
# Hard rule at the bottom: NEVER EXIT. If a service dies the container must stay
# up so the log is readable; a crash-loop buries the reason.
set -u

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "=== ai-allinone ==="
log "comfyui    $(cat /comfyui-ref.txt 2>/dev/null | cut -c1-12)"
log "facefusion $(cat /facefusion-ref.txt 2>/dev/null | cut -c1-12)"
log "dfl        $(cat /dfl-ref.txt 2>/dev/null | cut -c1-12)"
log "torch      $(python -c 'import torch;print(torch.__version__, torch.version.cuda)' 2>/dev/null)"
log "gpu        $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"

# --- volume -----------------------------------------------------------------
log "--- volume ---"
VOL=/workspace /opt/bin/volume_init.sh

# --- ssh (RunPod injects PUBLIC_KEY) ----------------------------------------
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  mkdir -p /run/sshd && ssh-keygen -A >/dev/null 2>&1
  /usr/sbin/sshd -D & log "sshd started"
fi

# --- jupyterlab -------------------------------------------------------------
# Token from JUPYTER_TOKEN if set. Without one it refuses rather than serving a
# tokenless notebook on a public proxy.
if [ -n "${JUPYTER_TOKEN:-}" ]; then
  nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
    --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.root_dir=/workspace \
    --ServerApp.allow_origin='*' --ServerApp.trust_xheaders=True \
    > /workspace/logs/jupyter.log 2>&1 &
  log "jupyterlab on :8888 (token set)"
else
  log "jupyterlab NOT started — set JUPYTER_TOKEN to enable it"
fi

# --- comfyui ----------------------------------------------------------------
cd /opt/comfyui
nohup python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header \
  ${COMFY_EXTRA_ARGS:-} > /workspace/logs/comfyui.log 2>&1 &
log "comfyui starting on :8188 (node imports take a few minutes over network storage)"

# --- facefusion ui, opt-in --------------------------------------------------
if [ "${START_FACEFUSION:-0}" = "1" ]; then
  cd /opt/facefusion
  nohup python facefusion.py run --execution-providers cuda \
    --ui-layouts default > /workspace/logs/facefusion.log 2>&1 &
  log "facefusion ui on :7860"
else
  log "facefusion ui not started (START_FACEFUSION=1 to enable); CLI is on PATH"
fi

log "--- ready; tailing logs ---"
# Never exit: keep the container alive so a dead service leaves a readable log
# instead of a restart loop.
touch /workspace/logs/comfyui.log
tail -F /workspace/logs/*.log 2>/dev/null &
while true; do sleep 300; done
