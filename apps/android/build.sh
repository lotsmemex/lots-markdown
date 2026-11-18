#!/bin/sh
# Builds app/build/outputs/apk/debug/app-debug.apk. Needs the Android SDK with NDK 30.
# Usage: ANDROID_HOME=/path/to/sdk ./build.sh
set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
NDK="$(ls -d "$SDK"/ndk/* | tail -1)"
BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
for pair in "aarch64-linux-android:arm64-v8a" "x86_64-linux-android:x86_64"; do
  T="${pair%%:*}"; ABI="${pair##*:}"
  CC_VAR=$(echo "CARGO_TARGET_${T}_LINKER" | tr 'a-z-' 'A-Z_')
  env "$CC_VAR=$BIN/${T}26-clang" cargo build --release --features jni --target "$T" \
    --manifest-path ../render-stub/Cargo.toml
  mkdir -p "app/src/main/jniLibs/$ABI"
  cp "../render-stub/target/$T/release/liblots_render_stub.so" "app/src/main/jniLibs/$ABI/"
done
echo "sdk.dir=$SDK" > local.properties
gradle --quiet assembleDebug
echo "built app/build/outputs/apk/debug/app-debug.apk"
