#!/bin/sh
# Hear candidate anchor voices and pick one.
#
# These are not clones.  OmniVoice can build a voice from a description —
# female, middle-aged, low pitch — with no reference recording anywhere in
# the chain, so a bad reference cannot be inherited.  The description is not
# free text: the model accepts 48 fixed items and refuses the rest.
#
#   tools/media/voice_audition.sh ["text she should read"]
#
# Writes one wav per voice into ~/Documents/generated/omnivoice/audition and
# opens the folder.  Play them, pick the one that sounds like your anchor,
# then point [news.voices] anchorb_ref_audio at that file and copy
# _script.txt into anchorb_ref_text.
#
# Nothing here scores the voices.  A voice is chosen by ear.
set -e
here="$(cd "$(dirname "$0")/../.." && pwd)"
out="$HOME/Documents/generated/omnivoice/audition"
"$here/tv/.venv/bin/python" "$here/tv/news/scripts/voice_audition.py" "$@"
[ -d "$out" ] && open "$out" 2>/dev/null || true
