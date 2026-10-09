#!/bin/sh
# Turn a generated anchor clip into a loop the bulletin can play.
#
# The clip is played forwards and then backwards, so it ends on the frame it
# began on: it joins itself with no visible cut, and it joins any other loop
# of the same anchor, because every take of one anchor starts from the same
# reference frame. That is what lets the bulletin change her expression with
# the news and never show a jump. The sound is dropped — the anchor's voice
# is the TTS track, not the clip's.
#
#   tools/media/anchor_loop.sh <clip.mov> [anchor] [tone]
#
# Drag a clip onto the terminal and press return; it asks for the anchor and
# the tone. Writes tv/news/scripts/assets/<anchor>_<tone>.mp4 at the
# clip's own resolution and frame rate. Untracked by git.
#
# Adding a new expression is this script and nothing else: run it on the take,
# give it the same anchor name and a new tone, and the bulletin can use it.
set -e
in="$1"
[ -n "$in" ] || { printf 'Clip to loop: '; read -r in; }
[ -f "$in" ] || { echo "No such clip: $in" >&2; exit 1; }

anchor="$2"
[ -n "$anchor" ] || { printf 'Anchor name (e.g. anchorB): '; read -r anchor; }
tone="$3"
[ -n "$tone" ] || { printf 'Tone (normal, upset, delighted, …): '; read -r tone; }
[ -n "$anchor" ] && [ -n "$tone" ] || { echo "Anchor and tone are both needed." >&2; exit 1; }

out="$(cd "$(dirname "$0")/../.." && pwd)/tv/news/scripts/assets/${anchor}_${tone}.mp4"
mkdir -p "$(dirname "$out")"

frames=$(ffprobe -v error -select_streams v:0 -count_frames \
	-show_entries stream=nb_read_frames -of csv=p=0 "$in")
[ "$frames" -gt 2 ] 2>/dev/null || { echo "Clip has too few frames to loop: $frames" >&2; exit 1; }
fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$in")

# Forwards 0..N-1, then backwards N-2..1. The turnaround frame and the frame
# the loop wraps onto are each shown once, so neither end stutters.
ffmpeg -y -hide_banner -loglevel error -stats -i "$in" -an \
	-filter_complex "[0:v]split[a][b];[b]reverse,trim=start_frame=1:end_frame=$((frames - 1)),setpts=PTS-STARTPTS[r];[a][r]concat=n=2:v=1[out]" \
	-map "[out]" -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p \
	-r "$fps" -movflags +faststart "$out"

# The loop is only worth having if its seam is invisible: compare the last
# frame to the first. Above ~40 dB the join cannot be seen in motion.
last=$((frames * 2 - 3))
tmp="${TMPDIR:-/tmp}/anchor_loop_$$"
mkdir -p "$tmp"
ffmpeg -v error -i "$out" -vf "select=eq(n\,0)" -vframes 1 -y "$tmp/first.png"
ffmpeg -v error -i "$out" -vf "select=eq(n\,$last)" -vframes 1 -y "$tmp/last.png"
seam=$(ffmpeg -i "$tmp/last.png" -i "$tmp/first.png" -lavfi "[0:v][1:v]psnr" \
	-f null - 2>&1 | sed -n 's/.*average:\([0-9.]*\).*/\1/p')
rm -rf "$tmp"

echo "$out"
echo "  $((frames * 2 - 2)) frames at $fps, seam ${seam:-?} dB"
