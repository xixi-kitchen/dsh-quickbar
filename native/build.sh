#!/bin/bash
#
# Build the dsh-quickbar native global-hotkey helper as a UNIVERSAL
# (arm64 + x86_64) Mach-O binary, so one published npm package runs on both
# Apple Silicon and Intel Macs.
#
# Idempotent: safe to run any number of times, from any working directory.
# Prints the absolute path of the built binary on success, exits non-zero on
# any failure. The source is plain C/Objective-C; the Swift toolchain on this
# machine is broken, so this intentionally uses /usr/bin/clang.
#
# Environment:
#   CLANG       compiler to use (default /usr/bin/clang)
#   MIN_MACOS   minimum macOS deployment target for both slices (default 11.0)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$SCRIPT_DIR/quickbar-hotkey.m"
OUT="$SCRIPT_DIR/quickbar-hotkey"
MIN_MACOS="${MIN_MACOS:-11.0}"

if [ ! -f "$SRC" ]; then
    echo "build.sh: error: source file not found: $SRC" >&2
    exit 1
fi

CLANG="${CLANG:-/usr/bin/clang}"
if [ ! -x "$CLANG" ]; then
    CLANG="$(command -v clang || true)"
fi
if [ -z "${CLANG:-}" ] || [ ! -x "$CLANG" ]; then
    echo "build.sh: error: no usable clang found (tried \$CLANG and PATH)" >&2
    exit 1
fi

LIPO="${LIPO:-/usr/bin/lipo}"
if [ ! -x "$LIPO" ]; then
    LIPO="$(command -v lipo || true)"
fi
if [ -z "${LIPO:-}" ] || [ ! -x "$LIPO" ]; then
    echo "build.sh: error: no usable lipo found (tried \$LIPO and PATH)" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-quickbar-build.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# -framework Carbon: RegisterEventHotKey / InstallEventHandler / RunApplicationEventLoop
# -framework AppKit:  the floating input panel (NSPanel/NSTextField/NSPopUpButton)
build_slice() { # <arch> <output>
    local arch="$1"
    local out="$2"
    "$CLANG" -O2 -arch "$arch" -mmacosx-version-min="$MIN_MACOS" \
        -o "$out" "$SRC" -framework Carbon -framework AppKit
}

build_slice arm64 "$TMP_DIR/quickbar-hotkey.arm64"
build_slice x86_64 "$TMP_DIR/quickbar-hotkey.x86_64"

"$LIPO" -create -output "$OUT" \
    "$TMP_DIR/quickbar-hotkey.arm64" \
    "$TMP_DIR/quickbar-hotkey.x86_64"
chmod 755 "$OUT"

if [ ! -x "$OUT" ]; then
    echo "build.sh: error: expected binary was not produced: $OUT" >&2
    exit 1
fi

ARCHES="$("$LIPO" -archs "$OUT")"
case "$ARCHES" in
    *arm64*) : ;;
    *) echo "build.sh: error: built binary lacks arm64 (archs: $ARCHES)" >&2; exit 1 ;;
esac
case "$ARCHES" in
    *x86_64*) : ;;
    *) echo "build.sh: error: built binary lacks x86_64 (archs: $ARCHES)" >&2; exit 1 ;;
esac

printf '%s\n' "$OUT"
