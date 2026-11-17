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
# Zero-setup but not wide open: if no usable token is supplied, generate a random
# one and print the ready-to-click URL in the log. That keeps the one-shot deploy
# (nothing to configure) without the tokenless default, where the 14-char pod id
# is the only thing between the internet and a root shell holding your CivitAI
# and HF keys on a mounted 750 GB volume.
#
# Set JUPYTER_DISABLE_AUTH=1 for the tokenless behaviour anyway.
JT="${JUPYTER_TOKEN:-}"
# RunPod substitutes {{ RUNPOD_SECRET_name }} only when that secret exists; when
# it does not, the literal template string arrives instead. It is non-empty, so a
# naive check would hand JupyterLab a completely guessable token.
case "$JT" in
  *"{{"*|*RUNPOD_SECRET*) log "JUPYTER_TOKEN unresolved, ignoring it"; JT="";;
esac
if [ -n "$JT" ] && [ "${#JT}" -lt 16 ]; then
  log "JUPYTER_TOKEN under 16 chars, ignoring it"; JT=""
fi

JUP_AUTH=()
if [ "${JUPYTER_DISABLE_AUTH:-0}" = "1" ]; then
  JUP_AUTH=(--ServerApp.token= --ServerApp.password=)
  log "jupyter: NO LOGIN - anyone with the pod URL can open a root shell"
else
  if [ -z "$JT" ]; then
    JT=$(python -c 'import secrets; print(secrets.token_hex(16))')
    log "jupyter: generated a token for this pod"
  else
    log "jupyter: using the supplied JUPYTER_TOKEN"
  fi
  JUP_AUTH=(--ServerApp.token="$JT")
fi

nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
  "${JUP_AUTH[@]}" --ServerApp.root_dir=/workspace \
  --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
  --ServerApp.trust_xheaders=True \
  > /workspace/logs/jupyter.log 2>&1 &

if [ -n "$JT" ]; then
  log "jupyter: https://${RUNPOD_POD_ID:-<podid>}-8888.proxy.runpod.net/lab?token=$JT"
else
  log "jupyter: https://${RUNPOD_POD_ID:-<podid>}-8888.proxy.runpod.net/lab"
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
