# ai-allinone

One image with everything the face-swap pipeline needs, so a rented GPU is
usable in the time it takes to pull a container — no installs, no model
downloads, no network races at boot.

Published to `ghcr.io/stevenrotelli/ai-allinone`.

| | |
|---|---|
| ComfyUI | `/opt/comfyui`, 24 node packs baked, port **8188** |
| FaceFusion | `/opt/facefusion`, importable *and* CLI, UI on **7860** (opt-in) |
| DeepFaceLab-Revamped | `/opt/dfl`, SAEHD training + `exportdfm` |
| JupyterLab | port **8888**, rooted at `/workspace` |
| MatAnyone / SAM2 | `/opt/matanyone`, `/opt/sam2` |
| torch | pinned, CUDA 12.8, frozen via `PIP_CONSTRAINT` |
| ffmpeg | **static build**, not apt's |

## The one design rule

**The image owns the environment. The volume owns the data.**

Nothing is pip-installed at boot and nothing executable lives on the network
volume. This is a direct response to how the previous setup failed:

- python deps lived on the volume with `PYTHONPATH` pointing at them, so a
  transitively-installed `torch` shadowed the CUDA-matched build — once fatally
  (`libtorch_global_deps.so` missing), and once as a silent CPU fallback
- a cleanup script that deleted paths under that directory destroyed 360 GB of
  models, because the data and the scratch space were the same filesystem

Here the volume holds models, workflows, inputs, outputs and training data.
Nothing on it can break a boot, and no dependency fix needs to touch it.

## Volume layout

`src/volume_init.sh` creates this on first boot and never deletes anything:

```
/workspace/
  models/{checkpoints,loras,vae,vae_approx,clip_vision,controlnet,
          diffusion_models,text_encoders,upscale_models,embeddings,
          latent_upscale_models,detection,frame_interpolation,
          facefusion,dfl}
  workflows/            -> symlinked to ComfyUI user/default/workflows
  inputs/               -> symlinked to ComfyUI input
  outputs/              -> symlinked to ComfyUI output
  dfl/{models,data_src,data_dst}
  logs/  notebooks/  scratch/
```

`vae_approx`, `latent_upscale_models`, `detection` and `frame_interpolation` are
in there because they are real ComfyUI folder keys that the default config omits
— a model in an unmapped folder is invisible with **no error at all**.

## Environment

| var | effect |
|---|---|
| `JUPYTER_TOKEN` | required to start JupyterLab; without it Jupyter stays down rather than serving tokenless on a public proxy |
| `START_FACEFUSION=1` | also start the FaceFusion UI on 7860 |
| `COMFY_EXTRA_ARGS` | appended to the ComfyUI command line |
| `PUBLIC_KEY` | injected by RunPod; enables sshd |
| `CIVITAI_API_KEY`, `HF_TOKEN` | inherited by every child, since start.sh is PID 1 |

## Why these choices

**`PIP_CONSTRAINT` with torch frozen.** Torch is installed first, pinned into
`/torch-constraint.txt`, and that file is exported as `PIP_CONSTRAINT`. Every
later `pip install` — node pack requirements, FaceFusion, anything — inherits
it, so none of them can move torch. The failure mode is impossible rather than
documented.

**Static ffmpeg.** apt ships 4.4.2, which renders silently-black video that
passes every size and duration check. FaceFusion output looks correct to every
automated test and is blank.

**onnxruntime-gpu from Microsoft's CUDA-12 index.** The PyPI build targets a
different CUDA and falls back to CPU with no error — detection and swap stages
just run slowly for no visible reason. It is also reasserted *after* the node
packs and FaceFusion install, because their requirements pin the CPU build and
would otherwise clobber it.

**Node packs baked, not cloned at boot.** A pod must never fail to start because
GitHub is unreachable, and a pack must never change without a rebuild and a new
tag.

**The container never exits.** If a service dies, `start.sh` keeps running so the
log stays readable. A crash-loop buries the reason.

## Building

Push to `main`, or run the workflow manually with an optional tag:

```sh
gh workflow run "build image" -f tag=v1
```

Tags published: `latest` (default branch), `sha-<short>`, and any manual tag.

The workflow reclaims ~25-30 GB on the runner first by removing the
preinstalled .NET/Android/GHC toolchains — a GitHub-hosted runner has ~14 GB
free and this image does not fit without it.

## Running on RunPod

```
image         ghcr.io/stevenrotelli/ai-allinone:latest
volume        ai-stack -> /workspace
ports         8188/http, 8888/http, 7860/http, 22/tcp
env           JUPYTER_TOKEN=<something>
```

GHCR packages are private by default, so the RunPod template needs registry
credentials: a GitHub PAT with `read:packages` as the password.
