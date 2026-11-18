#!/bin/sh
# Builds build/LotsMarkdown.app for the iOS Simulator (Apple Silicon). Usage: ./build-sim.sh
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cargo build --release --target aarch64-apple-ios-sim --manifest-path ../render-stub/Cargo.toml
APP=build/LotsMarkdown.app
rm -rf "$APP" && mkdir -p "$APP"
cp Info.plist "$APP/Info.plist"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator -parse-as-library \
  -import-objc-header ../render-stub/lots_render_stub.h \
  Sources/LotsMarkdown/*.swift \
  -L ../render-stub/target/aarch64-apple-ios-sim/release -llots_render_stub \
  -framework UIKit -framework WebKit -framework UniformTypeIdentifiers \
  -o "$APP/LotsMarkdown"
codesign --force --sign - "$APP"
echo "built $APP"
