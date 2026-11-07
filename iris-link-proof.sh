#!/bin/bash
# iris-link-proof.sh <dmg url>: the PRODUCTION proof that a signed-in Iris links this Mac to the publik account.
# The repo secret IRIS_REFRESH_TOKEN is a Supabase refresh token of one test session. It goes where Iris's own
# sign-in saves it (Keychain com.publikhq.iris / supabase-refresh-token). Iris then restores the session at launch
# and, with no publik API key on this Mac, mints an account-link install bound to the account.
#   run 1 (100 s): restore + link; usage counts every 40 s (test interval)
#   run 2 (35 s):  a new launch; app_opened carries the link key
#   run 3 (35 s):  the session is gone (refresh token deleted); Iris deletes the link key and revokes its install
# The app's output is never printed in full: only `publik-telemetry:` and `publik account link:` lines are kept.
# The orchestrator reads the production rows and cleans them up; this script never prints a secret.
set -u
URL="${1:?dmg url}"; ROOT="$PWD"; R="$ROOT/results"; W="$ROOT/work"; mkdir -p "$R" "$W"
[ -n "${IRIS_REFRESH_TOKEN:-}" ] || { echo "no IRIS_REFRESH_TOKEN"; exit 1; }
echo "::add-mask::$IRIS_REFRESH_TOKEN"
security create-keychain -p test rs.keychain; security unlock-keychain -p test rs.keychain; security set-keychain-settings rs.keychain
security list-keychains -d user -s rs.keychain; security default-keychain -d user -s rs.keychain
security add-generic-password -U -s com.publikhq.iris -a supabase-refresh-token -w "$IRIS_REFRESH_TOKEN" -A
security set-generic-password-partition-list -S "apple-tool:,apple:,teamid:R5R3ZS54LV" -k test -s com.publikhq.iris -a supabase-refresh-token rs.keychain >/dev/null 2>&1
unset IRIS_REFRESH_TOKEN

item() { security find-generic-password -s com.publikhq.iris -a "$1" rs.keychain >/dev/null 2>&1 && echo present || echo absent; }
curl -fsSL -o "$W/Iris.dmg" "$URL" || { echo "download failed"; exit 1; }
{ echo "dmg sha256 $(shasum -a 256 "$W/Iris.dmg" | cut -d' ' -f1)"
  echo "stapler: $(xcrun stapler validate "$W/Iris.dmg" 2>&1 | tail -1)"
  echo "spctl dmg: $(spctl -a -t open --context context:primary-signature -vv "$W/Iris.dmg" 2>&1 | head -2 | tr '\n' ' ')"; } | tee "$R/install.txt"
hdiutil attach "$W/Iris.dmg" -nobrowse -readonly -noautoopen -mountpoint "$W/mnt" -quiet
ditto "$W/mnt/Iris.app" /Applications/Iris.app; hdiutil detach "$W/mnt" -quiet
{ echo "spctl app: $(spctl -a -t exec -vv /Applications/Iris.app 2>&1 | head -2 | tr '\n' ' ')"
  echo "version: $(defaults read /Applications/Iris.app/Contents/Info CFBundleShortVersionString)"; } | tee -a "$R/install.txt"

run_iris() { # run_iris <name> <seconds>
  PUBLIK_TELEMETRY_DEBUG=1 PUBLIK_TELEMETRY_INTERVAL_SECONDS=40 script -q /dev/null /Applications/Iris.app/Contents/MacOS/Iris > "$W/$1.out" 2>&1 &
  local S=$!; sleep "$2"
  local up=no; pgrep -x Iris >/dev/null && up=yes
  pkill -x Iris; sleep 3; pkill -9 -x Iris 2>/dev/null; wait $S 2>/dev/null
  tr -d '\r' < "$W/$1.out" | grep -a -E "publik-telemetry:|publik account link:" | grep -a -v -E "pk_|eyJ|pat_" > "$R/$1.lines.txt"
  rm -f "$W/$1.out"
  echo "== $1: process up at the end = $up; link key $(item publik-account-link-key); refresh token $(item supabase-refresh-token); publik API key $(item publik-api-key)" | tee -a "$R/summary.txt"
  sed 's/^/   /' "$R/$1.lines.txt" | tee -a "$R/summary.txt"
}
echo "before: link key $(item publik-account-link-key); refresh token $(item supabase-refresh-token); publik API key $(item publik-api-key)" | tee "$R/summary.txt"
run_iris run1 100
run_iris run2 35
security delete-generic-password -s com.publikhq.iris -a supabase-refresh-token rs.keychain >/dev/null 2>&1
echo "refresh token deleted (the session is gone, as after a refused restore)" | tee -a "$R/summary.txt"
run_iris run3 35
python3 -I -c 'import json,os; d=json.load(open(os.path.expanduser("~/Library/Application Support/publik/telemetry.json"))); print("telemetry install_id", d["install_id"])' | tee -a "$R/summary.txt"
security delete-keychain rs.keychain
