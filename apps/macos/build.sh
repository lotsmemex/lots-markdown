#!/bin/sh
# Builds build/Lots Markdown.app (Apple Silicon, release) on core/'s UniFFI binding.
# Usage: ./build.sh
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CORE=../../core
cargo build --release --locked --features bindings --manifest-path "$CORE/Cargo.toml"
BINDINGS=build/bindings
rm -rf "$BINDINGS" && mkdir -p "$BINDINGS"
(cd "$CORE" && cargo run -q --release --locked --features bindings --bin uniffi-bindgen -- generate \
  target/release/liblots_markdown_core.dylib --language swift --out-dir "$OLDPWD/$BINDINGS")
APP="build/Lots Markdown.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
  sips -z $px $px AppIcon/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) AppIcon/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Document icons shown in Finder for the file types in Info.plist.
xcrun swiftc -O AppIcon/make-doc-icon.swift -o build/make-doc-icon
for kind in MD TXT SRT; do
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  # Each size is drawn on its own: small sizes drop the label and enlarge the mark.
  for px in 16 32 128 256 512; do
    build/make-doc-icon "$kind" $px "$ICONSET/icon_${px}x${px}.png"
    build/make-doc-icon "$kind" $((px * 2)) "$ICONSET/icon_${px}x${px}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Doc$kind.icns"
done
mkdir -p "$APP/Contents/Resources/Themes" && cp ../../themes/*.css "$APP/Contents/Resources/Themes/"
# The generated LotsMarkdownCore.swift compiles into the app module, so the app calls
# renderHtml(markdown:) without an import.
xcrun swiftc -O -target arm64-apple-macos14 \
  -Xcc -fmodule-map-file="$BINDINGS/LotsMarkdownCoreFFI.modulemap" -I "$BINDINGS" \
  "$BINDINGS/LotsMarkdownCore.swift" Sources/LotsMarkdown/*.swift \
  "$CORE/target/release/liblots_markdown_core.a" \
  -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/LotsMarkdown"
codesign --force --sign - "$APP"
echo "built $APP"
