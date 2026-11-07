#!/bin/bash
# prod-signed-in.sh <apps.json>: the PRODUCTION signed-in proof. The repo secret PROD_KEYS is JSON {"<slug>": key,
# "<slug>:cli": key}: real publik install keys, each made for that app and linked to one test account, revoked after the
# run. Each key goes where the app's own sign-in saves it, then the public build runs against production (publikhq.com is
# NOT blocked here; the app's own API base points at a dead port, so nothing is spent). The app prints only
# `publik-telemetry: app_opened -> <status>`. The orchestrator reads the production rows; this script never prints a key.
set -u
LIST="$1"; ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
Q="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
AS="$HOME/Library/Application Support"
python3 -I - "$ROOT/keys.tsv" <<'PY'
import json, os, sys
keys = json.loads(os.environ["PROD_KEYS"])
with open(sys.argv[1], "w") as f:
    for name, key in sorted(keys.items()):
        print("::add-mask::" + key)
        slug, _, kind = name.partition(":")
        f.write(f"{slug}\t{kind or 'app'}\t{key}\n")
PY
chmod 600 "$ROOT/keys.tsv"
security create-keychain -p test rs.keychain; security unlock-keychain -p test rs.keychain; security set-keychain-settings rs.keychain
security list-keychains -d user -s rs.keychain; security default-keychain -d user -s rs.keychain
cred() { mkdir -p "$1/publik/apps"; printf '{"key":"%s","base_url":"https://publikhq.com/api/v1","app_slug":"%s","version":1}' "$KEY" "$2" > "$1/publik/apps/$2.json"; chmod 600 "$1/publik/apps/$2.json"; }
store_key() {
  case "$1" in
    cue) for d in cue Cue; do mkdir -p "$AS/$d"; printf '{"apiKeys":{"publik":"%s"},"publik":{"revoked":false}}' "$KEY" > "$AS/$d/cue-data.json"; done; STORE="userData/cue-data.json, apiKeys.publik";;
    publikclip) mkdir -p "$HOME/.publikclip"; printf '{"publik":{"key":"%s"}}' "$KEY" > "$HOME/.publikclip/secrets.json"; chmod 600 "$HOME/.publikclip/secrets.json"; STORE="~/.publikclip/secrets.json, publik.key";;
    simplicity) mkdir -p "$AS/Simplicity/data"; printf '{"version":1,"modelProviders":[{"id":"1","name":"publik API","type":"publik","config":{"apiKey":"%s","baseURL":"http://127.0.0.1:9/api/v1"}}]}' "$KEY" > "$AS/Simplicity/data/config.json"; STORE="userData/data/config.json, modelProviders[type=publik]";;
    whimprflow) security add-generic-password -U -s com.whimpr.whimprflow -a publik_api_key -w "$KEY" -A; security set-generic-password-partition-list -S "apple-tool:,apple:,teamid:R5R3ZS54LV" -k test -s com.whimpr.whimprflow -a publik_api_key rs.keychain >/dev/null 2>&1; STORE="Keychain com.whimpr.whimprflow / publik_api_key";;
    iris) security add-generic-password -U -s com.publikhq.iris -a publik-api-key -w "$KEY" -A; security set-generic-password-partition-list -S "apple-tool:,apple:,teamid:R5R3ZS54LV" -k test -s com.publikhq.iris -a publik-api-key rs.keychain >/dev/null 2>&1; STORE="Keychain com.publikhq.iris / publik-api-key";;
    jobleft) SVC="jobleft-$(printf '%s' "$AS/jobleft" | shasum -a 256 | cut -c1-12)"; B64="$(printf '%s' "$KEY" | base64)"; security add-generic-password -U -a jobleft.publik.key -s "$SVC" -l "$SVC" -w "b64:$B64" -A; STORE="Keychain $SVC / jobleft.publik.key";;
    *) cred "$AS" "$1"; STORE="publik/apps/$1.json, key";;
  esac
}
row() { python3 -I - "$LIST" "$1" "$2" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])); slug, kind = sys.argv[2], sys.argv[3]
r = [x for x in rows if x["slug"] == slug and x["runner"] == "arm64" and (("-cli-" in x["file"]) == (kind == "cli"))]
print("\t".join([r[0]["file"], r[0]["url"]]) if r else "")
PY
}
while IFS=$'\t' read -r SLUG KIND KEY; do
  D="$ROOT/w/$SLUG-$KIND"; rm -rf "$D"; mkdir -p "$D"; LOG="$R/$SLUG-$KIND.log"; : > "$LOG"; STATUS=""; NOTE=""; STORE=""; APP=""; BIN=""
  IFS=$'\t' read -r FILE URL <<< "$(row "$SLUG" "$KIND")"
  if [ -z "${URL:-}" ]; then NOTE="no file in apps.json"; else
    curl -sSL --retry 3 -o "$D/$FILE" "$URL" 2>>"$LOG" || NOTE="download failed"
    case "$FILE" in
      *.dmg) MNT="$D/mnt"; mkdir -p "$MNT"; hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$D/$FILE" >>"$LOG" 2>&1; A="$(find "$MNT" -maxdepth 2 -name '*.app' | head -1)"; [ -n "$A" ] && ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"; hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1;;
      *.zip) mkdir -p "$D/x"; ditto -x -k "$D/$FILE" "$D/x"; A="$(find "$D/x" -maxdepth 2 -name '*.app' | head -1)"
             if [ -n "$A" ]; then ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"
             else while IFS= read -r -d '' b; do file -b "$b" | grep -q "Mach-O" && { BIN="$b"; break; }; done < <(find "$D/x" -type f -print0); fi;;
    esac
    rm -f "$D/$FILE"
  fi
  if [ "$KIND" = app ] && [ -n "$APP" ]; then
    xattr -rw com.apple.quarantine "$Q" "$APP" 2>/dev/null; store_key "$SLUG"
    EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
    ( exec env -u PUBLIK_API_KEY -u PUBLIK_TELEMETRY_URL PUBLIK_API_BASE_URL="http://127.0.0.1:9" PUBLIK_TELEMETRY_DEBUG=1 "$EXE" ) > "$D/app.out" 2>&1 &
    for i in $(seq 1 120); do grep -aq "publik-telemetry: app_opened ->" "$D/app.out" && break; sleep 1; done
    pkill -TERM -f "$APP/" 2>/dev/null; sleep 2; pkill -KILL -f "$APP/" 2>/dev/null; rm -rf "$APP"
    STATUS="$(grep -a -m1 "publik-telemetry: app_opened ->" "$D/app.out" | cut -c1-120)"
    [ -n "$STATUS" ] || tail -12 "$D/app.out" | cut -c1-200 >>"$LOG"
  elif [ "$KIND" = cli ] && [ -n "$BIN" ]; then
    xattr -w com.apple.quarantine "$Q" "$BIN"; H="$D/home"; mkdir -p "$H/Library/Application Support"; cred "$H/Library/Application Support" "$SLUG"; STORE="publik/apps/$SLUG.json (own HOME), key"
    ( cd "$H"; exec env -u PUBLIK_API_KEY -u PUBLIK_TELEMETRY_URL HOME="$H" PUBLIK_TELEMETRY_DEBUG=1 "$BIN" __publik_check__ ) > "$D/app.out" 2>&1
    for i in $(seq 1 60); do grep -aq "publik-telemetry: app_opened ->" "$D/app.out" && break; sleep 1; done
    STATUS="$(grep -a -m1 "publik-telemetry: app_opened ->" "$D/app.out" | cut -c1-120)"
  else NOTE="${NOTE:-nothing to run}"; fi
  python3 -I - "$R/results.jsonl" "$SLUG" "$KIND" "${FILE:-}" "$STORE" "$STATUS" "$NOTE" <<'PY'
import json, sys
p, slug, kind, f, store, status, note = sys.argv[1:8]
open(p, "a").write(json.dumps({"slug": slug, "kind": kind, "file": f, "store": store, "status": status, "sent_204": status.endswith("-> 204"), "note": note}) + "\n")
PY
  tail -1 "$R/results.jsonl"
  rm -rf "$D"
done < "$ROOT/keys.tsv"
# Scrub: no key may reach the uploaded results, even if an app printed one.
python3 -I - "$ROOT/keys.tsv" "$R" <<'PY'
import os, sys
keys = [l.rstrip("\n").split("\t")[2] for l in open(sys.argv[1]) if l.strip()]
for name in os.listdir(sys.argv[2]):
    p = os.path.join(sys.argv[2], name); t = open(p, errors="replace").read()
    for k in keys: t = t.replace(k, "[key]")
    open(p, "w").write(t)
PY
rm -f "$ROOT/keys.tsv"
