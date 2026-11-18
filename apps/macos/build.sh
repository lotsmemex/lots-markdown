#!/bin/sh
# Builds build/Lots Markdown.app (Apple Silicon, release). Usage: ./build.sh
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cargo build --release --manifest-path ../render-stub/Cargo.toml
APP="build/Lots Markdown.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macos14 \
  -import-objc-header ../render-stub/lots_render_stub.h \
  Sources/LotsMarkdown/*.swift \
  -L ../render-stub/target/release -llots_render_stub \
  -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/LotsMarkdown"
codesign --force --sign - "$APP"
echo "built $APP"
