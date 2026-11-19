#!/usr/bin/env bash
# Downloads the pinned yt-dlp, deno, ffmpeg and ffprobe binaries into vendor/tools/
# and verifies their SHA-256 checksums. Re-running is a no-op when versions match.
set -euo pipefail

YTDLP_VERSION="2026.10.26"
DENO_VERSION="v2.9.8"
FFMPEG_BUILD="1789931890_9.0.2"      # https://ffmpeg.martin-riedl.de (macOS arm64 release build)
FFMPEG_VERSION="${FFMPEG_BUILD#*_}"

cd "$(dirname "$0")/.."
DEST="vendor/tools"
STAMP="$DEST/.versions"
WANT="yt-dlp=$YTDLP_VERSION deno=$DENO_VERSION ffmpeg=$FFMPEG_BUILD"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANT" ]]; then
  echo "Tools up to date ($WANT)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# Usage: verify <file> <expected sha256>
verify() {
  local got
  got="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$got" != "$2" ]]; then
    echo "Checksum mismatch for $1: expected $2, got $got" >&2
    exit 1
  fi
}

echo "Fetching yt-dlp $YTDLP_VERSION"
YT="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
fetch "$YT/yt-dlp_macos" "$TMP/yt-dlp"
fetch "$YT/SHA2-256SUMS" "$TMP/yt-dlp.sums"
verify "$TMP/yt-dlp" "$(awk '$2 == "yt-dlp_macos" {print $1}' "$TMP/yt-dlp.sums")"

echo "Fetching deno $DENO_VERSION"
DN="https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-aarch64-apple-darwin.zip"
fetch "$DN" "$TMP/deno.zip"
fetch "$DN.sha256sum" "$TMP/deno.sum"
verify "$TMP/deno.zip" "$(awk '{print $1}' "$TMP/deno.sum")"
unzip -qo "$TMP/deno.zip" -d "$TMP/deno"

for tool in ffmpeg ffprobe; do
  echo "Fetching $tool $FFMPEG_VERSION"
  FF="https://ffmpeg.martin-riedl.de/download/macos/arm64/$FFMPEG_BUILD/$tool.zip"
  fetch "$FF" "$TMP/$tool.zip"
  fetch "$FF.sha256" "$TMP/$tool.sum"
  verify "$TMP/$tool.zip" "$(awk '{print $1}' "$TMP/$tool.sum")"
  unzip -qo "$TMP/$tool.zip" -d "$TMP/$tool"
done

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$TMP/yt-dlp" "$DEST/yt-dlp"
cp "$TMP/deno/deno" "$DEST/deno"
cp "$TMP/ffmpeg/ffmpeg" "$DEST/ffmpeg"
cp "$TMP/ffprobe/ffprobe" "$DEST/ffprobe"
chmod +x "$DEST"/*
xattr -c "$DEST"/* 2>/dev/null || true

cat > "$DEST/versions.json" <<JSON
{"yt-dlp": "$YTDLP_VERSION", "deno": "${DENO_VERSION#v}", "ffmpeg": "$FFMPEG_VERSION"}
JSON
echo "$WANT" > "$STAMP"
echo "Tools ready in $DEST"
