#!/bin/bash
# THE IPAD: the whole world, bundled, onto an iPad.
#
# Same deal as the Quest APK — nothing streams, nothing is downloaded, the
# city and every pack ride along inside the app. The difference is Apple:
# Godot cannot hand you a finished app the way it hands you an .apk, because
# an iOS app has to be signed by a person. So this goes as far as a machine
# can go on its own — it exports the Xcode project, and builds and installs it
# if you have told it who you are — and stops with instructions when it needs
# your Apple ID.
#
#   tools/deploy/ipad.sh                     export, then open Xcode (first time: do this)
#   tools/deploy/ipad.sh --team ABCDE12345   export, build and install onto a plugged-in iPad
#   tools/deploy/ipad.sh --project-only      just the Xcode project, touch nothing else
#   tools/deploy/ipad.sh --debug             debug template (slower, prints more)
#   tools/deploy/ipad.sh --devices           list the iPads this Mac can see, and quit
#
# The team ID is the ten-character string Apple gives your account. It is in
# Xcode under Settings -> Accounts -> your Apple ID -> the Team column, and
# once you know it you can put it in the environment instead of typing it:
#
#   export GAME_TEAM_ID=ABCDE12345
#
# A free Apple ID works. The app then expires after seven days and you rerun
# this; a paid account ($99/yr) makes it a year. Either way nothing goes near
# the App Store.
#
# Expect ~2 GB in build/ios and about the same again on the iPad.

set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$HERE/client"
OUT="$HERE/build/ios"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PRESET="iPad"
APP_NAME="client"
BUNDLE_ID="${GAME_BUNDLE_ID:-}"

TEAM="${GAME_TEAM_ID:-}"
CONFIG="Release"
EXPORT_MODE="--export-release"
PROJECT_ONLY=0

say() { printf '[ipad] %s\n' "$1" >&2; }
die() { say "$1"; exit 1; }

devices() {  # one "udid<TAB>name" line per connected, real, available iPad
  # The Name column holds spaces and the Hostname column is usually empty, so
  # the identifier is found by shape and the name is whatever preceded it.
  # A usable iPad reports "connected" while the cable is live and "available
  # (paired)" once it has been seen before; both are fine, and "unavailable"
  # must be excluded explicitly because it contains "available".
  xcrun devicectl list devices 2>/dev/null |
    awk 'tolower($0) ~ /ipad/ && $0 ~ /physical/ &&
         ($0 ~ /connected/ || $0 ~ /available/) && $0 !~ /unavailable/ {
      udid = ""
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]+$/) { udid = $i; idx = i; break }
      if (udid == "") next
      name = $1
      for (j = 2; j < idx; j++) name = name " " $j
      print udid "\t" name
    }'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --team) shift; TEAM="${1:-}"; [ -n "$TEAM" ] || die "--team needs a ten-character team ID" ;;
    --team=*) TEAM="${1#--team=}" ;;
    --debug) CONFIG="Debug"; EXPORT_MODE="--export-debug" ;;
    --project-only) PROJECT_ONLY=1 ;;
    --devices) devices; exit 0 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
  shift
done

[ -x "$GODOT" ] || die "no Godot at $GODOT — set GODOT to the binary inside Godot.app"
[ -d "$PROJECT" ] || die "no project at $PROJECT"
grep -q "^name=\"$PRESET\"$" "$PROJECT/export_presets.cfg" 2>/dev/null ||
  die "no \"$PRESET\" preset in client/export_presets.cfg — copy export_presets.ipad.cfg in (see IPAD_EXPORT.md)"

preset_option() {  # preset_option <key>: application/<key> of the $PRESET preset
  awk -v want="name=\"$PRESET\"" -v key="application/$1=" '
    /^\[preset\.[0-9]+\]$/ { inside = 0 }
    $0 == want { inside = 1 }
    inside && index($0, key) == 1 { v = substr($0, length(key) + 1); gsub(/"/, "", v); print v; exit }
  ' "$PROJECT/export_presets.cfg"
}
[ -n "$BUNDLE_ID" ] || BUNDLE_ID="$(preset_option bundle_identifier)"
[ -n "$BUNDLE_ID" ] || die "no bundle identifier in the \"$PRESET\" preset (or set GAME_BUNDLE_ID)"
xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools not selected: run xcode-select --install"

# ── the Xcode project ─────────────────────────────────────────────────
# Godot refuses to write into a directory holding an older export, and this
# one is nothing but export output (build/ is gitignored), so clear it.
if [ -d "$OUT/$APP_NAME.xcodeproj" ]; then
  say "clearing the previous export in build/ios"
  rm -rf "$OUT"
fi
mkdir -p "$OUT" || die "cannot create $OUT"

say "exporting (~2 GB of packed world; expect a few minutes)"
"$GODOT" --headless --path "$PROJECT" "$EXPORT_MODE" "$PRESET" "$OUT/$APP_NAME.ipa" 2>&1 |
  grep -vE '^(READ|ADDING|Creating|savepack|res://)' | tail -20
[ -d "$OUT/$APP_NAME.xcodeproj" ] || die "Godot did not produce an Xcode project; see the output above"
say "Xcode project ready: build/ios/$APP_NAME.xcodeproj"

if [ "$PROJECT_ONLY" = 1 ]; then
  exit 0
fi

# ── signing, which is the part only you can do ────────────────────────
if [ -z "$TEAM" ]; then
  say ""
  say "No team ID, so this is as far as it goes on its own. In the Xcode"
  say "window about to open:"
  say "  1. pick the client target, then Signing & Capabilities"
  say "  2. tick 'Automatically manage signing' and choose your Apple ID team"
  say "     (Xcode -> Settings -> Accounts -> + if it is not listed yet)"
  say "  3. plug the iPad in, pick it in the toolbar, press Run"
  say "  4. on the iPad, Settings -> General -> VPN & Device Management ->"
  say "     trust the developer, then launch it from the home screen"
  say ""
  say "Note the ten-character team ID Xcode shows you. Next time:"
  say "  tools/deploy/ipad.sh --team <that ID>   builds and installs without Xcode."
  open "$OUT/$APP_NAME.xcodeproj"
  exit 0
fi

# ── build ─────────────────────────────────────────────────────────────
DD="$OUT/.build"
# Godot writes CODE_SIGN_IDENTITY = "Apple Distribution" into the Release
# config. Automatic signing refuses to pair that with a development profile
# ("conflicting provisioning settings"), so it is overridden here as well as
# in the preset — a project exported by hand still builds.
say "building $CONFIG for arm64 as team $TEAM"
xcodebuild -project "$OUT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration "$CONFIG" -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build 2>&1 | tail -25

APP="$DD/Build/Products/$CONFIG-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || die "the build did not produce $APP_NAME.app; see the output above"
say "built: $(du -sh "$APP" | cut -f1)"

# ── install ───────────────────────────────────────────────────────────
FOUND="$(devices)"
if [ -z "$FOUND" ]; then
  say "no iPad connected. Plug one in (unlocked, 'Trust This Computer' accepted)"
  say "and rerun, or drag $APP_NAME.app onto the device in Xcode's Devices window."
  exit 0
fi
UDID="$(printf '%s\n' "$FOUND" | head -1 | cut -f1)"
NAME="$(printf '%s\n' "$FOUND" | head -1 | cut -f2)"
say "installing onto $NAME (a couple of GB over the cable; give it a minute)"
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -10 ||
  die "install failed — on a first install, trust the developer on the iPad first: Settings -> General -> VPN & Device Management"
say "installed. Launch it from the iPad's home screen."
say "Touch controls are on-screen; a keyboard still works (WASD)."
