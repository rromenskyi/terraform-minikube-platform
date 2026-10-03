# Runbook: build, load and verify the whisper.cpp Vulkan recogniser

Applies to `whisper.tf` (`services.whisper`): a whisper.cpp `whisper-server`
decoding on a GPU through Vulkan, sharing the card with Ollama, exposing an
OpenAI-shaped transcription route in-cluster. The image is built by the
operator from `images/whisper-server-vulkan/` — no upstream image ships a Mesa
recent enough for every card.

## What the image does

- `whisper-server` from a pinned whisper.cpp tag (`WHISPER_CPP_REF`), built
  with `GGML_VULKAN=ON` and `GGML_NATIVE=OFF` (built on one machine, run on
  another).
- `whisper-entrypoint` picks and checks the GPU before the server starts:
  - `WHISPER_VULKAN_DEVICE_ID=<vendor>:<device>` (PCI ids, hex) hands the pin
    to Mesa's device-select layer and filters enumeration down to that device.
    A privileged pod sees every render node on the host, so on a host with an
    integrated GPU as well this is what keeps whisper on the discrete card. A
    PCI-id pin survives the enumeration-order changes that a reboot or Mesa
    upgrade can cause; an index pin does not.
  - Exits non-zero when the pinned device is missing, or when Vulkan lists only
    CPU devices (llvmpipe) — the symptom of a missing device mount or a Mesa
    too old for the card. Without this the server starts anyway and decodes on
    the CPU, many times slower, with nothing in the probes to show it.
  - Logs the device list it saw on every start.
- `whisper-fetch-model` (init container) downloads the model once into the
  hostPath volume and verifies its sha256 on every start.

## Build

Pick `BASE_IMAGE` so its Mesa matches the GPU node's generation (the default
`ubuntu:26.04` ships Mesa 26). Build for the node's architecture:

```bash
cd images/whisper-server-vulkan
docker build --platform linux/amd64 \
  --build-arg WHISPER_CPP_REF=v1.9.4 \
  --build-arg BUILD_JOBS=8 \
  -t whisper-server-vulkan:v1.9.4-1 .
```

`ggml-vulkan` is the heavy translation unit; give the build several GiB of
memory or lower `BUILD_JOBS`. Under emulation (building amd64 on an arm64
machine) expect the build to take much longer — building on an amd64 host is
faster.

## Load into the GPU node

The pod is pinned to the GPU node, so the image does not need a registry —
import it straight into that node's containerd, as the Ollama runbook does:

```bash
docker save whisper-server-vulkan:v1.9.4-1 | ssh <gpu-node> 'sudo k3s ctr -n k8s.io images import -'
```

Use a tag other than `:latest`; kubelet then defaults to `IfNotPresent` and
uses the imported image without trying a registry.

## Configure

In `config/platform.yaml`:

```yaml
services:
  whisper:
    enabled: true
    image: docker.io/library/whisper-server-vulkan:v1.9.4-1
    node_selector:
      gpu: intel                        # same node as Ollama
    gpu:
      device_path: /dev/dri/renderD129  # the discrete card's render node
      device_type: CharDevice
      privileged: true                  # as services.ollama.gpu on the same host
      supplemental_groups: [44, 990]    # host video + render GIDs
      vulkan_device_id: "8086:e212"     # PCI vendor:device of the card
```

Find the PCI id with `lspci -nn | grep -Ei 'vga|display'` on the node, or
`cat /sys/bus/pci/devices/*/{vendor,device}` from any privileged pod there.

### VRAM: share the card, don't starve it

Ollama and whisper-server each hold their model in VRAM; neither knows about
the other. Before enabling, check the headroom on the card:

- whisper-server's start log lists its buffers (`whisper_model_load: ... buffer
  size`, `whisper_init_state: compute buffer`); large-v3-turbo q5_0 is roughly
  0.6 GB of weights plus a few hundred MB of compute buffers.
- Ollama's own VRAM estimate can be off; look at the driver's view (for
  example `intel_gpu_top` / `xpu-smi` on Intel) with the chat model loaded and
  busy.

If the two do not fit, shrink Ollama's share first: fewer parallel slots
(`OLLAMA_NUM_PARALLEL`) or a smaller `num_ctx` free KV-cache memory without
changing the chat model. An over-full card shows up as Vulkan allocation
failures in either pod's log, or as Ollama offloading layers to the CPU.

## Verify

From any pod in the cluster (the Service is internal-only), post a 16 kHz
mono WAV with the same multipart fields an OpenAI-compatible transcription
client sends (`model`, `response_format`, optional `language` and `prompt`,
and `file`):

```bash
curl -s http://whisper.<namespace>.svc.cluster.local:8080/v1/audio/transcriptions \
  -F model=whisper-1 \
  -F response_format=verbose_json \
  -F file=@sample-16k.wav
```

Expect `text`, `language` and `duration` in the reply. The server ignores
`model` — it serves the one model it loaded.

Latency: whisper-server logs its per-request timings (`whisper_print_timings`).
Compare `total time` with the in-process recogniser's per-utterance decode
time for utterances of similar length. A decode several times slower than
that means the work landed on the CPU — the entrypoint's device-list line
says which device Vulkan used.

## Facts a gateway provider entry needs

- **Base URL:** `http://whisper.<namespace>.svc.cluster.local:8080/v1` (the
  route is `/v1/audio/transcriptions`).
- **Concurrency limit: 1.** whisper-server holds a single model context behind
  a mutex and decodes one request at a time; extra requests wait inside the
  pod. Cap the provider at 1 so overflow moves to the next tier instead of
  queueing behind another call.
- **Language in:** `language` takes an ISO 639-1 code (`en`, `uk`) or `auto`;
  omitted means auto-detect. A region-tagged BCP-47 value (`en-US`) is not a
  Whisper language and fails the request with HTTP 500 — strip the region
  before sending.
- **Language out:** with `verbose_json`, `language` is the full lower-case
  English name (`english`, `ukrainian`), not a code. With language
  probabilities on (drop `--no-language-probabilities` from
  `services.whisper.extra_args`), `detected_language_probability` is added at
  the cost of an extra encoder pass per request.
- **No confidence field.** The reply carries text, language, duration and
  segments only.
- **Audio in:** WAV (any rate is resampled to 16 kHz; send 16 kHz to skip
  that). The image has no ffmpeg, so compressed formats are not accepted.

## Rollback

Set `services.whisper.enabled: false` and apply. The model file stays on the
node's hostPath volume (the PV is `Retain`), so re-enabling does not download
it again.
