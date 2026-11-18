#!/usr/bin/env bash
# Lay out the network volume. Idempotent: creates what is missing, touches
# nothing that exists. Never deletes.
set -u
VOL="${VOL:-/workspace}"

[ -d "$VOL" ] || { echo "  $VOL is not a directory — no volume mounted"; exit 0; }

for d in models/checkpoints models/loras models/vae models/vae_approx \
         models/clip_vision models/controlnet models/diffusion_models \
         models/text_encoders models/upscale_models models/embeddings \
         models/latent_upscale_models models/detection models/frame_interpolation \
         models/facefusion models/dfl \
         workflows inputs outputs logs dfl/models dfl/data_src dfl/data_dst \
         notebooks scratch; do
  mkdir -p "$VOL/$d"
done

# ComfyUI reads extra_model_paths.yaml at startup only. Folder keys it does not
# know about are ignored, and a model in an unmapped folder is invisible with no
# error — so the list below must stay in step with what gets downloaded.
cat > /opt/comfyui/extra_model_paths.yaml <<YAML
volume:
  base_path: $VOL
  checkpoints: models/checkpoints
  loras: models/loras
  vae: models/vae
  vae_approx: models/vae_approx
  clip_vision: models/clip_vision
  controlnet: models/controlnet
  diffusion_models: models/diffusion_models
  text_encoders: models/text_encoders
  upscale_models: models/upscale_models
  embeddings: models/embeddings
  latent_upscale_models: models/latent_upscale_models
  detection: models/detection
  frame_interpolation: models/frame_interpolation
YAML

# Workflows, inputs and outputs live on the volume, surfaced where ComfyUI
# expects them. Symlink rather than copy so there is exactly one copy.
# The "leave a non-empty directory alone" guard below is correct in spirit but
# silently defeated itself for output/ and input/: the ComfyUI image ships
# placeholder content in both (output/_output_images_will_be_put_here and
# input/3d/), so the directory was never empty, the link never happened, and
# EVERY RENDER went to the container disk to be lost at teardown. It said so
# only as one line in a long boot log. Found 2026-11-18.
#
# So: move whatever is already there onto the volume (never overwriting), drop
# the known placeholder markers, then link. Nothing is deleted that is not
# either a known marker or already safely copied across.
link() {  # link <target-on-volume> <path-comfy-expects>
  local tgt="$1" dst="$2"
  mkdir -p "$tgt" "$(dirname "$dst")"
  if [ -L "$dst" ]; then return; fi
  if [ -d "$dst" ]; then
    local moved=0 item base
    for item in "$dst"/* "$dst"/.[!.]*; do
      [ -e "$item" ] || continue
      base=$(basename "$item")
      case "$base" in
        _output_images_will_be_put_here|_input_images_go_here) rm -f "$item"; continue ;;
      esac
      if [ ! -e "$tgt/$base" ]; then
        cp -a "$item" "$tgt/$base" && moved=$((moved+1))
      fi
    done
    [ "$moved" -gt 0 ] && echo "  moved $moved pre-existing item(s) from $dst onto the volume"
    rm -rf "$dst"
  fi
  rmdir "$dst" 2>/dev/null || true
  ln -s "$tgt" "$dst" && echo "  linked $dst -> $tgt"
}
link "$VOL/workflows" /opt/comfyui/user/default/workflows
link "$VOL/inputs"    /opt/comfyui/input
link "$VOL/outputs"   /opt/comfyui/output

# FaceFusion downloads its model set into .assets inside its own source tree.
# That is the container disk, and `facefusion.py force-download` fetched 39 GB
# of it on pod sy3az8qk25olqk — against a 60 GB container disk, with the models
# thrown away on every pod teardown. Models are volume data by the rule at the
# top of the Dockerfile, so .assets belongs on the volume like everything else.
link "$VOL/models/facefusion" /opt/facefusion/.assets

# Same reasoning for DFL: a trained model must outlive the pod that trained it.
link "$VOL/dfl/models" /opt/dfl/workspace_models

# Two node packs look past extra_model_paths.yaml entirely, so a yaml entry does
# nothing for them and their weights land on the container disk:
#
#   ComfyUI-segment-anything-2  os.path.join(folder_paths.models_dir, "sam2")
#                               (nodes.py:62) - models_dir is the container's
#                               /opt/comfyui/models, never the extra search paths
#   comfyui_controlnet_aux      <pack>/ckpts/<hf-repo-id>/<filename>
#                               (src/custom_controlnet_aux/util.py:36,296)
#
# Both are hardcoded, so the only fix that survives a pod is a symlink. The
# controlnet_aux one must keep the repo-id subdirectory layout, because
# custom_hf_download() builds the path as ckpts/<repo_id>/<filename> and
# re-downloads if that exact path is absent. The DWPose default pair is
# hr16/yolox-onnx/yolox_l.onnx and
# hr16/DWPose-TorchScript-BatchSize5/dw-ll_ucoco_384_bs5.torchscript.pt
# (node_wrappers/dwpose.py:60,67).
mkdir -p "$VOL/models/sam2" "$VOL/models/controlnet_aux_ckpts"
link "$VOL/models/sam2" /opt/comfyui/models/sam2
CNA=/opt/comfyui/custom_nodes/comfyui_controlnet_aux
if [ -d "$CNA" ] && [ ! -L "$CNA/ckpts" ]; then
  if [ -d "$CNA/ckpts" ]; then
    cp -rn "$CNA/ckpts/." "$VOL/models/controlnet_aux_ckpts/" 2>/dev/null || true
    rm -rf "$CNA/ckpts"
  fi
  ln -s "$VOL/models/controlnet_aux_ckpts" "$CNA/ckpts" \
    && echo "  linked $CNA/ckpts -> $VOL/models/controlnet_aux_ckpts"
fi

# Single config files, not directories: seed the volume from the container copy
# the first time, then the volume copy is the only one that exists.
linkfile() {  # linkfile <path-on-volume> <path-the-node-expects>
  local tgt="$1" dst="$2"
  mkdir -p "$(dirname "$tgt")" "$(dirname "$dst")"
  if [ -L "$dst" ]; then return; fi
  if [ ! -s "$tgt" ] && [ -s "$dst" ]; then cp "$dst" "$tgt"; fi
  [ -e "$tgt" ] || echo '{}' > "$tgt"
  rm -f "$dst"
  ln -s "$tgt" "$dst" && echo "  linked $dst -> $tgt"
}

# Civicomfy keeps its settings inside its own source tree on the container disk,
# so "workspace root = /workspace/models" had to be re-entered by hand on every
# new pod (pod qf80u7sb82t9nb, 2026-11-17). Its Civitai key is NOT here: the node
# reads $CIVITAI_API_KEY (server/utils.py:36) and otherwise keeps the key only in
# browser localStorage, which is per-origin and so dies with the pod hostname.
# Pass CIVITAI_API_KEY at pod create; do not try to persist it in these files.
CIVI=/opt/comfyui/custom_nodes/Civicomfy
if [ -d "$CIVI" ]; then
  linkfile "$VOL/config/civicomfy/root_settings.json"    "$CIVI/root_settings.json"
  linkfile "$VOL/config/civicomfy/download_history.json" "$CIVI/download_history.json"
fi

# Civitai has a "Workflows" model type whose payload is a workflow json, usually
# zipped. Civicomfy picks the target folder from the GUI's model_type and defaults
# to "checkpoint" when it is absent (server/routes/DownloadModel.py:32); there is
# no workflows entry in MODEL_TYPE_DIRS, so the type is not even selectable and
# a workflow download lands in models/checkpoints. Seen twice on pod qf80u7sb82t9nb.
#
# Two halves, both idempotent:
#   1. register a `workflows` folder so helpers.get_model_dir() — which asks
#      folder_paths before falling back to a literal folder under models/ —
#      resolves it to the real workflows directory, not models/workflows
#   2. add the type to MODEL_TYPE_DIRS so it appears in the GUI dropdown
# Civitai serves many "workflow" models as a .zip. Civicomfy downloads the file
# but never unpacks it, and ComfyUI cannot read a .zip as a workflow, so the
# graph is invisible until someone extracts it by hand. This watcher does that.
# It treats the archives as untrusted: path traversal, symlinks, oversized
# members and non-graph JSON are all refused, nothing is overwritten, and the
# original .zip is moved to workflows/_archives/ rather than deleted.
UNZIP=/workspace/scripts/workflow_unzip.py
if [ -f "$UNZIP" ]; then
  mkdir -p /workspace/logs
  python3 -I "$UNZIP" --once >> /workspace/logs/workflow_unzip.log 2>&1 || true
  setsid nohup python3 -I "$UNZIP" >> /workspace/logs/workflow_unzip.log 2>&1 < /dev/null &
  echo "  workflow zip watcher started (log: /workspace/logs/workflow_unzip.log)"
else
  echo "  note: $UNZIP absent, civitai workflow zips will not be unpacked"
fi

EMP=/opt/comfyui/extra_model_paths.yaml
emp_key() {  # emp_key <folder-type> <path-on-volume>
  local key="$1" path="$2"
  [ -f "$EMP" ] || return 0
  grep -qE "^[[:space:]]+${key}:" "$EMP" && return 0
  # match a sibling's indentation rather than assuming two spaces
  local ind
  ind=$(sed -nE 's/^([[:space:]]+)checkpoints:.*/\1/p' "$EMP" | head -1)
  [ -n "$ind" ] || ind="  "
  printf '%s%s: %s\n' "$ind" "$key" "$path" >> "$EMP"
  echo "  registered $key -> $path in extra_model_paths.yaml"
}
emp_key workflows "$VOL/workflows"
# ComfyUI-SeedVR2_VideoUpscaler reads extra_model_paths and matches the folder
# key case-insensitively (its README, "Fix: Case-insensitive model paths"), so a
# yaml entry is enough here - unlike sam2/controlnet_aux above, which hardcode.
mkdir -p "$VOL/models/SEEDVR2"
emp_key seedvr2 "$VOL/models/SEEDVR2"

# Impact Pack / Subpack. Without these keys the detector models on the volume
# are invisible to UltralyticsDetectorProvider and SAMLoader.
mkdir -p "$VOL/models/ultralytics/bbox" "$VOL/models/ultralytics/segm" \
         "$VOL/models/sams" "$VOL/custom_wildcards"
emp_key ultralytics      "$VOL/models/ultralytics"
emp_key ultralytics_bbox "$VOL/models/ultralytics/bbox"
emp_key ultralytics_segm "$VOL/models/ultralytics/segm"
emp_key sams             "$VOL/models/sams"

# Impact Pack reads impact-pack.ini at its pack root and logs
# "KeyError: 'default'" on every boot when it is absent, falling back to
# hardcoded defaults. The pack root is on the container disk now that packs are
# baked, so this is rewritten per pod - cheap and idempotent.
IPK=/opt/comfyui/custom_nodes/ComfyUI-Impact-Pack
if [ -d "$IPK" ] && [ ! -f "$IPK/impact-pack.ini" ]; then
  cat > "$IPK/impact-pack.ini" <<INI
[default]
sam_editor_cpu = False
sam_editor_model = sam_vit_b_01ec64.pth
custom_wildcards = $VOL/custom_wildcards
disable_gpu_opencv = True
gpu_gaussian_blur = False
wildcard_cache_limit_mb = 50
INI
  echo "  wrote $IPK/impact-pack.ini"
fi

# Subpack keeps its model whitelist under /opt/comfyui/user - container disk -
# so an edit would not survive the pod. Point it at the volume. It stays EMPTY
# by default on purpose: the whitelist is only a fallback for models that fail
# safe loading, and entries bypass a torch security check. The three detector
# models in use load fine with zero entries.
WLD=/opt/comfyui/user/default/ComfyUI-Impact-Subpack
mkdir -p "$VOL/config/impact-subpack" "$WLD"
[ -e "$VOL/config/impact-subpack/model-whitelist.txt" ] || \
  : > "$VOL/config/impact-subpack/model-whitelist.txt"
if [ ! -L "$WLD/model-whitelist.txt" ]; then
  rm -f "$WLD/model-whitelist.txt"
  ln -s "$VOL/config/impact-subpack/model-whitelist.txt" "$WLD/model-whitelist.txt" \
    && echo "  linked Subpack whitelist -> volume"
fi
# Verified in-process on 2026-11-18 rather than taken on trust: the pack walks
# folder_names_and_paths and compares folder_type.lower() to "seedvr2"
# (src/utils/constants.py, get_all_model_paths), and with this key present
# get_all_model_paths() returns /workspace/models/SEEDVR2 first.
# SeedVR2 needs BOTH a DiT and ema_vae_fp16.safetensors - the DiT alone cannot
# run, which is not obvious from the pack README.

# Node packs and their python deps are NOT kept on the volume. They are baked
# into the image (src/node_packs.txt), per the design rule at the top of the
# Dockerfile: the image owns the environment, the volume owns the data. An
# earlier pass here cloned packs into $VOL/custom_nodes and pip-installed their
# deps into $VOL/pylibs with a .pth, which is exactly the arrangement that rule
# exists to prevent - and it reproduced the predicted failure within the hour,
# when a volume-side omegaconf shadowed the image's working copy and broke
# hydra with "Could not deserialize ATN with version 3".
#
# If a stale $VOL/pylibs or $VOL/custom_nodes is still present from that pass,
# say so loudly rather than silently honouring it.
for stale in "$VOL/pylibs" "$VOL/custom_nodes"; do
  if [ -d "$stale" ] && [ -n "$(ls -A "$stale" 2>/dev/null)" ]; then
    echo "  WARNING: $stale exists and is not used by this image."
    echo "           Packs are baked in now. Remove it once you have confirmed"
    echo "           nothing you need is only there."
  fi
done
if [ -f "$CIVI/config.py" ] && ! grep -q '"workflows"' "$CIVI/config.py"; then
  python3 - "$CIVI/config.py" <<'PATCH'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    "wildcards": ("Wildcards", "wildcards"),'
if old in s and '"workflows"' not in s:
    s = s.replace(old, old + '\n    "workflows": ("Workflows", "workflows"),', 1)
    open(p, "w").write(s)
    print("  added Workflows to Civicomfy MODEL_TYPE_DIRS")
else:
    print("  Civicomfy config.py anchor missing; left alone")
PATCH
fi

echo "  volume ready at $VOL"
df -h "$VOL" 2>/dev/null | tail -1 | sed 's/^/  /'
