#!/bin/bash
# check-linux.sh <list> <runner> [only]: downloads each public Linux file from its install URL, runs it under a virtual display,
# and waits for its first event at a local listener. Then a second start with a made-up publik key. publikhq.com is blocked here.
set -u
LIST="$1"; RUNNER="$2"; ONLY="${3:-}"; ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
TESTKEY="pk_test_cleanmac_0123456789abcdef0123456789abcdef"
python3 - "$LIST" "$RUNNER" "$ONLY" > work-linux.tsv <<'PY'
import json,sys
for a in json.load(open(sys.argv[1])):
    if a["runner"]==sys.argv[2] and (not sys.argv[3] or a["slug"] in sys.argv[3].split(",")):
        print("\t".join([a["slug"],a["file"],a["url"]]))
PY
launch() { # launch <key or empty> <command...>
  local KEY="$1"; shift; : > "$L"; local T0=$SECONDS
  ( cd "$D"; exec env HOME="$D/home" XDG_CONFIG_HOME="$D/home/.config" APPIMAGE_EXTRACT_AND_RUN=1 ELECTRON_DISABLE_SANDBOX=1 PUBLIK_TELEMETRY_URL="http://127.0.0.1:$PORT/api/v1/telemetry" PUBLIK_API_BASE_URL="http://127.0.0.1:$PORT" PUBLIK_TELEMETRY_DEBUG=1 PUBLIK_TELEMETRY_INTERVAL_SECONDS=20 ${KEY:+PUBLIK_API_KEY=$KEY} xvfb-run -a "$@" ) >"$D/app.out" 2>&1 & AP=$!
  L_OPENED=false; L_SECS=""
  for i in $(seq 1 60); do
    if grep -q '"event": *"app_opened"' "$L" 2>/dev/null; then L_OPENED=true; L_SECS=$((SECONDS-T0)); break; fi
    kill -0 "$AP" 2>/dev/null || break
    sleep 1
  done
  sleep 4; L_UP=false; kill -0 "$AP" 2>/dev/null && L_UP=true
  grep -a -E "publik-telemetry" "$D/app.out" | head -4 >>"$LOG"
  [ "$L_OPENED" = true ] || tail -20 "$D/app.out" | cut -c1-240 >>"$LOG"
  kill "$AP" 2>/dev/null; pkill -f xvfb-run 2>/dev/null; pkill -TERM -f "$KILLPAT" 2>/dev/null; pkill -TERM -f appimage_extracted 2>/dev/null; sleep 2; pkill -KILL -f "$KILLPAT" 2>/dev/null; pkill -KILL -f appimage_extracted 2>/dev/null; sleep 1
}
while IFS=$'\t' read -r SLUG FILE URL; do
  LOG="$R/$SLUG-$FILE.log"; echo "=== $SLUG $FILE $URL" | tee "$LOG"
  D="$(mktemp -d)"; mkdir -p "$D/home"; F="$D/$FILE"; L="$D/listener.jsonl"
  DL=false; INST=false; OPENED=false; UP=false; SIGNED=false; SECS=""; APP=""; VER=""; NOTE=""; CMD=()
  curl -fsSL --retry 3 -o "$F" "$URL" && DL=true
  if [ "$DL" = true ]; then
    case "$FILE" in
      *.AppImage) chmod +x "$F"; CMD=("$F"); KILLPAT="$F"; INST=true;;
      *.deb) if sudo apt-get install -y "$F" >>"$LOG" 2>&1; then
               PKG="$(dpkg-deb -f "$F" Package)"; DESK="$(dpkg -L "$PKG" | grep '\.desktop$' | head -1)"; BIN="$(grep -m1 '^Exec=' "$DESK" | sed 's/^Exec=//; s/ %.*//; s/"//g')"
               echo "package $PKG runs $BIN" >>"$LOG"; CMD=("$BIN"); KILLPAT="$(basename "$BIN")"; INST=true
             else NOTE="apt could not install it"; fi;;
      *.rpm) rpm -qpi "$F" >>"$LOG" 2>&1 && NOTE="package read only: this machine does not install rpm files" || NOTE="rpm read failed";;
    esac
    if [ ${#CMD[@]} -gt 0 ]; then
      PORT=$((20000 + RANDOM % 20000)); : > "$L"
      python3 "$ROOT/listener.py" "$PORT" "$L" >>"$LOG" 2>&1 & LP=$!
      for i in $(seq 1 40); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ready")" = 204 ] && break; sleep 0.5; done
      launch "" "${CMD[@]}"; OPENED=$L_OPENED; SECS=$L_SECS; UP=$L_UP
      SEEN="$(grep -a -m1 -E 'app_opened|active_session' "$L" | cut -c1-260)"
      APP="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("app",""))' "$SEEN" 2>/dev/null)"
      VER="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("app_version",""))' "$SEEN" 2>/dev/null)"
      : > "$L.auth"; launch "$TESTKEY" "${CMD[@]}"
      grep -q "Bearer $TESTKEY" "$L.auth" 2>/dev/null && SIGNED=true
      kill "$LP" 2>/dev/null
    fi
  fi
  python3 - "$R/results.jsonl" "$SLUG" "$FILE" "$RUNNER" "$DL" "$INST" "$OPENED" "$SECS" "$APP" "$VER" "$UP" "$SIGNED" "$NOTE" <<'PY'
import json,sys
a=sys.argv
b=lambda s:s=="true"
r={"slug":a[2],"file":a[3],"platform":"linux","runner":a[4],"downloaded":b(a[5]),"installed":b(a[6]),"opened":b(a[7]),"secs":a[8],"event_app":a[9],"event_version":a[10],"still_up":b(a[11]),"signed_in_seen":b(a[12]),"note":a[13]}
open(a[1],"a").write(json.dumps(r)+"\n"); print(json.dumps(r))
PY
  rm -rf "$D"
done < work-linux.tsv
