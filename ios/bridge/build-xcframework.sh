#!/usr/bin/env bash
set -euo pipefail

bridge_dir=$(cd "$(dirname "$0")" && pwd)
out_dir="$bridge_dir/build"
mkdir -p "$out_dir"

targets=(aarch64-apple-ios)
if [ "${INCLUDE_SIMULATOR:-0}" = "1" ]; then
    targets+=(aarch64-apple-ios-sim)
fi

xc_args=()
for target in "${targets[@]}"; do
    echo "Building ac_bridge for $target..."
    cargo build --manifest-path "$bridge_dir/Cargo.toml" --release --target "$target"
    xc_args+=(-library "$bridge_dir/target/$target/release/libac_bridge.a" -headers "$bridge_dir/include")
done

rm -rf "$out_dir/ACBridge.xcframework"
xcodebuild -create-xcframework "${xc_args[@]}" -output "$out_dir/ACBridge.xcframework"
echo "Built $out_dir/ACBridge.xcframework"
