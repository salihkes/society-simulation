# addons/ffmpeg — EIRTeam.FFmpeg for Godot, with local patches

Plays anything FFmpeg can read (mp4, mkv, webm, ts...) through the ordinary
VideoStreamPlayer as an `FFmpegVideoStream`, with audio. Upstream:
https://github.com/EIRTeam/EIRTeam.FFmpeg (MIT), built from commit
0b21297 on 2026-09-07.

`win64/` and `linux64/` are upstream's prebuilt 1.1.4 binaries, unpatched.
`macos/` is our own build (arm64 only), with `streaming.patch` applied:

1. **URL sources.** Upstream reads everything through Godot's FileAccess, so
   only local files play. A `file` that carries a scheme other than res://
   or user:// (http, https, an HLS .m3u8, rtsp, udp) is now handed straight
   to FFmpeg's own protocols. Tested with a local HLS playlist.
2. **Godot 4.7.** The YUV-to-RGB compute shader declared a 4-byte push
   constant while the code sends 16; 4.7 rejects the mismatch and the
   picture stays black. The shader block is padded to 16 bytes.
3. **Stream timing.** On a network source, frame time runs from the first
   decoded frame (HLS and MPEG-TS timestamps start anywhere, and the
   stream's start_time may be unset), the demuxer is never seeked, and when
   the player finds itself out of sync it moves its clock to the frame
   instead of seeking. Without this, an HLS playlist decoded its second
   segment first, the player seeked, and the picture never appeared. A
   live stream reports a duration of zero.

Verified on this Mac: an mkv from disk, an mp4 over http, and an HLS
playlist (both with original and zero-based timestamps), each on two sets
at once.

## Rebuilding on macOS

    brew install scons ffmpeg@6            # FFmpeg 6 is the API this code targets
    git clone --recursive https://github.com/EIRTeam/EIRTeam.FFmpeg.git
    cd EIRTeam.FFmpeg && git apply /path/to/streaming.patch
    cd gdextension_build
    scons platform=macos arch=arm64 target=template_release ffmpeg_path=/opt/homebrew/opt/ffmpeg@6 -j24
    scons platform=macos arch=arm64 target=template_debug   ffmpeg_path=/opt/homebrew/opt/ffmpeg@6 -j24
    cp -R build/addons/ffmpeg/macos <project>/addons/ffmpeg/macos

Each target takes under a minute on an M2 Ultra. Upstream's own
`make gdextension PLATFORM=macos` builds FFmpeg from source through
ffmpeg-kit instead (universal binary, LGPL-clean); it takes far longer and
was not needed for development.

## Caveats

- The macOS libraries link against `/opt/homebrew/opt/ffmpeg@6` by absolute
  path: this build runs on a machine with that Homebrew keg. For a shipped
  build, either rewrite the install names with `install_name_tool` and copy
  the dependency tree, or use upstream's ffmpeg-kit route.
- Homebrew's FFmpeg is built with GPL components (x264, x265). Shipping the
  game with these dylibs puts the binary under the GPL. Upstream's
  FFmpeg-Builds tarballs and the ffmpeg-kit route are LGPL-only.
- H.264 and HEVC are patent-encumbered in some jurisdictions; upstream's
  README says the same.
- No hardware decoding; a 720p H.264 stream costs one CPU core per set.
- The Windows and Linux binaries here are upstream's and lack both patches:
  rebuild them from the patched source before relying on URLs or 4.7 there.
