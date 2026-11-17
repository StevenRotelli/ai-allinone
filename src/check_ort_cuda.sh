#!/usr/bin/env bash
# Assert that onnxruntime's CUDA provider can actually LOAD. Runs on a machine
# with no GPU, which is the point: the GitHub builder has none.
#
# get_available_providers() is not evidence. CUDAExecutionProvider is compiled
# into the wheel and is listed even when its shared library cannot be loaded at
# all, so that check passed a build whose every InferenceSession fell back to
# CPU (onnxruntime-gpu 1.32.0, a CUDA-13 wheel, on a CUDA-12.8 base: missing
# libcublasLt.so.13). The honest test is whether the provider's .so resolves
# all of its dynamic dependencies -- which ldd answers without a device.
set -euo pipefail

SO=$(python - <<'PY'
import os, onnxruntime
print(os.path.join(os.path.dirname(onnxruntime.__file__), "capi",
                   "libonnxruntime_providers_cuda.so"))
PY
)

if [ ! -f "$SO" ]; then
  echo "FAIL: no CUDA provider library at $SO (is this the GPU wheel?)" >&2
  exit 1
fi
echo "provider library: $SO"

# ldd exits 0 even when entries are "not found", so grep is the gate.
missing=$(ldd "$SO" 2>/dev/null | awk '/not found/{print "  " $1}')
if [ -n "$missing" ]; then
  echo "FAIL: the CUDA provider cannot load; unresolved libraries:" >&2
  echo "$missing" >&2
  echo "This is the CUDA-major mismatch: a cu13 wheel wants libcublasLt.so.13," >&2
  echo "a cu12 base provides libcublasLt.so.12. Pin ORT_VERSION to a build on" >&2
  echo "the onnxruntime-cuda-12 feed and do not add PyPI as a fallback index." >&2
  exit 1
fi
echo "ort CUDA provider: all dynamic dependencies resolve"

# Belt and braces: the CUDA libs ort links against must be the 12 series.
ldd "$SO" 2>/dev/null | grep -oE 'lib(cublasLt|cublas|cudnn|cudart)\.so\.[0-9]+' \
  | sort -u | sed 's/^/  links /'
