#!/usr/bin/env bash
#
# Capture the current ICY (Icecast) metadata title from the Maxi80 stream.
#
# Reads the stream with the "Icy-MetaData: 1" header, honours the icy-metaint
# byte interval the server advertises, and prints the first StreamTitle it finds.
# Useful for confirming whether the broadcaster is currently emitting real track
# metadata or only the station's default/filler title.
#
# Usage:
#   scripts/stream-metadata.sh [STREAM_URL]
#
# Defaults to the production stream if no URL is given.

set -euo pipefail

STREAM_URL="${1:-https://audio1.maxi80.com}"
MAX_SECONDS="${MAX_SECONDS:-20}"

# Pull a chunk of the stream (audio + interleaved metadata) with the ICY header,
# then extract the StreamTitle. `strings` isolates the printable metadata block
# from the surrounding binary audio so grep can find the title reliably.
#
# curl is expected to hit --max-time on this never-ending stream (exit 28); that
# is normal, so the curl exit status is deliberately ignored (|| true).
raw="$(
  curl -s \
    -H "Icy-MetaData: 1" \
    -H "User-Agent: maxi80/1.0" \
    --max-time "$MAX_SECONDS" \
    "$STREAM_URL" 2>/dev/null || true
)"

title="$(
  printf '%s' "$raw" \
    | LC_ALL=C strings \
    | grep -ao "StreamTitle=[^;]*" \
    | head -1 \
    | sed "s/^StreamTitle='//; s/'$//"
)"

if [ -z "$title" ]; then
  echo "No StreamTitle metadata found (stream may not be sending ICY metadata)." >&2
  exit 1
fi

echo "$title"
