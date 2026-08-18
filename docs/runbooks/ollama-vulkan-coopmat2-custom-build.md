# Runbook: benchmark and (optionally) build a custom Ollama image for Vulkan coopmat2

Applies to the `modules/ollama` GPU offload path (`var.gpu`) on Intel Arc
(Battlemage / Xe2) hardware running the upstream `ollama/ollama` image with
`OLLAMA_VULKAN=1`. Answers one question with hard numbers instead of guessing
from release notes: *is this build of Ollama actually using the GPU's matrix
cores, and does it matter for our workload?*

## Background

llama.cpp's Vulkan backend can accelerate matrix multiplication via
`VK_KHR_cooperative_matrix` ("coopmat2") on GPUs that expose it — Intel Xe2
(Battlemage, Lunar Lake) among them. Ollama vendors its own pinned copy of
llama.cpp (`LLAMA_CPP_VERSION` in the `ollama/ollama` repo, currently a
`bNNNNN`-style tag) and bumps it periodically; whether a given Ollama release
picked up a working coopmat2 path for your specific GPU is not reliably
inferable from Ollama's changelog — it never calls out Intel Vulkan matrix-core
support explicitly. The only way to know for certain is to build llama.cpp
yourself and check the runtime capability line, then benchmark.

## Step 1 — build bare llama.cpp and check the capability line

Run this as a throwaway pod on the GPU node (same device/group access pattern
`modules/ollama` grants the production StatefulSet: the render node character
device plus the host `video`/`render` supplemental GIDs, privileged). Give it
generous, unconstrained resources in its own namespace — the build is
memory-hungry (a single heavy translation unit, `ggml-vulkan.cpp`, can OOM at
4Gi even with only 2 parallel jobs; ~10Gi with `-j` scaled to available cores
built cleanly) and a tight shared-namespace `ResourceQuota` is the wrong place
to fight that. A namespace with no quota, cleaned up afterward, is simpler
than trying to squeeze a one-off build into production headroom.

```bash
kubectl create namespace llamacpp-bench
# Pod spec: nodeSelector matching your GPU node, the render-node char device
# mounted read-write, supplementalGroups for video+render, privileged: true —
# mirror modules/ollama's var.gpu wiring (device_path, supplemental_groups).
```

Inside the pod:

```bash
apt-get update && apt-get install -y git cmake build-essential libvulkan-dev \
  glslc vulkan-tools spirv-headers glslang-tools glslang-dev pkg-config curl
# spirv-headers + glslang-tools are easy to miss: glslc alone is not enough —
# cmake fails on `find_package(SPIRV-Headers)` without them.

git clone --depth 1 https://github.com/ggml-org/llama.cpp /src
cd /src
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2 --target llama-bench   # raise -j only if memory allows
```

Run it against any small GGUF (a tiny public model is fine for this check —
you don't need your production model yet):

```bash
./build/bin/llama-bench -m tiny.gguf -ngl 999 -p 512 -n 128
```

The line that answers the question:

```
ggml_vulkan: 0 = <GPU name> | fp16: 1 | ... | matrix cores: KHR_coopmat
```

`matrix cores: none` means this llama.cpp build/driver combination is not
using the GPU's matrix units for this device — stop here, there is nothing to
gain from a custom build. `KHR_coopmat` (or a vendor-specific coopmat variant)
means it is active; proceed to a same-model comparison.

Note: a plain `llama-cli -v` run may not print this line at all — logging
verbosity and format around backend device init have changed across llama.cpp
revisions. `llama-bench` prints it reliably. Don't conclude "not supported"
from its absence in `llama-cli` output alone.

## Step 2 — apples-to-apples benchmark on the real model

Mount the Ollama data volume read-only into the same build pod (it's the same
node, so this is a local hostPath mount, not a copy) and point `llama-bench`
directly at the blob Ollama already has on disk — no need to re-download a
multi-gigabyte model:

```bash
# Find the model layer digest from Ollama's manifest:
cat /root/.ollama/models/manifests/registry.ollama.ai/library/<model>/<tag>
# -> layers[].digest where mediaType ends in ".model"

./build/bin/llama-bench -m /ollama-data/models/blobs/sha256-<digest> -ngl 999 -p 512 -n 128
```

Compare `pp512` (prefill, prompt processing) and `tg128` (decode, token
generation) against what your current production Ollama actually serves for
the same model — measured through Ollama's own API, not a different tool, so
the comparison is meaningful:

```bash
curl http://ollama.<namespace>.svc.cluster.local:11434/api/generate -d \
  '{"model":"<model>","prompt":"<a long prompt, several hundred tokens>",
    "stream":false,"options":{"num_predict":1,"temperature":0}}'
# response.prompt_eval_count / (response.prompt_eval_duration / 1e9) = prefill tok/s

curl ... -d '{"model":"<model>","prompt":"<short prompt>","stream":false,
              "options":{"num_predict":64,"temperature":0}}'
# response.eval_count / (response.eval_duration / 1e9) = decode tok/s
```

**Expect prefill to improve and decode not to.** Cooperative-matrix
acceleration speeds up batched matrix-matrix multiplication (prefill, which
processes the whole prompt as one batch); single-token autoregressive decode
is memory-bandwidth-bound regardless of matrix-core availability, so it will
not move. This is architecturally expected, not a sign the bump failed. Don't
compare a raw `llama-bench` number against an Ollama-served number and call
the difference a "generation speedup" without re-measuring generation the
same way on both sides — the two harnesses have enough serving overhead
difference (tokenization, HTTP, scheduling) to manufacture an apparent gap
that isn't really there.

If your workload is decode-heavy (short prompts, long generations — a typical
back-and-forth chat), a coopmat2 win may not be worth the maintenance cost
below. If it's prefill-heavy (long system prompts, RAG context, long
conversation history resent every turn), it is.

## Step 3 — build and deploy a custom image, if it's worth it

Ollama pins its llama.cpp source via a single text file and applies a small
compatibility patch on top (as of writing, one ~5KB patch touching
`llama-model-loader.cpp` to translate legacy tensor/metadata shapes for
already-published Ollama model blobs — see `llama/compat/` and its README in
the `ollama/ollama` source tree). Bumping is a two-line change:

```bash
git clone --depth 1 https://github.com/ollama/ollama.git
cd ollama
echo "<new-llama.cpp-tag-or-commit>" > LLAMA_CPP_VERSION
```

Pick a target you've already validated in Step 2 (the exact commit or tag you
benchmarked), not the latest upstream HEAD sight-unseen — the compatibility
patch is small and has survived a many-tag jump in practice, but "we already
proved this exact commit works and reports the numbers we want" is a much
better invariant than "the newest thing is probably fine."

The Dockerfile builds one backend per GPU vendor as a separate stage
(`llama-server-cpu`, `-cuda_v12`, `-cuda_v13`, `-rocm_v7_2`, `-vulkan`, ...)
and assembles them into the final image. If your fleet only has one vendor's
GPU, trim the unused stages out of the final assembly stage(s) locally before
building — the default target unconditionally builds every backend, including
multi-gigabyte CUDA SDK base images you'll never use. Docker's dependency
graph only builds what a `COPY --from=<stage>` actually references, so
deleting the unwanted `COPY --from=llama-server-cuda_v12` (etc.) lines is
enough; no need to touch the backend stages themselves.

```bash
docker build -t ollama-custom:<tag> .
```

### Loading a single-node pinned image without a registry

If the GPU workload is pinned to one node (a `nodeSelector` matching one piece
of hardware, as `modules/ollama`'s `gpu` config typically is), there is no
need to push the custom image anywhere. Save it and import it directly into
that node's containerd:

```bash
docker save ollama-custom:<tag> | ssh <gpu-node> \
  'sudo k3s ctr -n k8s.io images import -'
```

Point the module's `gpu.image` at the same repository:tag string. Kubernetes'
default `imagePullPolicy` for any tag other than `:latest` is `IfNotPresent`,
so kubelet uses the already-imported local image without attempting (and
failing) a registry pull — no explicit pull-policy override needed.

## Reverse story

Revert `gpu.image` to the stock upstream tag and re-apply; the StatefulSet
rolls back to the published image on the next pod restart. No data migration
is involved — the model blobs and Ollama's on-disk state are unaffected by
which binary serves them.

## When to re-run this check

Re-benchmark whenever upstream Ollama bumps its `LLAMA_CPP_VERSION` past the
commit you last validated — if Ollama's own vendored copy catches up to the
same coopmat2 support, the custom build reduces to "identical performance,
extra maintenance burden," and the stock image should be preferred again.
