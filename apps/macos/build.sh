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
