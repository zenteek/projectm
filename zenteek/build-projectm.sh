#!/bin/bash
# build-projectm.sh
# Build projectM 4.x as a universal static library (arm64 + x86_64)
# and install into Vendor/projectM/.
#
# Pattern analogous to setup-ffmpeg.sh: two thin per-arch builds merged
# via `lipo -create` into fat .a archives.
#
# Output:
#   Vendor/projectM/lib/libprojectM-4.a            (universal)
#   Vendor/projectM/lib/libprojectM-4-playlist.a   (universal)
#   Vendor/projectM/include/projectM-4/*.h
#   Vendor/projectM/LICENSE
#   Vendor/projectM/VERSION
#
# Override pin:  PROJECTM_REF=<tag|sha> ./scripts/build-projectm.sh
# Override target: DEPLOYMENT_TARGET=14.0 ./scripts/build-projectm.sh

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
PROJECTM_REF="${PROJECTM_REF:-v4.1.6}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
ARCHS=(arm64 x86_64)
LIBS=(libprojectM-4.a libprojectM-4-playlist.a)

# Resolve repo root (parent of this script's directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BUILD_ROOT="$REPO_ROOT/build/projectm"
SRC_DIR="$BUILD_ROOT/src"
VENDOR_DIR="$REPO_ROOT/Vendor/projectM"

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
echo "=== Prerequisites ==="

if ! command -v cmake >/dev/null; then
    echo "Error: cmake not installed. Run: brew install cmake" >&2
    exit 1
fi
CMAKE_VERSION=$(cmake --version | head -1 | awk '{print $3}')
echo "  cmake:  $CMAKE_VERSION"

if ! command -v xcode-select >/dev/null || ! xcode-select -p >/dev/null 2>&1; then
    echo "Error: Xcode Command Line Tools missing. Run: xcode-select --install" >&2
    exit 1
fi
echo "  xcode:  $(xcode-select -p)"

GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null; then
    GENERATOR="Ninja"
    echo "  ninja:  $(ninja --version)"
else
    echo "  ninja:  not found (falling back to Unix Makefiles - slower)"
fi

if ! command -v lipo >/dev/null; then
    echo "Error: lipo not found (ships with Xcode CLT)." >&2
    exit 1
fi

echo "  target: macOS $DEPLOYMENT_TARGET, archs=${ARCHS[*]}"
echo "  ref:    $PROJECTM_REF"
echo ""

# ── 2. Source ────────────────────────────────────────────────────────────────
echo "=== Source ==="

mkdir -p "$BUILD_ROOT"

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "  cloning projectM @ $PROJECTM_REF"
    git clone --depth 1 --branch "$PROJECTM_REF" \
        https://github.com/projectM-visualizer/projectm.git "$SRC_DIR"
else
    echo "  source exists - fetching + checking out $PROJECTM_REF"
    git -C "$SRC_DIR" fetch --tags --depth 1 origin "$PROJECTM_REF" 2>/dev/null || \
        git -C "$SRC_DIR" fetch --tags
    git -C "$SRC_DIR" checkout --quiet "$PROJECTM_REF"
fi

echo "  initialising submodules"
git -C "$SRC_DIR" submodule update --init --recursive --depth 1

COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD)
echo "  HEAD:   $COMMIT"

# Local patch: disable projectM's hard-coded FFT "equalize" curve.
# The default `equalize=true` multiplies bin 0 by 0 and the lowest few bins
# by ~1e-4, which removes kick-drum fundamentals (40-100 Hz) from the bass-band
# loudness sum. Beat detection ends up dominated by low-mid synth/vocal energy
# instead of actual beats. Flipping to `false` gives all bins equal weight; the
# band-relative loudness (m_current / m_longAverage) handles 1/f distribution
# on its own. Re-applied after every checkout so future syncs don't lose it.
PCM_HPP="$SRC_DIR/src/libprojectM/Audio/PCM.hpp"
if [ -f "$PCM_HPP" ]; then
    sed -i '' \
        's|MilkdropFFT m_fft{WaveformSamples, SpectrumSamples, true}|MilkdropFFT m_fft{WaveformSamples, SpectrumSamples, false}|' \
        "$PCM_HPP"
    if grep -q 'SpectrumSamples, false' "$PCM_HPP"; then
        echo "  patch:  FFT equalize disabled (PCM.hpp)"
    else
        echo "Error: failed to apply PCM.hpp equalize patch" >&2
        exit 1
    fi
fi
echo ""

# ── 3. Thin per-arch builds ──────────────────────────────────────────────────
for ARCH in "${ARCHS[@]}"; do
    echo "=== Build: $ARCH ==="

    BUILD_DIR="$BUILD_ROOT/build-$ARCH"
    INSTALL_DIR="$BUILD_ROOT/install-$ARCH"

    rm -rf "$BUILD_DIR" "$INSTALL_DIR"

    cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
        -G "$GENERATOR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_DOCS=OFF \
        -DENABLE_SDL_UI=OFF \
        -DENABLE_PLAYLIST=ON \
        -DENABLE_SYSTEM_GLM=OFF \
        -DENABLE_SYSTEM_PROJECTM_EVAL=OFF \
        -DENABLE_BOOST_FILESYSTEM=OFF \
        -DENABLE_CXX_INTERFACE=OFF \
        -DENABLE_DEBUG_POSTFIX=OFF \
        -DENABLE_VERBOSE_LOGGING=OFF

    cmake --build "$BUILD_DIR" --config Release --parallel
    cmake --install "$BUILD_DIR" --config Release

    echo ""
done

# ── 4. lipo: thin → fat ──────────────────────────────────────────────────────
echo "=== lipo (universal binaries) ==="

rm -rf "$VENDOR_DIR/lib"
mkdir -p "$VENDOR_DIR/lib"

for LIB in "${LIBS[@]}"; do
    THIN_ARGS=()
    for ARCH in "${ARCHS[@]}"; do
        THIN="$BUILD_ROOT/install-$ARCH/lib/$LIB"
        if [ ! -f "$THIN" ]; then
            echo "Error: expected thin lib missing: $THIN" >&2
            exit 1
        fi
        THIN_ARGS+=("$THIN")
    done

    OUT="$VENDOR_DIR/lib/$LIB"
    lipo -create "${THIN_ARGS[@]}" -output "$OUT"
    SIZE=$(ls -lh "$OUT" | awk '{print $5}')
    ARCHS_INFO=$(lipo -info "$OUT" | sed 's/^.*are: //')
    echo "  $LIB  ($SIZE, $ARCHS_INFO)"
done
echo ""

# ── 5. Headers (arch-independent) ────────────────────────────────────────────
echo "=== Headers ==="

rm -rf "$VENDOR_DIR/include"
mkdir -p "$VENDOR_DIR/include"

HEADER_SRC="$BUILD_ROOT/install-${ARCHS[0]}/include/projectM-4"
if [ ! -d "$HEADER_SRC" ]; then
    echo "Error: expected header dir missing: $HEADER_SRC" >&2
    echo "       (install step did not produce projectM-4 headers)" >&2
    exit 1
fi

cp -R "$HEADER_SRC" "$VENDOR_DIR/include/"
HEADER_COUNT=$(find "$VENDOR_DIR/include/projectM-4" -maxdepth 2 -name '*.h' | wc -l | tr -d ' ')
echo "  copied $HEADER_COUNT header(s) → Vendor/projectM/include/projectM-4/"
echo ""

# ── 6. LICENSE + VERSION stamp ───────────────────────────────────────────────
echo "=== Metadata ==="

LICENSE_SRC=""
for cand in LICENSE LICENSE.txt COPYING COPYING.txt; do
    if [ -f "$SRC_DIR/$cand" ]; then
        LICENSE_SRC="$SRC_DIR/$cand"
        break
    fi
done
if [ -n "$LICENSE_SRC" ]; then
    cp "$LICENSE_SRC" "$VENDOR_DIR/LICENSE"
    echo "  LICENSE copied (from $(basename "$LICENSE_SRC"))"
else
    echo "  LICENSE: source file not found, skipped" >&2
fi

{
    echo "projectM $PROJECTM_REF"
    echo "commit $COMMIT"
    echo "built  $(date -u +%FT%TZ)"
    echo "archs  ${ARCHS[*]}"
    echo "macos  $DEPLOYMENT_TARGET"
} > "$VENDOR_DIR/VERSION"
echo "  VERSION written"
echo ""

# ── 7. Summary ───────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "  Vendor/projectM/:"
echo "    lib/"
for LIB in "${LIBS[@]}"; do
    SIZE=$(ls -lh "$VENDOR_DIR/lib/$LIB" | awk '{print $5}')
    echo "      $LIB  ($SIZE)"
done
echo "    include/projectM-4/  ($HEADER_COUNT headers)"
echo "    LICENSE, VERSION"
echo ""
echo "  Verify:  lipo -info Vendor/projectM/lib/libprojectM-4.a"
echo "  Build sources kept at $BUILD_ROOT (gitignored)"
