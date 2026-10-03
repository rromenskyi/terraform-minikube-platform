# whisper.cpp `whisper-server` built with the Vulkan backend, for running a
# Whisper model on a GPU that has no CUDA path (Intel Arc, AMD). Consumed by
# `whisper.tf` through `services.whisper.image`; build and load instructions
# live in docs/runbooks/whisper-server-vulkan-image.md.
#
# The base must ship a Mesa new enough to drive the GPU it runs on. Older
# Mesa releases do not know recent Intel discrete cards and Vulkan then
# enumerates only llvmpipe — the server still starts, but decodes on the CPU
# many times slower. Match BASE_IMAGE to the host's Mesa generation; the
# entrypoint refuses to start on a CPU-only device list so a too-old Mesa
# fails loudly instead.
ARG BASE_IMAGE=ubuntu:26.04

FROM ${BASE_IMAGE} AS build

ARG WHISPER_CPP_REF=v1.9.4
ARG BUILD_JOBS=4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates cmake git glslc libvulkan-dev spirv-headers \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${WHISPER_CPP_REF}" https://github.com/ggml-org/whisper.cpp /src

WORKDIR /src

# GGML_NATIVE=OFF: the image is built on one machine and run on another, so
# host-specific CPU instructions would crash the server on the GPU node.
# Static libraries keep the runtime stage to a single binary.
RUN cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_VULKAN=ON \
      -DGGML_NATIVE=OFF \
      -DBUILD_SHARED_LIBS=OFF \
      -DWHISPER_BUILD_TESTS=OFF \
    && cmake --build build -j"${BUILD_JOBS}" --target whisper-server

FROM ${BASE_IMAGE}

# vulkan-tools provides `vulkaninfo`, which the entrypoint uses to check the
# device list before the model loads. curl fetches the model in the init
# container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl libgomp1 libvulkan1 mesa-vulkan-drivers vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/bin/whisper-server /usr/local/bin/whisper-server
COPY entrypoint.sh /usr/local/bin/whisper-entrypoint
COPY fetch-model.sh /usr/local/bin/whisper-fetch-model
RUN chmod 0755 /usr/local/bin/whisper-entrypoint /usr/local/bin/whisper-fetch-model

USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/whisper-entrypoint"]
