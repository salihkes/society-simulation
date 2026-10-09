#!/usr/bin/env python3
"""Cut event line clips from a source video by a clips.json spec.

Usage:
  python3 tools/media/cut_event_clips.py <event_id> <source video>

Reads client/assets/entities/ambient/events/<event_id>/clips.json
({"clips": {name: {"t": [start, end], ...}}}) and writes one loudness-
normalized mono mp3 per clip into
client/assets/art/sound/events/<event_id>/. Existing clips are
overwritten (the spec is the truth; re-run after editing timestamps).
"""
import json
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "client")

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    event_id, src = sys.argv[1], sys.argv[2]
    spec_path = os.path.join(ROOT, "assets/entities/ambient/events", event_id, "clips.json")
    out_dir = os.path.join(ROOT, "assets/art/sound/events", event_id)
    os.makedirs(out_dir, exist_ok=True)
    spec = json.load(open(spec_path))
    clips = spec["clips"]
    pad_in, pad_out = 0.12, 0.20
    for name, c in clips.items():
        t0 = max(float(c["t"][0]) - pad_in, 0.0)
        t1 = float(c["t"][1]) + pad_out
        dur = t1 - t0
        out = os.path.join(out_dir, name + ".mp3")
        fade_out_start = max(dur - 0.12, 0.0)
        cmd = ["ffmpeg", "-y", "-v", "error", "-ss", f"{t0:.2f}", "-t", f"{dur:.2f}",
               "-i", src, "-vn", "-ac", "1", "-ar", "44100",
               "-af", f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.06,afade=t=out:st={fade_out_start:.2f}:d=0.12",
               "-c:a", "libmp3lame", "-q:a", "4", out]
        subprocess.run(cmd, check=True)
        print(f"{name}.mp3  [{t0:.1f}..{t1:.1f}]")
    print(f"done: {len(clips)} clips -> {out_dir}")

if __name__ == "__main__":
    main()
