#!/bin/bash
# gate-window.sh <gate-apps.json>
# On a clean Mac: download the newest public dmg of each app the way a browser does (quarantine flag on), install it
# to /Applications and open it with `open -a`. There are no environment overrides and no key file: the app talks to the
# real https://publikhq.com, as a user's install does. 15 s after the open, take a screenshot of the whole screen and
# record the window titles; 15 s later, take a second screenshot. Then quit the app.
# If the macOS first-open dialog ("downloaded from the Internet") stops the app, the script clicks "Open" as a user
# does and takes two more screenshots (-3 and -4). Screenshot -0 is the screen before the open. A list of every
# on-screen window with its owner process goes with the screenshots. An alert window that stays after the app has quit
# is recorded, and its owner process (UserNotificationCenter or osascript only) is stopped, so the next app starts clean.
# Writes results/results.jsonl (one line per app), results/<slug>.log, results/<slug>-N.png and results/control.*.
# One app that fails does not stop the others (set -u, not set -e).
set -u
LIST="$1"; ROOT="$PWD"; R="$ROOT/results"; mkdir -p "$R"
Q="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
tmo() { perl -e 'alarm shift; exec @ARGV or die "exec failed: $!\n"' "$@"; }   # tmo <seconds> <command...>

# The window titles, exactly as asked: {names of the processes, titles of their windows}.
TITLES_AS='tell application "System Events" to get {name, title of windows} of (processes whose background only is false)'
# The same data, one "process | window" line each, so that a person can read it.
PAIRS_AS='set out to ""
tell application "System Events"
  repeat with p in (processes whose background only is false)
    set n to name of p
    try
      set ws to windows of p
      if (count of ws) is 0 then set out to out & n & " | (no window)" & linefeed
      repeat with w in ws
        set out to out & n & " | " & (name of w as text) & linefeed
      end repeat
    on error e
      set out to out & n & " | error: " & e & linefeed
    end try
  end repeat
end tell
return out'
# The macOS first-open dialog: record its text; click "Open" (as a user does). A dialog with no "Open" button is closed
# with "Done", "OK" or "Cancel", so that it does not cover the next app. It never clicks "Move to Trash".
DIALOG_AS='tell application "System Events"
  if not (exists process "CoreServicesUIAgent") then return "no dialog"
  tell process "CoreServicesUIAgent"
    if (count of windows) is 0 then return "no dialog"
    set t to ""
    try
      set AppleScript'"'"'s text item delimiters to " / "
      set t to (value of static texts of window 1) as text
    end try
    set bs to ""
    try
      set bs to (name of buttons of window 1) as text
    end try
    repeat with b in {"Open", "Done", "OK", "Cancel"}
      if exists button (b as text) of window 1 then
        click button (b as text) of window 1
        return "clicked " & (b as text) & " | text: " & t & " | buttons: " & bs
      end if
    end repeat
    return "dialog, no button clicked | text: " & t & " | buttons: " & bs
  end tell
end tell'

# ---------- Control: the screen capture and System Events work on this runner ----------
C="$R/control.log"; : > "$C"
{ echo "=== control $(date -u +%FT%TZ)"; sw_vers; uname -m; spctl --status
  echo "LSQuarantine default: $(defaults read com.apple.LaunchServices LSQuarantine 2>&1)"
  echo "PUBLIK_ variables in this environment: $(env | grep -c '^PUBLIK_')"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Display Type|Main Display" ; } >>"$C" 2>&1
# Every window on the screen with its owner process (System Events does not show agent apps or system alerts).
mkdir -p "$ROOT/w"; WINLIST="$ROOT/w/winlist"
cat > "$ROOT/w/winlist.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { print("(no window list)"); exit(0) }
var n = 0
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    if owner == "Window Server" || owner == "Dock" { continue }
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    var r = CGRect.zero
    if let b = w[kCGWindowBounds as String] as? NSDictionary, let rr = CGRect(dictionaryRepresentation: b as CFDictionary) { r = rr }
    if r.height < 50 { continue }
    print("\(owner) [pid \(pid)] layer \(layer) \"\(name)\" at \(Int(r.minX)),\(Int(r.minY)) size \(Int(r.width))x\(Int(r.height))")
    n += 1
}
if n == 0 { print("(no window)") }
SWIFT
tmo 180 swiftc -O -o "$WINLIST" "$ROOT/w/winlist.swift" >>"$C" 2>&1 || echo "window list tool: build failed" >>"$C"
winlist() { if [ -x "$WINLIST" ]; then tmo 20 "$WINLIST" 2>&1; else echo "(no window list tool)"; fi; }
tmo 30 screencapture -x "$R/control-0-desktop.png" >>"$C" 2>&1 || echo "control desktop screenshot failed" >>"$C"
open -a Calculator >>"$C" 2>&1; sleep 6
tmo 30 screencapture -x "$R/control-1-calculator.png" >>"$C" 2>&1 || echo "control calculator screenshot failed" >>"$C"
echo "--- on-screen windows (control)" >>"$C"; winlist >>"$C"
echo "--- titles (control)" >>"$C"; tmo 60 osascript -e "$TITLES_AS" >>"$C" 2>&1 || echo "System Events refused (control): rc=$?" >>"$C"
echo "--- pairs (control)" >>"$C"; tmo 60 osascript -e "$PAIRS_AS" >>"$C" 2>&1 || echo "System Events refused (control pairs): rc=$?" >>"$C"
tmo 20 osascript -e 'tell application "Calculator" to quit' >>"$C" 2>&1; sleep 2; pkill -x Calculator 2>/dev/null
cat "$C"

python3 -I - "$LIST" > "$ROOT/work.tsv" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])):
    print("\t".join([a["slug"], a["tag"], a["file"], a["url"], a["sha256"]]))
PY

while IFS=$'\t' read -r -u 3 SLUG TAG FILE URL SHA; do
  LOG="$R/$SLUG.log"; : > "$LOG"; ERR=""
  D="$ROOT/w/$SLUG"; rm -rf "$D"; mkdir -p "$D"; F="$D/$FILE"
  DL=false; SHA_GOT=""; SHA_OK=false; SIZE=""; VERIFY=false; GK=false; GK_OUT=""; APP=""; NAME=""; BID=""; VER=""; QTN_APP=""
  OPEN_RC=""; OPEN_OUT=""; RUN1=false; RUN2=false; RUN3=false; RUN_BQ=false; RUN_AQ=""; QUIT_OUT=""
  TITLES=""; PAIRS1=""; PAIRS2=""; PAIRS3=""; DIALOG=""; BROWSER=""; SHOTS=""
  WL0=""; WL1=""; WL3=""; WLQ=""; LEFTOVER=""
  err() { ERR="${ERR:+$ERR; }$1"; echo "ERROR: $1" >>"$LOG"; }
  shot() { if tmo 30 screencapture -x "$R/$1" >>"$LOG" 2>&1 && [ -s "$R/$1" ]; then SHOTS="${SHOTS:+$SHOTS,}$1"; else err "screencapture $1 failed"; fi; }
  echo "=== $SLUG $TAG $FILE $(date -u +%FT%TZ)" | tee -a "$LOG"

  # 1. Download (quarantine flag on, as a browser does), check, mount read-only, install, detach.
  if curl -fsSL --retry 3 -o "$F" "$URL" 2>>"$LOG"; then DL=true; else err "download failed"; fi
  if [ "$DL" = true ]; then
    xattr -w com.apple.quarantine "$Q" "$F"
    SIZE="$(stat -f %z "$F")"
    SHA_GOT="$(shasum -a 256 "$F" | cut -d' ' -f1)"
    if [ "$SHA_GOT" = "$SHA" ]; then SHA_OK=true; else err "sha256 mismatch: got $SHA_GOT"; fi
    hdiutil verify "$F" >>"$LOG" 2>&1 </dev/null && VERIFY=true || err "hdiutil verify failed"
    GK_OUT="$(spctl -a -t open --context context:primary-signature -vv "$F" 2>&1)"; echo "$GK_OUT" >>"$LOG"
    echo "$GK_OUT" | grep -q "accepted" && GK=true
    MNT="$D/mnt"; mkdir -p "$MNT"
    if hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$F" >>"$LOG" 2>&1 </dev/null; then
      A="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
      if [ -n "$A" ]; then
        B="$(basename "$A")"
        # A fresh install: ditto merges into an existing folder, so any older copy goes first.
        [ -e "/Applications/$B" ] && { echo "old copy found and removed: /Applications/$B" >>"$LOG"; rm -rf "/Applications/$B"; }
        if ditto "$A" "/Applications/$B" 2>>"$LOG"; then APP="/Applications/$B"; else err "ditto failed"; fi
      else err "no .app on the dmg"; fi
      hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1
    else err "hdiutil attach failed"; fi
  fi

  if [ -n "$APP" ]; then
    # A browser and Finder keep the flag on every file of the copy (as in check.sh).
    xattr -rw com.apple.quarantine "$Q" "$APP" 2>/dev/null
    NAME="$(basename "$APP" .app)"; PAT="$NAME.app/Contents/MacOS/"
    BID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    VER="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
    QTN_APP="$(xattr -p com.apple.quarantine "$APP" 2>/dev/null)"
    running() { pgrep -f "$PAT" >/dev/null 2>&1; }
    echo "app: $APP  id: $BID  version: $VER  quarantine: $QTN_APP" >>"$LOG"

    # The screen before the open: it must be clean (no window of an earlier app).
    WL0="$(winlist)"; printf -- '--- on-screen windows before the open\n%s\n' "$WL0" >>"$LOG"
    shot "$SLUG-0.png"

    # 2. Open it with no environment overrides, as a user does.
    echo "--- open -a \"$APP\" $(date -u +%T)" >>"$LOG"
    open -a "$APP" >"$D/open.out" 2>&1 & OP=$!

    # 3. 15 s, screenshot 1 and the window titles; 15 s more, screenshot 2.
    sleep 15
    running && RUN1=true
    shot "$SLUG-1.png"
    TITLES="$(tmo 20 osascript -e "$TITLES_AS" 2>&1)" || err "System Events (titles) failed: $(echo "$TITLES" | tail -1 | cut -c1-200)"
    PAIRS1="$(tmo 20 osascript -e "$PAIRS_AS" 2>&1)" || err "System Events (window list 1) failed"
    WL1="$(winlist)"
    printf -- '--- titles at 15 s\n%s\n--- windows at 15 s\n%s\n--- on-screen windows at 15 s\n%s\n' "$TITLES" "$PAIRS1" "$WL1" >>"$LOG"
    sleep 15
    running && RUN2=true
    shot "$SLUG-2.png"
    PAIRS2="$(tmo 20 osascript -e "$PAIRS_AS" 2>&1)" || err "System Events (window list 2) failed"
    printf -- '--- windows at 30 s\n%s\n' "$PAIRS2" >>"$LOG"
    if kill -0 "$OP" 2>/dev/null; then OPEN_RC="open still waiting after 30 s"; kill "$OP" 2>/dev/null; else wait "$OP"; OPEN_RC="$?"; fi
    OPEN_OUT="$(cut -c1-300 "$D/open.out")"; echo "open: rc=$OPEN_RC $OPEN_OUT" >>"$LOG"

    # The macOS first-open dialog, if it is on the screen: click "Open" as a user does, then two more screenshots.
    DIALOG="$(tmo 20 osascript -e "$DIALOG_AS" 2>&1)" || err "first-open dialog check failed: $(echo "$DIALOG" | tail -1 | cut -c1-200)"
    echo "--- first-open dialog: $DIALOG" >>"$LOG"
    case "$DIALOG" in
      "clicked Open"*)
        sleep 15; running && RUN3=true; shot "$SLUG-3.png"
        PAIRS3="$(tmo 20 osascript -e "$PAIRS_AS" 2>&1)" || err "System Events (window list 3) failed"
        WL3="$(winlist)"
        printf -- '--- windows 15 s after Open\n%s\n--- on-screen windows 15 s after Open\n%s\n' "$PAIRS3" "$WL3" >>"$LOG"
        sleep 15; running && RUN3=true; shot "$SLUG-4.png" ;;
    esac

    # 4. Quit. Record whether the process ran before the quit; pkill is the fallback.
    running && RUN_BQ=true
    pgrep -lf "$NAME.app/Contents/" >>"$LOG" 2>&1
    if [ "$RUN_BQ" = true ]; then
      QUIT_OUT="$(tmo 30 osascript -e "tell application \"$NAME\" to quit" 2>&1)" || err "AppleScript quit failed: $(echo "$QUIT_OUT" | tail -1 | cut -c1-200)"
      sleep 5
    fi
    if pgrep -f "$NAME.app/Contents/" >/dev/null 2>&1; then
      RUN_AQ=true; pkill -f "$NAME.app/Contents/"; sleep 2; pkill -KILL -f "$NAME.app/Contents/" 2>/dev/null
    else RUN_AQ=false; fi
    # A browser that the app opened by itself would cover the next app: record it and quit it.
    for BR in Safari "Google Chrome" Firefox; do
      if pgrep -x "$BR" >/dev/null 2>&1; then BROWSER="${BROWSER:+$BROWSER,}$BR"; tmo 20 osascript -e "tell application \"$BR\" to quit" >>"$LOG" 2>&1; sleep 2; pkill -x "$BR" 2>/dev/null; fi
    done
    [ -n "$BROWSER" ] && echo "browser that ran during this app: $BROWSER" >>"$LOG"
    # Close a dialog that is still on the screen (never "Move to Trash").
    LEFT="$(tmo 20 osascript -e "$DIALOG_AS" 2>&1)"; [ "$LEFT" != "no dialog" ] && echo "--- dialog after quit: $LEFT" >>"$LOG"
    # An alert window that stays after the app has quit (it belongs to a system alert process, not to the app) would
    # cover the next app. Record its owner and stop that process. Its button is never clicked.
    WLQ="$(winlist)"; printf -- '--- on-screen windows after the quit\n%s\n' "$WLQ" >>"$LOG"
    for P in $(echo "$WLQ" | grep -o '\[pid [0-9]*\]' | grep -o '[0-9]*' | sort -u); do
      echo "$WL0" | grep -q "\[pid $P\]" || echo "window owner that was not there before the open: $(ps -p "$P" -o pid=,comm= 2>/dev/null | cut -c1-160)" >>"$LOG"
    done
    for OWN in UserNotificationCenter osascript; do
      if echo "$WLQ" | grep -q "^$OWN \["; then LEFTOVER="${LEFTOVER:+$LEFTOVER,}$OWN"; pkill -x "$OWN"; sleep 2; fi
    done
    [ -n "$LEFTOVER" ] && printf -- '--- stopped: %s\n%s\n' "$LEFTOVER" "$(winlist)" >>"$LOG"
  fi

  # 5. One JSON line for this app.
  J_SLUG="$SLUG" J_TAG="$TAG" J_FILE="$FILE" J_URL="$URL" J_SIZE="$SIZE" J_SHA_EXP="$SHA" J_SHA_GOT="$SHA_GOT" J_SHA_OK="$SHA_OK" \
  J_DL="$DL" J_VERIFY="$VERIFY" J_GK="$GK" J_GK_OUT="$GK_OUT" J_APP="$APP" J_BID="$BID" J_VER="$VER" J_QTN="$QTN_APP" \
  J_OPEN_RC="$OPEN_RC" J_OPEN_OUT="$OPEN_OUT" J_RUN1="$RUN1" J_RUN2="$RUN2" J_RUN3="$RUN3" J_RUN_BQ="$RUN_BQ" J_RUN_AQ="$RUN_AQ" \
  J_TITLES="$TITLES" J_PAIRS1="$PAIRS1" J_PAIRS2="$PAIRS2" J_PAIRS3="$PAIRS3" J_DIALOG="$DIALOG" J_BROWSER="$BROWSER" \
  J_WL0="$WL0" J_WL1="$WL1" J_WL3="$WL3" J_WLQ="$WLQ" J_LEFTOVER="$LEFTOVER" \
  J_SHOTS="$SHOTS" J_ERR="$ERR" python3 -I - "$R/results.jsonl" <<'PY'
import json, os, sys
e = lambda k: os.environ.get("J_" + k, "")
b = lambda k: e(k) == "true"
row = {
    "slug": e("SLUG"), "tag": e("TAG"), "file": e("FILE"), "url": e("URL"), "size": e("SIZE"),
    "downloaded": b("DL"), "sha256_expected": e("SHA_EXP"), "sha256_got": e("SHA_GOT"), "sha256_verified": b("SHA_OK"),
    "hdiutil_verify": b("VERIFY"), "gatekeeper_accepted": b("GK"), "gatekeeper_output": e("GK_OUT"),
    "app": e("APP"), "bundle_id": e("BID"), "version": e("VER"), "quarantine_on_app": e("QTN"),
    "open_rc": e("OPEN_RC"), "open_output": e("OPEN_OUT"),
    "process_running_at_15s": b("RUN1"), "process_running_at_30s": b("RUN2"), "process_running_after_dialog_open": b("RUN3"),
    "process_running_before_quit": b("RUN_BQ"), "process_running_after_quit": e("RUN_AQ"),
    "process_seen_running": b("RUN1") or b("RUN2") or b("RUN3") or b("RUN_BQ"),
    "window_titles": e("TITLES"), "windows_at_15s": e("PAIRS1"), "windows_at_30s": e("PAIRS2"), "windows_after_dialog_open": e("PAIRS3"),
    "first_open_dialog": e("DIALOG"), "browser_seen": e("BROWSER"),
    "onscreen_before_open": e("WL0"), "onscreen_at_15s": e("WL1"), "onscreen_after_dialog_open": e("WL3"),
    "onscreen_after_quit": e("WLQ"), "leftover_owner_stopped": e("LEFTOVER"),
    "screenshots": [s for s in e("SHOTS").split(",") if s], "error": e("ERR"),
}
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
print(json.dumps({k: row[k] for k in ("slug", "sha256_verified", "gatekeeper_accepted", "process_seen_running", "first_open_dialog", "screenshots", "error")}))
PY
  rm -rf "$D"
done 3< "$ROOT/work.tsv"
echo "=== done $(date -u +%FT%TZ)"
