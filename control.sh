#!/bin/bash
# Proof that this runner's Gatekeeper is really on: it must REJECT a quarantined app with no notarization.
set -u
sudo spctl --master-enable 2>&1 | tail -1
spctl --status
D="$(mktemp -d)"; A="$D/Control.app/Contents/MacOS"; mkdir -p "$A"; cp /bin/echo "$A/Control"
cat > "$D/Control.app/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Control</string><key>CFBundleIdentifier</key><string>com.publik.control</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
P
codesign --force --deep --sign - "$D/Control.app" 2>&1 | tail -1
xattr -rw com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$D/Control.app"
O="$(spctl -a -t exec -vv "$D/Control.app" 2>&1)"; echo "$O"
mkdir -p results
if echo "$O" | grep -q "rejected"; then echo '{"control":"rejected, as it must be"}' | tee results/control.json; else echo '{"control":"NOT REJECTED: Gatekeeper is off, the results mean nothing"}' | tee results/control.json; exit 1; fi
