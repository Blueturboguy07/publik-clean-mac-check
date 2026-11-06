#!/bin/bash
# real-store.sh <apps.json> [only csv]: for each app that holds a publik key, put a made-up key in the place the app's
# REAL sign-in saves it, then start the public build. No PUBLIK_API_KEY, no helper. Pass = the event carries that key.
# This is the app's own key provider at run time. A throwaway VM; nothing reaches production.
set -u
LIST="$1"; ONLY="${2:-}"; ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
KEY="pk_test_realstore_0123456789abcdef0123456789abcdef"
Q="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
AS="$HOME/Library/Application Support"
# One empty, open keychain, so an item made here can be read with no dialog.
security create-keychain -p test rs.keychain; security unlock-keychain -p test rs.keychain; security set-keychain-settings rs.keychain
security list-keychains -d user -s rs.keychain; security default-keychain -d user -s rs.keychain
cred() { mkdir -p "$AS/publik/apps"; printf '{"key":"%s","base_url":"https://publikhq.com/api/v1","app_slug":"%s","install_id":"11111111-1111-4111-8111-111111111111","claim_state":"unclaimed","claim_url":"https://publikhq.com/claim/x","add_credit_url":"https://publikhq.com/x","minted_at":"2026-11-06T00:00:00Z","model":"publik-fast","version":1}' "$KEY" "$1" > "$AS/publik/apps/$1.json"; chmod 600 "$AS/publik/apps/$1.json"; }
store_key() {
  case "$1" in
    cue) for d in cue Cue MicrosoftEdgeUpdate; do mkdir -p "$AS/$d"; printf '{"apiKeys":{"publik":"%s"},"publik":{"revoked":false}}' "$KEY" > "$AS/$d/cue-data.json"; done; STORE="userData/cue-data.json, apiKeys.publik";;
    publikclip) mkdir -p "$HOME/.publikclip"; printf '{"publik":{"key":"%s"}}' "$KEY" > "$HOME/.publikclip/secrets.json"; chmod 600 "$HOME/.publikclip/secrets.json"; STORE="~/.publikclip/secrets.json, publik.key";;
    simplicity) mkdir -p "$AS/Simplicity/data"; printf '{"version":1,"modelProviders":[{"id":"1","name":"publik API","type":"publik","config":{"apiKey":"%s","baseURL":"http://127.0.0.1:9/api/v1"}}]}' "$KEY" > "$AS/Simplicity/data/config.json"; STORE="userData/data/config.json, modelProviders[type=publik]";;
    whimprflow) security add-generic-password -U -s com.whimpr.whimprflow -a publik_api_key -w "$KEY" -A; STORE="Keychain com.whimpr.whimprflow / publik_api_key";;
    iris) security add-generic-password -U -s com.publikhq.iris -a publik-api-key -w "$KEY" -A; STORE="Keychain com.publikhq.iris / publik-api-key";;
    jobleft) SVC="jobleft-$(printf '%s' "$AS/jobleft" | shasum -a 256 | cut -c1-12)"; B64="$(printf '%s' "$KEY" | base64)"; security add-generic-password -U -a jobleft.publik.key -s "$SVC" -l "$SVC" -w "b64:$B64" -A; STORE="Keychain $SVC / jobleft.publik.key, b64";;
    nitroai|gspot|artcraft) cred "$1"; STORE="publik/apps/$1.json, key";;
  esac
}
python3 - "$LIST" "$ONLY" > work.tsv <<'PY'
import json, sys
only = [s for s in sys.argv[2].split(",") if s]
want = ["cue", "nitroai", "iris", "gspot", "publikclip", "jobleft", "simplicity", "whimprflow", "artcraft"]
rows = json.load(open(sys.argv[1]))
for s in want:
    if only and s not in only: continue
    r = [x for x in rows if x["slug"] == s and x["runner"] == "arm64" and "-cli-" not in x["file"]][0]
    print("\t".join([s, r["file"], r["url"]]))
PY
while IFS=$'\t' read -r SLUG FILE URL; do
  LOG="$R/$SLUG.log"; : > "$LOG"; D="$ROOT/w/$SLUG"; rm -rf "$D"; mkdir -p "$D"; APP=""; STORE=""; OPENED=false; SIGNED=false; NOTE=""; SEEN=""; MNT=""
  curl -sSL --retry 3 -o "$D/$FILE" "$URL" 2>>"$LOG" || NOTE="download failed"
  case "$FILE" in
    *.dmg) MNT="$D/mnt"; mkdir -p "$MNT"; hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$D/$FILE" >>"$LOG" 2>&1; A="$(find "$MNT" -maxdepth 2 -name '*.app' | head -1)"; [ -n "$A" ] && ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"; hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1;;
    *.zip) mkdir -p "$D/x"; ditto -x -k "$D/$FILE" "$D/x"; A="$(find "$D/x" -maxdepth 2 -name '*.app' | head -1)"; [ -n "$A" ] && ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")";;
  esac
  rm -f "$D/$FILE"
  if [ -n "$APP" ]; then
    xattr -rw com.apple.quarantine "$Q" "$APP" 2>/dev/null
    store_key "$SLUG"; echo "store: $STORE" >>"$LOG"
    EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
    PORT=$((20000 + RANDOM % 20000)); L="$D/listener.jsonl"; : > "$L"; : > "$L.auth"
    python3 "$ROOT/listener.py" "$PORT" "$L" >>"$LOG" 2>&1 & LP=$!
    for i in $(seq 1 40); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ready")" = 204 ] && break; sleep 0.5; done
    ( exec env -u PUBLIK_API_KEY PUBLIK_TELEMETRY_URL="http://127.0.0.1:$PORT/api/v1/telemetry" PUBLIK_API_BASE_URL="http://127.0.0.1:$PORT" PUBLIK_TELEMETRY_DEBUG=1 PUBLIK_TELEMETRY_INTERVAL_SECONDS=20 "$EXE" ) > "$D/app.out" 2>&1 & AP=$!
    for i in $(seq 1 120); do grep -q "Bearer $KEY" "$L.auth" 2>/dev/null && break; sleep 1; done
    sleep 1
    grep -q '"event": *"app_opened"' "$L" && OPENED=true
    grep -q "Bearer $KEY" "$L.auth" && SIGNED=true
    SEEN="$(grep -a -m1 -E 'app_opened|active_session' "$L" | cut -c1-240)"; echo "$SEEN" >>"$LOG"; grep -a -i 'publik-telemetry' "$D/app.out" | head -4 >>"$LOG"
    [ "$SIGNED" = true ] || tail -15 "$D/app.out" | cut -c1-200 >>"$LOG"
    pkill -TERM -f "$APP/" 2>/dev/null; sleep 2; pkill -KILL -f "$APP/" 2>/dev/null; kill "$LP" 2>/dev/null; rm -rf "$APP"
  else NOTE="${NOTE:-no .app}"; fi
  python3 - "$R/results.jsonl" "$SLUG" "$FILE" "$STORE" "$OPENED" "$SIGNED" "$NOTE" "$SEEN" <<'PY'
import json, sys
p, slug, f, store, op, si, note, seen = sys.argv[1:9]
open(p, "a").write(json.dumps({"slug": slug, "file": f, "store": store, "app_opened": op == "true", "real_store_key_sent": si == "true", "note": note, "first_event": seen}) + "\n")
PY
  tail -1 "$R/results.jsonl" | cut -c1-200
  rm -rf "$D"
done < work.tsv
