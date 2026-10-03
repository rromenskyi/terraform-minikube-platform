#!/bin/sh
# Picks the Vulkan device, checks it is really there, then runs
# whisper-server with the container's arguments.
#
# WHISPER_VULKAN_DEVICE_ID   PCI `vendor:device` in hex (e.g. 8086:e212).
#                            Hands the pin to Mesa's device-select layer and
#                            filters enumeration down to that device. A pin
#                            by PCI id survives the enumeration-order changes
#                            a reboot or a Mesa upgrade can cause, which an
#                            index pin does not. A privileged pod sees every
#                            host render node, so on a multi-GPU host this is
#                            what keeps whisper off the integrated GPU.
# WHISPER_REQUIRE_GPU        "1" (default) refuses to start when Vulkan lists
#                            only CPU devices (llvmpipe) — the symptom of a
#                            missing device mount or a Mesa too old for the
#                            card. "0" allows a CPU-only run, for local tests.
set -eu

log() { echo "whisper-entrypoint: $*" >&2; }

pin=$(printf '%s' "${WHISPER_VULKAN_DEVICE_ID:-}" | tr 'A-F' 'a-f')
require_gpu="${WHISPER_REQUIRE_GPU:-1}"

if [ -n "$pin" ]; then
  case "$pin" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) log "WHISPER_VULKAN_DEVICE_ID='$pin' is not a vendor:device hex pair (e.g. 8086:e212)"; exit 1 ;;
  esac
  export MESA_VK_DEVICE_SELECT="$pin"
  export MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1
fi

if ! summary=$(vulkaninfo --summary 2>&1); then
  log "vulkaninfo failed:"
  printf '%s\n' "$summary" >&2
  [ "$require_gpu" = "1" ] && exit 1
  summary=""
fi

# One line per enumerated device: "<vendor>:<device> <deviceType> <deviceName>".
devices=$(printf '%s\n' "$summary" | awk '
  function flush() { if (vendor != "") print vendor ":" device " " type " " name; vendor = device = type = name = "" }
  /^GPU[0-9]+:/            { flush() }
  /^[[:space:]]+vendorID/  { vendor = tolower($3); sub(/^0x/, "", vendor) }
  /^[[:space:]]+deviceID/  { device = tolower($3); sub(/^0x/, "", device) }
  /^[[:space:]]+deviceType/ { type = $3 }
  /^[[:space:]]+deviceName/ { sub(/^[^=]*=[[:space:]]*/, ""); name = $0 }
  END { flush() }
')

log "vulkan devices visible (pin='${pin:-none}'):"
printf '%s\n' "${devices:-  (none)}" | sed 's/^/  /' >&2

if [ -n "$pin" ] && ! printf '%s\n' "$devices" | grep -q "^$pin "; then
  log "pinned device $pin is not in the Vulkan device list — check the device mount, supplemental groups and Mesa version"
  exit 1
fi

if [ "$require_gpu" = "1" ] && ! printf '%s\n' "$devices" | grep -q -E 'PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED|VIRTUAL)_GPU'; then
  log "no GPU in the Vulkan device list (CPU only); refusing to decode on the CPU. Set WHISPER_REQUIRE_GPU=0 to allow it."
  exit 1
fi

exec /usr/local/bin/whisper-server "$@"
