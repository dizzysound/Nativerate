#!/bin/bash
# Build "Nativerate Dev" for another Mac into <dest> (default ~/Desktop/Nativerate Dev):
# the app plus "Set Up (run once).command", which puts MediaRemoteAdapter's resource bundle where the
# binary looks for it (/Users/Shared/Nativerate-dev-build/..., see make_dev_app.sh) and clears
# the quarantine flag (the app is ad-hoc signed). arm64 only.
set -e
cd "$(dirname "$0")"
DEST=${1:-"$HOME/Desktop/Nativerate Dev"}
BP=/Users/Shared/Nativerate-dev-build
CONFIG=release BUILD_PATH=$BP ./make_dev_app.sh >/dev/null
cat ".build/Nativerate Dev.app/Contents/MacOS/"* | strings | grep -q "$BP/arm64-apple-macosx/release/MediaRemoteAdapter_MediaRemoteAdapter.bundle" \
  || { echo "the binary doesn't point at $BP"; exit 1; }
rm -rf "$DEST"; mkdir -p "$DEST"
ditto ".build/Nativerate Dev.app" "$DEST/Nativerate Dev.app"
cat > "$DEST/Set Up (run once).command" <<SH
#!/bin/bash
# Run once on the Mac that will use Nativerate Dev (double-click; Terminal opens).
cd "\$(dirname "\$0")"
APP="\$PWD/Nativerate Dev.app"
xattr -dr com.apple.quarantine "\$APP" 2>/dev/null
mkdir -p "$BP/arm64-apple-macosx/release"
rm -rf "$BP/arm64-apple-macosx/release/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
cp -R "\$APP/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$BP/arm64-apple-macosx/release/"
echo "Set up. Open Nativerate Dev, then in its menu: Settings > Advanced > Exclusive Mode driver > Install..., and"
echo "Exclusive Mode. Quit the regular Nativerate first if it is running."
SH
chmod +x "$DEST/Set Up (run once).command"
cat > "$DEST/README.txt" <<TXT
Nativerate Dev (branch main of dizzysound/Nativerate, $(git -C ../.. rev-parse --short HEAD), built $(date '+%Y-%m-%d %H:%M')).
Apple Silicon only. Ad-hoc signed: each copy asks again for Microphone and Automation (Music).

1. Copy this folder anywhere on the test Mac (the app must stay next to nothing in particular).
2. Double-click "Set Up (run once).command" (right-click > Open if macOS refuses).
3. Quit the regular Nativerate if it runs, then open "Nativerate Dev.app".
4. Its menu-bar item (a speaker icon; on a notched MacBook it can hide under the notch):
   Settings > Advanced > Exclusive Mode driver > Install... (administrator password; audio restarts for a moment),
   then Exclusive Mode to turn the engine on. Allow Microphone and Automation.
Engine log: ~/Library/Logs/Nativerate-ExclusiveMode.log
Remove: menu Settings > Advanced > Exclusive Mode driver > Remove..., then delete the app and /Users/Shared/Nativerate-dev-build.
TXT
echo "$DEST"
