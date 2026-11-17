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
link() {  # link <target-on-volume> <path-comfy-expects>
  local tgt="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then return; fi
  if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    echo "  $dst has content, leaving it alone (expected $tgt)"; return
  fi
  rmdir "$dst" 2>/dev/null || true
  ln -s "$tgt" "$dst" && echo "  linked $dst -> $tgt"
}
link "$VOL/workflows" /opt/comfyui/user/default/workflows
link "$VOL/inputs"    /opt/comfyui/input
link "$VOL/outputs"   /opt/comfyui/output

echo "  volume ready at $VOL"
df -h "$VOL" 2>/dev/null | tail -1 | sed 's/^/  /'
