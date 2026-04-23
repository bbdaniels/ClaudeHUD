#!/usr/bin/env bash
# Rebuild vendored Ghostty binaries for ClaudeHUD.
#
# Produces everything under ClaudeHUD/Vendor/Ghostty/ — the xcframework plus
# the static libs the linker needs. Vendored Swift sources under
# ClaudeHUD/Vendor/GhosttySurface/ are checked into git; this script only
# deals with the binaries.
#
# Requirements:
#   - Xcode 26+ with Metal Toolchain (first run: xcodebuild -downloadComponent MetalToolchain)
#   - Zig 0.15.2 exactly (brew install zig@0.15 OR ziglang.org download)
#   - Ghostty v1.3.1 source (cloned into /tmp/ghostty-build if missing)

set -euo pipefail

PIN_TAG="v1.3.1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/ghostty-build"
VENDOR_DIR="$REPO_ROOT/ClaudeHUD/Vendor/Ghostty"

# Locate Zig 0.15.2
ZIG=""
for candidate in \
    "/usr/local/opt/zig@0.15/bin/zig" \
    "/opt/homebrew/opt/zig@0.15/bin/zig" \
    "$(command -v zig 2>/dev/null || true)"; do
    if [ -x "$candidate" ]; then
        version=$("$candidate" version 2>/dev/null || echo "")
        if [ "$version" = "0.15.2" ]; then
            ZIG="$candidate"
            break
        fi
    fi
done
if [ -z "$ZIG" ]; then
    echo "error: Zig 0.15.2 not found on PATH"
    echo "install:  brew install zig@0.15"
    echo "      or: download from https://ziglang.org/download/0.15.2/"
    exit 1
fi
echo "using zig: $ZIG ($($ZIG version))"

# Clone Ghostty at pinned tag if needed
if [ ! -d "$BUILD_DIR/.git" ]; then
    echo "cloning ghostty @ $PIN_TAG to $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$PIN_TAG" https://github.com/ghostty-org/ghostty.git "$BUILD_DIR"
else
    echo "reusing existing clone at $BUILD_DIR"
fi

# Build
cd "$BUILD_DIR"
echo "building ghostty.xcframework (this takes a few minutes)..."
"$ZIG" build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false

# Find architecture-native static libs from the zig cache
find_lib() {
    local pattern="$1"
    for candidate in "$BUILD_DIR/.zig-cache/o/"*/"$pattern"; do
        if [ -f "$candidate" ]; then
            local arch
            arch=$(lipo -info "$candidate" 2>&1 | awk -F'is architecture: ' '{print $2}' | tr -d ' ')
            if [ "$arch" = "arm64" ] || [ "$arch" = "$(uname -m)" ]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

# Stage output
mkdir -p "$VENDOR_DIR"
rm -rf "$VENDOR_DIR/GhosttyKit.xcframework" "$VENDOR_DIR"/*.a
cp -R "$BUILD_DIR/macos/GhosttyKit.xcframework" "$VENDOR_DIR/"

for lib in libghostty libdcimgui libfreetype liboniguruma libintl libz libsimdutf libpng libhighway libspirv_cross libglslang libsentry libbreakpad; do
    found=$(find_lib "${lib}.a" || true)
    if [ -z "$found" ]; then
        echo "warning: could not find ${lib}.a for native arch"
    else
        cp "$found" "$VENDOR_DIR/${lib}.a"
        echo "  -> ${lib}.a ($(du -h "$VENDOR_DIR/${lib}.a" | cut -f1))"
    fi
done

echo "done. regenerate Xcode project: xcodegen generate"
