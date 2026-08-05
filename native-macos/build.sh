#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_MANIFEST="$ROOT/src-tauri/Cargo.toml"
RUST_TARGET="$ROOT/src-tauri/target/release"
BUILD_DIR="$ROOT/native-macos/build"
APP="$BUILD_DIR/Todo.app"
MACOS_DIR="$APP/Contents/MacOS"
RESOURCES_DIR="$APP/Contents/Resources"

cargo build --release --manifest-path "$RUST_MANIFEST" -p todo-macos-bridge

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

clang \
  -fobjc-arc \
  -fblocks \
  -O2 \
  -framework AppKit \
  -framework Foundation \
  -Wl,-dead_strip \
  "$ROOT/native-macos/ObjC/TodoApp.m" \
  "$RUST_TARGET/libtodo_macos_bridge.a" \
  -o "$MACOS_DIR/Todo"

strip -x "$MACOS_DIR/Todo"
cp "$ROOT/native-macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/src-tauri/icons/icon.icns" "$RESOURCES_DIR/icon.icns"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
