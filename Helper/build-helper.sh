#!/bin/zsh
# Builds the LEModHelper command-line tool and its native libraries, and copies them into
# MEMT/Helper so Xcode bundles them into the app's Resources.
#
# Requirements (user-local installs, no admin needed):
#   .NET 10 SDK  ~/.dotnet   (curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0)
#   Rust         ~/.cargo    (curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path)
#
# Upstream sources live in Helper/external (ME3TweaksCore with LegendaryExplorerCore, oozextract).
# The small macOS fixes applied to them are kept in Helper/patches.
set -euo pipefail

HELPER_DIR="${0:A:h}"
OUTPUT_DIR="$HELPER_DIR/../MEMT/Helper"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"

echo "==> Native libraries (Oodle decompression, LZMA/zlib)"
(cd "$HELPER_DIR/oodle-rs" && "$CARGO" build --release)
(cd "$HELPER_DIR/compression-rs" && "$CARGO" build --release)

echo "==> ME3TweaksCore localization dictionaries"
# ME3TweaksCore normally generates these with a Windows PowerShell pre-build step (disabled on macOS
# by Helper/Directory.Build.targets). LEC's LZMA reader needs the uncompressed size in the header.
python3 - "$HELPER_DIR/external/ME3TweaksCore/ME3TweaksCore/Localization/Dictionaries" <<'EOF'
import glob, lzma, struct, sys
for path in glob.glob(sys.argv[1] + "/*.xaml"):
    data = open(path, "rb").read()
    packed = bytearray(lzma.compress(data, format=lzma.FORMAT_ALONE, filters=[{"id": lzma.FILTER_LZMA1, "dict_size": 1 << 23}]))
    packed[5:13] = struct.pack("<Q", len(data))
    open(path + ".lzma", "wb").write(packed)
EOF

echo "==> LEModHelper"
rm -rf "$HELPER_DIR/LEModHelper/publish"
"$DOTNET" publish "$HELPER_DIR/LEModHelper/LEModHelper.csproj" -c Release \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:DebugType=none -o "$HELPER_DIR/LEModHelper/publish"

mkdir -p "$OUTPUT_DIR"
# The native libraries are inside the single-file executable (IncludeNativeLibrariesForSelfExtract),
# so this one file is all the app needs.
cp "$HELPER_DIR/LEModHelper/publish/LEModHelper" "$OUTPUT_DIR/"
echo "==> Copied helper to $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
