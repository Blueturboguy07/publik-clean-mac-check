#!/bin/bash
# prod-signed-out.sh <apps.json>: the PRODUCTION signed-out proof. No publik key exists on this machine. Each public build
# (one file per app, plus each command-line tool) runs against production with publikhq.com NOT blocked; the app's own API
# base points at a dead port, so nothing is spent. Apps share the normal home folder (install ID A); command-line tools
# share a second home folder (install ID B). The orchestrator reads the production rows by these two anonymous install IDs
# and deletes them. Prints no key (there is none).
set -u
LIST="$1"; ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
Q="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
HC="$ROOT/home-cli"; mkdir -p "$HC/Library/Application Support"
python3 -I - "$LIST" > "$ROOT/work.tsv" <<'PY'
import json, sys
seen = set()
for r in json.load(open(sys.argv[1])):
    if r["runner"] != "arm64": continue
    kind = "cli" if "-cli-" in r["file"] else "app"
    if (r["slug"], kind) in seen: continue
    seen.add((r["slug"], kind)); print("\t".join([r["slug"], kind, r["file"], r["url"]]))
PY
while IFS=$'\t' read -r SLUG KIND FILE URL; do
  D="$ROOT/w/$SLUG-$KIND"; rm -rf "$D"; mkdir -p "$D"; LOG="$R/$SLUG-$KIND.log"; : > "$LOG"; STATUS=""; NOTE=""; APP=""; BIN=""
  curl -sSL --retry 3 -o "$D/$FILE" "$URL" 2>>"$LOG" || NOTE="download failed"
  case "$FILE" in
    *.dmg) MNT="$D/mnt"; mkdir -p "$MNT"; hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$D/$FILE" >>"$LOG" 2>&1; A="$(find "$MNT" -maxdepth 2 -name '*.app' | head -1)"; [ -n "$A" ] && ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"; hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1;;
    *.zip) mkdir -p "$D/x"; ditto -x -k "$D/$FILE" "$D/x"; A="$(find "$D/x" -maxdepth 2 -name '*.app' | head -1)"
           if [ -n "$A" ]; then ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"
           else while IFS= read -r -d '' b; do file -b "$b" | grep -q "Mach-O" && { BIN="$b"; break; }; done < <(find "$D/x" -type f -print0); fi;;
  esac
  rm -f "$D/$FILE"
  if [ "$KIND" = app ] && [ -n "$APP" ]; then
    xattr -rw com.apple.quarantine "$Q" "$APP" 2>/dev/null
    EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
    W=60; [ "$SLUG" = astro ] && W=240
    ARGS=(); [ "$SLUG" = astro ] && ARGS=(--no-first-run --no-default-browser-check)
    ( cd "$D"; exec env -u PUBLIK_API_KEY -u PUBLIK_TELEMETRY_URL -u DO_NOT_TRACK PUBLIK_API_BASE_URL="http://127.0.0.1:9" PUBLIK_TELEMETRY_DEBUG=1 "$EXE" "${ARGS[@]+"${ARGS[@]}"}" ) > "$D/app.out" 2>&1 &
    for i in $(seq 1 "$W"); do grep -aq "publik-telemetry: app_opened ->" "$D/app.out" && break; sleep 1; done
    sleep 3; pkill -TERM -f "$APP/" 2>/dev/null; sleep 2; pkill -KILL -f "$APP/" 2>/dev/null; rm -rf "$APP"
    STATUS="$(grep -a -m1 "publik-telemetry: app_opened ->" "$D/app.out" | cut -c1-120)"
    [ -n "$STATUS" ] || { NOTE="no debug line (the row decides)"; tail -8 "$D/app.out" | cut -c1-200 >>"$LOG"; }
  elif [ "$KIND" = cli ] && [ -n "$BIN" ]; then
    xattr -w com.apple.quarantine "$Q" "$BIN"
    ( cd "$HC"; exec env -u PUBLIK_API_KEY -u PUBLIK_TELEMETRY_URL -u DO_NOT_TRACK HOME="$HC" PUBLIK_TELEMETRY_DEBUG=1 "$BIN" __publik_check__ ) > "$D/app.out" 2>&1
    for i in $(seq 1 60); do grep -aq "publik-telemetry: app_opened ->" "$D/app.out" && break; sleep 1; done
    STATUS="$(grep -a -m1 "publik-telemetry: app_opened ->" "$D/app.out" | cut -c1-120)"
    [ -n "$STATUS" ] || NOTE="no debug line (the row decides)"
  else NOTE="${NOTE:-nothing to run}"; fi
  python3 -I - "$R/results.jsonl" "$SLUG" "$KIND" "$FILE" "$STATUS" "$NOTE" <<'PY'
import json, sys
p, slug, kind, f, status, note = sys.argv[1:7]
open(p, "a").write(json.dumps({"slug": slug, "kind": kind, "file": f, "status": status, "sent_204": status.endswith("-> 204"), "note": note}) + "\n")
PY
  tail -1 "$R/results.jsonl"
  rm -rf "$D"
done < "$ROOT/work.tsv"
# The anonymous install IDs (not secrets): A = apps (normal home), B = command-line tools, plus any other telemetry.json.
find "$HOME" "$HC" -maxdepth 7 -name telemetry.json -path '*publik*' 2>/dev/null > "$R/telemetry-files.txt"
python3 -I - "$HOME/Library/Application Support/publik/telemetry.json" "$HC/Library/Application Support/publik/telemetry.json" "$R/telemetry-files.txt" "$R/install-ids.json" <<'PY'
import json, sys
def iid(p):
    try: return json.load(open(p))["install_id"]
    except Exception: return None
out = {"apps": iid(sys.argv[1]), "cli": iid(sys.argv[2]), "all": sorted({i for i in (iid(l.strip()) for l in open(sys.argv[3]) if l.strip()) if i})}
json.dump(out, open(sys.argv[4], "w")); print("install ids:", out)
PY
cat "$R/telemetry-files.txt"
