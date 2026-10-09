#!/bin/sh
# Put a folder of generated clips on air as the channel's idents.
#
#   tools/media/install_bumpers.sh                        the TRT glass bumpers → continuity/
#   tools/media/install_bumpers.sh <folder>               that folder → continuity/
#   tools/media/install_bumpers.sh <folder> commercials   …into commercials/ instead
#
# Two things are done to each clip, and both are why dropping the mp4s into
# the folder by hand does not work:
#
#   1. A SILENT TRACK IS ADDED.  The generated bumpers have no audio stream at
#      all.  Playout refuses silent media unless the package says the silence
#      is deliberate, and a stream whose audio stops for twelve seconds and
#      comes back is a stream players resynchronise through — audibly.  The
#      video is copied, not re-encoded; only a silent AAC track is added, at
#      the channel's own rate.
#   2. A MANIFEST IS WRITTEN.  A clip with no .package.json is guessed at from
#      the folder it sits in.  The manifest states it: a repeatable continuity
#      item that never expires.
#
# Re-running is safe: a clip already installed is skipped, so this can be
# pointed at the folder again after generating more.
set -e
here="$(cd "$(dirname "$0")/../.." && pwd)"
tv="$here/tv"
source="${1:-$here/output/trt_glass_collection/trt_glass_bumpers/MP4}"
kind="${2:-continuity}"

case "$kind" in
	continuity|commercials|fillers) ;;
	*) echo "second argument must be continuity, commercials or fillers" >&2; exit 1 ;;
esac
[ -d "$source" ] || { echo "no such folder: $source" >&2; exit 1; }

target="$tv/$kind"
mkdir -p "$target"
installed=0
skipped=0

for clip in "$source"/*.mp4 "$source"/*.mov "$source"/*.mkv; do
	[ -e "$clip" ] || continue
	name="$(basename "${clip%.*}")"
	out="$target/$name.mp4"
	# The temporary name keeps the .mp4 extension — ffmpeg picks the muxer
	# from it, and "name.mp4.tmp" is an extension it has never heard of — and
	# starts with a dot, which playout's scanner skips, so a half-written
	# clip is never picked up mid-copy.
	tmp="$target/.$name.publishing.mp4"
	if [ -e "$out" ]; then
		skipped=$((skipped + 1))
		continue
	fi
	rm -f "$tmp"

	if ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
		-of default=nw=1:nk=1 "$clip" | grep -q .; then
		cp "$clip" "$tmp"
	else
		echo "  $name: adding a silent track"
		ffmpeg -hide_banner -loglevel error -y -i "$clip" \
			-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
			-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 96k -shortest \
			-movflags +faststart "$tmp"
	fi

	# The manifest goes down BEFORE the video takes its final name: playout
	# scans this folder every few seconds and a clip without its manifest is
	# a clip it has to guess about.
	cat > "$target/$name.package.json" <<-JSON
	{
	  "kind": "$kind",
	  "presentation": "programme",
	  "repeatable": true,
	  "state": "ready"
	}
	JSON
	mv "$tmp" "$out"
	installed=$((installed + 1))
	echo "  $name → $kind/"
done

echo "$installed clip(s) installed, $skipped already there."
if [ "$installed" -gt 0 ]; then
	echo "The channel picks them up within a few seconds; no restart needed."
fi
