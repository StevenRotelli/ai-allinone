#!/usr/bin/env bash
# Assert that onnxruntime's CUDA provider can actually LOAD. Designed to run on a
# machine with NO GPU, which is the point: the GitHub builder has none.
#
# get_available_providers() is not evidence. CUDAExecutionProvider is compiled
# into the wheel and is listed even when its shared library cannot be loaded at
# all, so that check passed a build whose every InferenceSession fell back to
# CPU (onnxruntime-gpu 1.32.0, a CUDA-13 wheel, on a CUDA-12.8 base: missing
# libcublasLt.so.13). The honest test is whether the provider's .so resolves its
# dynamic dependencies -- which ldd answers without a device.
#
# One exception, and only one: libcuda.so.1 is the NVIDIA DRIVER, not part of
# the CUDA toolkit. The container runtime injects it at run time, so it is
# legitimately absent at build time on a GPU-less runner and present on any pod.
# It must not be confused with the toolkit libraries (libcublas, libcublasLt,
# libcudart, libcudnn), whose absence is exactly the failure being hunted. The
# cu13-on-cu12 case stays caught: on the pod that reported libcublasLt.so.13,
# libcublas.so.13 and libcudart.so.13 as missing, and none of those are exempt.
#
# Set CHECK_ORT_LDD_FIXTURE=<file> to test this script's logic against canned
# ldd output, with no onnxruntime and no GPU involved.
set -uo pipefail

# Driver-provided, injected by the container runtime. Everything else must resolve.
DRIVER_LIBS='^(libcuda\.so\.1|libnvidia-ml\.so\.1)$'

if [ -n "${CHECK_ORT_LDD_FIXTURE:-}" ]; then
  LDD_OUT=$(cat "$CHECK_ORT_LDD_FIXTURE")
  SO="(fixture $CHECK_ORT_LDD_FIXTURE)"
else
  SO=$(python - <<'PY'
import os, onnxruntime
print(os.path.join(os.path.dirname(onnxruntime.__file__), "capi",
                   "libonnxruntime_providers_cuda.so"))
PY
  ) || { echo "FAIL: cannot locate onnxruntime" >&2; exit 1; }
  if [ ! -f "$SO" ]; then
    echo "FAIL: no CUDA provider library at $SO (is this the GPU wheel?)" >&2
    exit 1
  fi
  LDD_OUT=$(ldd "$SO" 2>/dev/null)
fi
echo "provider library: $SO"

# ldd exits 0 even when entries are "not found", so the grep is the gate.
all_missing=$(printf '%s\n' "$LDD_OUT" | awk '/not found/{print $1}' | sort -u)
missing=$(printf '%s\n' "$all_missing" | grep -vE "$DRIVER_LIBS" | grep -v '^$' || true)
exempt=$(printf '%s\n' "$all_missing"  | grep -E "$DRIVER_LIBS" | grep -v '^$' || true)

if [ -n "$exempt" ]; then
  printf '  driver-provided, absent at build time (expected): %s\n' "$(echo $exempt)"
fi

if [ -n "$missing" ]; then
  echo "FAIL: the CUDA provider cannot load; unresolved libraries:" >&2
  printf '  %s\n' $missing >&2
  echo "These are CUDA TOOLKIT libraries and must be in the image. A cu13 wheel" >&2
  echo "wants libcublasLt.so.13 while a cu12 base provides libcublasLt.so.12," >&2
  echo "so pin ORT_VERSION to a build on the onnxruntime-cuda-12 feed and do" >&2
  echo "not add PyPI as a fallback index (pip takes the highest version across" >&2
  echo "all indexes, which is how a CUDA-13 wheel wins)." >&2
  exit 1
fi
echo "ort CUDA provider: all toolkit dependencies resolve"

# Belt and braces: the CUDA libs it links against must be the 12 series.
printf '%s\n' "$LDD_OUT" \
  | grep -oE 'lib(cublasLt|cublas|cudnn|cudart)\.so\.[0-9]+' \
  | sort -u | sed 's/^/  links /'
