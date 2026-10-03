#!/bin/sh
# Usage: whisper-fetch-model <url> <destination file> <sha256>
#
# Downloads a model file once and verifies it. A file already at the
# destination with the expected checksum is kept, so a pod restart does not
# re-download half a gigabyte; a file with the wrong checksum (a torn
# download, a changed model) is replaced. The download lands in a temporary
# file and is renamed only after it verifies, so the server never sees a
# partial model.
set -eu

log() { echo "whisper-fetch-model: $*" >&2; }

if [ "$#" -ne 3 ]; then
  log "usage: whisper-fetch-model <url> <destination file> <sha256>"
  exit 2
fi

url=$1
dest=$2
want=$(printf '%s' "$3" | tr 'A-F' 'a-f')

sum() { sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$dest" ]; then
  if [ "$(sum "$dest")" = "$want" ]; then
    log "$dest present and verified"
    exit 0
  fi
  log "$dest has the wrong checksum; downloading again"
fi

mkdir -p "$(dirname "$dest")"
tmp="$dest.partial"
rm -f "$tmp"
curl --fail --location --retry 5 --retry-delay 5 --silent --show-error --output "$tmp" "$url"

got=$(sum "$tmp")
if [ "$got" != "$want" ]; then
  rm -f "$tmp"
  log "checksum mismatch for $url: got $got, want $want"
  exit 1
fi

mv "$tmp" "$dest"
log "$dest downloaded and verified"
