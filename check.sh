#!/bin/bash
# check.sh <apps.json> <arch: arm64|x64> [only slug]
# On a clean Mac: download each public file the way a browser does, install it, open it.
# Writes results/results.jsonl (one line per file) and results/<slug>-<file>.log.
set -u
LIST="$1"; ARCH="$2"; ONLY="${3:-}"
ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
Q="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
stapled() { local i; for i in 1 2 3 4 5; do xcrun stapler validate "$1" >/dev/null 2>&1 && return 0; sleep $((i*3)); done; return 1; }
python3 - "$LIST" "$ARCH" "$ONLY" > work.tsv <<'PY'
import json,sys
for a in json.load(open(sys.argv[1])):
    if a["runner"]==sys.argv[2] and (not sys.argv[3] or a["slug"] in sys.argv[3].split(",")):
        print("\t".join([a["slug"],a["file"],a["url"]]))
PY
while IFS=$'\t' read -r SLUG FILE URL; do
  LOG="$R/$SLUG-$FILE.log"; : > "$LOG"
  D="$(mktemp -d)"; F="$D/$FILE"
  DL=false; INTEGRITY=na; STAPLE_FILE=na; GK_FILE=na; INSTALLED=false; KIND=app; STAPLE_APP=false; GK_APP=false; GK_SOURCE=""
  OPENED=false; UP=false; SEEN=""; VER=""; DAMAGED=false; NOTE=""; OPENED2=na; SESSION=false; SECS=""; SECS2=""
  echo "=== $SLUG $FILE $URL" | tee -a "$LOG"
  curl -fsSL --retry 3 -o "$F" "$URL" && DL=true
  if [ "$DL" = true ]; then
    xattr -w com.apple.quarantine "$Q" "$F"
    MNT=""; APP=""
    case "$FILE" in
      *.dmg)
        hdiutil verify "$F" >>"$LOG" 2>&1 && INTEGRITY=true || INTEGRITY=false
        stapled "$F" && STAPLE_FILE=true || STAPLE_FILE=false
        O="$(spctl -a -t open --context context:primary-signature -vv "$F" 2>&1)"; echo "$O" >>"$LOG"
        echo "$O" | grep -q "accepted" && GK_FILE=true || GK_FILE=false
        MNT="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$F" >>"$LOG" 2>&1
        A="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
        if [ -n "$A" ]; then ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"; fi
        hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1
        ;;
      *.zip)
        INTEGRITY=true; X="$D/x"; mkdir -p "$X"; ditto -x -k "$F" "$X" 2>>"$LOG" || INTEGRITY=false
        A="$(find "$X" -maxdepth 2 -name '*.app' | head -1)"
        if [ -n "$A" ]; then ditto "$A" "/Applications/$(basename "$A")" && APP="/Applications/$(basename "$A")"
        else KIND=cli; fi
        ;;
    esac
    if [ "$KIND" = cli ]; then
      BIN=""; while IFS= read -r -d '' b; do file -b "$b" | grep -q "Mach-O" && { BIN="$b"; break; }; done < <(find "$X" -type f -print0)
      if [ -n "$BIN" ]; then
        xattr -w com.apple.quarantine "$Q" "$BIN"
        SP="$(spctl -a -t exec -vv "$BIN" 2>&1)"; echo "$SP" >>"$LOG"
        O="$(codesign --verify -R=notarized --check-notarization "$BIN" 2>&1)" && STAPLE_APP=true; echo "$O" >>"$LOG"
        if [ "$STAPLE_APP" = true ] && echo "$SP" | grep -q "the code is valid" && echo "$SP" | grep -q "R5R3ZS54LV"; then GK_APP=true; GK_SOURCE="source=notarized, codesign --check-notarization"; fi
        O="$("$BIN" --version 2>&1)"; RC=$?; echo "$O" | head -5 >>"$LOG"; VER="$(echo "$O" | head -1 | cut -c1-60)"
        [ $RC -eq 0 ] && { OPENED=true; UP=true; }; INSTALLED=true
        echo "$O" | grep -qi "damaged" && DAMAGED=true
      else NOTE="no Mach-O in the zip"; fi
    elif [ -n "$APP" ]; then
      INSTALLED=true
      # A browser and Finder keep the flag on every file of the copy.
      xattr -rw com.apple.quarantine "$Q" "$APP" 2>/dev/null
      stapled "$APP" && STAPLE_APP=true
      O="$(spctl -a -t exec -vv "$APP" 2>&1)"; echo "$O" >>"$LOG"
      echo "$O" | grep -q "accepted" && GK_APP=true; GK_SOURCE="$(echo "$O" | grep -o 'source=.*' | head -1)"
      VER="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
      EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
      PORT=$((20000 + RANDOM % 20000)); L="$D/listener.jsonl"; : > "$L"
      python3 "$ROOT/listener.py" "$PORT" "$L" >>"$LOG" 2>&1 & LP=$!
      for i in $(seq 1 40); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ready")" = 204 ] && break; sleep 0.5; done
      echo "listener ready after $i tries" >>"$LOG"
      H="$D/home"; mkdir -p "$H"
      W=45; [ "$ARCH" = x64 ] && W=90; [ "$SLUG" = astro ] && W=240
      # launch <extra args...>: runs the app, waits for app_opened. The interval env brings active_session early, so a lost first event still shows the client can reach the listener.
      launch() {
        : > "$L"; local T0=$SECONDS
        local RUNHOME="$H"; [ "$SLUG" = astro ] && RUNHOME="$HOME"
        ( cd "$H"; exec env HOME="$RUNHOME" PUBLIK_TELEMETRY_URL="http://127.0.0.1:$PORT/api/v1/telemetry" PUBLIK_API_BASE_URL="http://127.0.0.1:$PORT" PUBLIK_TELEMETRY_DEBUG=1 PUBLIK_TELEMETRY_INTERVAL_SECONDS=20 "$EXE" "$@" ) >"$D/app.out" 2>&1 & AP=$!
        LAUNCH_OPENED=false; LAUNCH_SECS=""
        for i in $(seq 1 "$W"); do
          if grep -q '"event": *"app_opened"' "$L" 2>/dev/null; then LAUNCH_OPENED=true; LAUNCH_SECS=$((SECONDS-T0)); break; fi
          kill -0 "$AP" 2>/dev/null || break
          sleep 1
        done
        sleep 4
        LAUNCH_UP=false; kill -0 "$AP" 2>/dev/null && LAUNCH_UP=true
        LAUNCH_SESSION=false; grep -q '"event": *"active_session"' "$L" 2>/dev/null && LAUNCH_SESSION=true
        if [ "$LAUNCH_OPENED" = false ]; then
          echo "--- no app_opened after ${W}s: what runs now" >>"$LOG"
          ps -axo pid,ppid,etime,command | grep -a -F "$APP/" | grep -v grep | cut -c1-200 | head -12 >>"$LOG"
          LAUNCH_NO=$((LAUNCH_NO+1)); screencapture -x "$R/$SLUG-$FILE-launch$LAUNCH_NO.png" 2>>"$LOG" || true
          tail -20 "$D/app.out" | cut -c1-240 >>"$LOG"
        fi
        grep -a -i -E "publik-telemetry|damaged|killed" "$D/app.out" | head -6 >>"$LOG"
        grep -a -qi "damaged" "$D/app.out" && DAMAGED=true
        pkill -TERM -f "$APP/" 2>/dev/null; sleep 2; pkill -KILL -f "$APP/" 2>/dev/null; sleep 1
      }
      LAUNCH_NO=0
      echo "--- first launch" >>"$LOG"
      launch
      OPENED=$LAUNCH_OPENED; UP=$LAUNCH_UP; SESSION=$LAUNCH_SESSION; SECS=$LAUNCH_SECS
      SEEN="$(grep -a -m1 -E 'app_opened|active_session' "$L" | cut -c1-260)"
      if [ "$OPENED" = false ]; then
        echo "--- second launch" >>"$LOG"
        if [ "$SLUG" = astro ]; then launch --no-first-run --no-default-browser-check; else launch; fi
        OPENED2=$LAUNCH_OPENED; SECS2=$LAUNCH_SECS; [ "$LAUNCH_SESSION" = true ] && SESSION=true
        [ -n "$SEEN" ] || SEEN="$(grep -a -m1 -E 'app_opened|active_session' "$L" | cut -c1-260)"
      fi
      kill "$LP" 2>/dev/null
      rm -rf "$APP"
    else NOTE="no .app in the file"; fi
  else NOTE="download failed"; fi
  python3 - "$R/results.jsonl" <<PY
import json,sys
open(sys.argv[1],"a").write(json.dumps({"slug":"$SLUG","file":"$FILE","arch":"$ARCH","kind":"$KIND","downloaded":$( [ "$DL" = true ] && echo True || echo False),"integrity":"$INTEGRITY","staple_file":"$STAPLE_FILE","gatekeeper_file":"$GK_FILE","installed":$( [ "$INSTALLED" = true ] && echo True || echo False),"staple_app":$( [ "$STAPLE_APP" = true ] && echo True || echo False),"gatekeeper_app":$( [ "$GK_APP" = true ] && echo True || echo False),"gatekeeper_source":"$GK_SOURCE","opened":$( [ "$OPENED" = true ] && echo True || echo False),"opened_second_launch":"$OPENED2","active_session_seen":$( [ "$SESSION" = true ] && echo True || echo False),"secs_to_app_opened":"$SECS","secs_second_launch":"$SECS2","still_up":$( [ "$UP" = true ] && echo True || echo False),"version":"""$VER""","damaged_message":$( [ "$DAMAGED" = true ] && echo True || echo False),"note":"$NOTE"})+"\n")
PY
  tail -1 "$R/results.jsonl"
  rm -rf "$D"
done < work.tsv
