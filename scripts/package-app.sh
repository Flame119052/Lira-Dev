#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release --product Lira
bin_dir="$(swift build -c release --product Lira --show-bin-path)"
app="$root/.build/Lira.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Lira" "$app/Contents/MacOS/Lira"
cp "$root/App/Info.plist" "$app/Contents/Info.plist"
printf 'APPL' > "$app/Contents/PkgInfo"
if command -v codesign >/dev/null; then
  codesign --force -s - "$app" >/dev/null
fi
test -x "$app/Contents/MacOS/Lira"
echo "Built $app"
