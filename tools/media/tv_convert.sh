#!/bin/sh
# Convert any video into what a CRT in the city can play: a 4:3 Theora
# reel at 640x480 (the set's decoder resamples to 720 samples per line
# anyway) plus the sound as a separate MP3 for the set's speaker (Godot's
# VideoStreamPlayer cannot place its audio in 3D). Homebrew's ffmpeg has no
# Theora encoder, so the video goes through ffmpeg2theora (brew install
# ffmpeg2theora); the audio through ffmpeg.
#   tools/media/tv_convert.sh <input> [name] [start_s] [end_s]
# Writes tools/media/tv_streamer/cache/<name>.ogv and <name>.mp3. Untracked by git.
set -e
in="$1"
name="${2:-$(basename "$in" | sed 's/\.[^.]*$//' | tr -c 'A-Za-z0-9_.-\n' '_')}"
start="${3:-0}"
end="$4"
out="$(cd "$(dirname "$0")/../.." && pwd)/tools/media/tv_streamer/cache/$name"
mkdir -p "$(dirname "$out")"
range="-s $start"; [ -n "$end" ] && range="$range -e $end"
ffmpeg2theora $range -x 640 -y 480 --aspect 4:3 -F 30000:1001 -v 7 --noaudio --nosubtitles -o "$out.ogv" "$in"
aopts="-ss $start"; [ -n "$end" ] && aopts="$aopts -to $end"
ffmpeg -y -hide_banner -loglevel error $aopts -i "$in" -vn -sn -c:a libmp3lame -q:a 3 -ac 2 -ar 48000 "$out.mp3"
echo "$out.ogv"
