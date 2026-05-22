#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: ./Scripts/fetch_video.sh <youtube_url> [name]"
  exit 1
fi

url="$1"
name="${2:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
videos_dir="$repo_root/Videos"
mkdir -p "$videos_dir"

max_bytes=$((90 * 1024 * 1024))
target_bytes=$((89 * 1024 * 1024))
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

video_id="$(yt-dlp --no-playlist --print id --skip-download "$url" 2>/dev/null | sed -n '1p' || true)"
if [[ -z "$video_id" ]]; then
  video_id="$(echo "$url" | sed -E 's|.*v=([^&]+).*|\1|')"
fi

if [[ -z "$name" ]]; then
  title="$(yt-dlp --no-playlist --print title --skip-download "$url" 2>/dev/null || true)"
  if [[ -n "$title" ]]; then
    name="$title"
  else
    name="$video_id"
  fi
fi

slug_base="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$slug_base" ]]; then
  slug_base="video"
fi
slug_base="${slug_base:0:64}"
slug_base="$(echo "$slug_base" | sed -E 's/-+$//')"

if [[ -n "$video_id" ]]; then
  slug="${slug_base}-${video_id}"
else
  slug="$slug_base"
fi

src_template="$tmp_dir/source.%(ext)s"
yt-dlp \
  --no-playlist \
  -S "res:720,fps:60,vcodec:h264,ext:mp4" \
  -f "bv*[ext=mp4][height<=720][fps<=60][vcodec^=avc1]/bv*[ext=mp4][height<=720][fps<=60]/b[ext=mp4][height<=720][fps<=60]/b[height<=720][fps<=60]" \
  -o "$src_template" \
  "$url"

shopt -s nullglob
src_candidates=("$tmp_dir"/source.*)
shopt -u nullglob
if [[ ${#src_candidates[@]} -eq 0 ]]; then
  echo "download failed: no source video found"
  exit 1
fi
src_path="${src_candidates[0]}"

duration="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$src_path")"
if [[ -z "$duration" ]]; then
  echo "failed to read source duration"
  exit 1
fi

target_bits=$((target_bytes * 8))
video_kbps="$(awk -v bits="$target_bits" -v d="$duration" 'BEGIN { if (d <= 0) print 1200; else print int((bits / d) / 1000 * 0.92) }')"
if [[ "$video_kbps" -lt 350 ]]; then
  video_kbps=350
fi
if [[ "$video_kbps" -gt 3000 ]]; then
  video_kbps=3000
fi

attempt=1
out_path=""
while [[ $attempt -le 4 ]]; do
  tmp_out="$tmp_dir/out-$attempt.mp4"
  maxrate_kbps=$((video_kbps * 12 / 10))
  bufsize_kbps=$((video_kbps * 2))

  ffmpeg -y -loglevel error -i "$src_path" \
    -vf "scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease" \
    -c:v libx264 -preset veryfast \
    -b:v "${video_kbps}k" -maxrate "${maxrate_kbps}k" -bufsize "${bufsize_kbps}k" \
    -pix_fmt yuv420p -movflags +faststart -an \
    "$tmp_out"

  size_bytes="$(stat -f%z "$tmp_out")"
  if [[ "$size_bytes" -le "$max_bytes" ]]; then
    out_path="$tmp_out"
    break
  fi

  video_kbps=$((video_kbps * 80 / 100))
  if [[ "$video_kbps" -lt 250 ]]; then
    video_kbps=250
  fi
  attempt=$((attempt + 1))
done

if [[ -z "$out_path" ]]; then
  echo "could not compress under 90MB"
  exit 1
fi

final_path="$videos_dir/$slug.mp4"
cp "$out_path" "$final_path"
final_bytes="$(stat -f%z "$final_path")"
final_mb="$(awk -v b="$final_bytes" 'BEGIN { printf "%.1f", b / 1024 / 1024 }')"
echo "saved: $final_path (${final_mb}MB)"
