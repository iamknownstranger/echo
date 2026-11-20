#!/bin/bash
# Build a Finder-launchable Apple silicon application with the installed Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")"

# Keep the release build plan separate from SwiftPM's native test plan.
build_args=(-c release --triple arm64-apple-macosx14.0 --scratch-path .build/package)
swift build "${build_args[@]}"
bin="$(swift build "${build_args[@]}" --show-bin-path)/EchoMusic"
mkdir -p build
stage="$(mktemp -d "$PWD/build/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Echo Music.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources" "$stage/Echo.iconset"
install -m755 "$bin" "$app/Contents/MacOS/EchoMusic"
cp Info.plist "$app/Contents/"
cp ../LICENSE "$resources/"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" ../assets/Echo-new.png --out "$stage/Echo.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" ../assets/Echo-new.png --out "$stage/Echo.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Echo.iconset" -o "$resources/Echo.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
lipo -verify_arch arm64 "$app/Contents/MacOS/EchoMusic"
ditto -c -k --keepParent "$app" "$stage/Echo-Music-arm64.zip"
if [[ -e "build/Echo Music.app" ]]; then
    mv "build/Echo Music.app" "$stage/previous.app"
fi
mv "$app" build/
mv -f "$stage/Echo-Music-arm64.zip" build/
echo "$PWD/build/Echo Music.app"
