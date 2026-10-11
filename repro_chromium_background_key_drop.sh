#!/bin/bash
# repro_chromium_background_key_drop.sh — evidence script for trycua/cua
#
# Self-contained: launches an ISOLATED Chrome instance (own --user-data-dir
# under /tmp, two pages served from a localhost http.server) and drives its
# omnibox with cua-driver. No user profile is touched; artifacts (raw tool
# JSON + screenshots + manifest + this run's literal output) land in $OUT.
#
# Two phases:
#   Phase A (cooperative case — Chrome stays frontmost throughout)
#   Phase B (real-session case — Finder is frontmost, as when agent CLIs run
#            while other apps own the screen)
#
# Expected vs observed (kept honest on purpose; observations from the
# captured runs — the issue quotes run 2 of the final pair):
#   A1 type_text AX insert, frontmost        -> confirmed (replaces the
#     select-all'd page URL: single click leaves the text selected, so the
#     insert lands on a selection; NOT a plain append)
#   A2 press_key return, background          -> refused same_pid_keyboard_ambiguity
#     (a transient "Sign In to Chrome?" bubble presumably counted as a sibling
#     keyboard destination; the same call was NOT refused in Phase B once the
#     bubble was gone — the refusal itself is state-dependent)
#   A3 press_key return, foreground+element  -> unverifiable, no navigation
#   B1 type_text AX insert, unfocused        -> confirmed (text lands while
#     Chrome is NOT frontmost; appends to whatever the omnibox buffer holds)
#   B2 press_key return, background          -> unverifiable, NO navigation
#     (silent drop; this is the report's core observation)
#   B3 press_key return, foreground w/o element -> unverifiable; the page
#     outcome tracks invisible omnibox buffer state, not the call: across
#     all 10 valid captured runs (spanning every revision of this script)
#     the stale concatenated buffer was committed 6 times and delivery
#     no-op'd 4 times — while every structured result reads "unverifiable".
#     That masking is part of the report.
#   B4 press_key return, foreground+element  -> unverifiable, nothing further
#
# type_text has NO replace flag: AX inserts go to the cursor position and
# append when the buffer already holds text (documented insert-at-cursor
# semantics). The reset step and B1 therefore deliberately concatenate —
# that behavior is itself discussed in the issue.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d /tmp/cua-repro-run-XXXX)"
PORT="${PORT:-8123}"
CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d /tmp/cua-repro-profile-XXXX)"
MANIFEST="$OUT/run_manifest.tsv"
SESS="repro-$$"  # unique per run: the driver rejects a label whose previous session has ended

say() { printf '%s\n' "$*"; }
cleanup() {
  [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  rm -rf "$PROFILE" 2>/dev/null
}
trap cleanup EXIT

# call_tool NAME ARGS — run one cua-driver call, save RAW stdout, print a
# one-line verdict derived ONLY from the saved payload (no hand paraphrase).
call_tool() {
  local name="$1" tool="$2" args="$3"
  cua-driver "$tool" "$args" >"$OUT/$name.json" 2>&1
  python3 - "$OUT/$name.json" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    txt = open(path).read()
    d = json.loads(txt[txt.find('{'):])
except Exception as e:
    if "session has ended" in txt:
        print(f"{name}: REJECTED — session has ended (label reuse)")
    else:
        print(f"{name}: PARSE-FAIL ({e}) — see raw file")
    sys.exit(0)
if d.get("status") == "refused" or d.get("refusal") or d.get("effect") == "refused":
    code = (d.get("refusal") or {}).get("code") or d.get("code")
    print(f"{name}: REFUSED {code} (effect=refused)")
elif "effect" in d:
    line = f"{name}: effect={d['effect']}"
    if d.get("route"): line += f" route={d['route']}"
    if d.get("delivered_count") is not None: line += f" delivered_count={d['delivered_count']}"
    print(line)
else:
    print(f"{name}: ok (no effect field)")
PY
}

# title_of_wid + bounded polling instead of fixed sleeps
title_of_wid() { cua-driver list_windows 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((w.get('title') for w in d['windows'] if w.get('window_id')==int('$1')),'?'))"; }
wait_title() { # wid expected timeout_s -> 0 if reached
  local wid="$1" want="$2" t="$3" i=0
  while [ "$i" -lt "$t" ]; do
    [ "$(title_of_wid "$wid")" = "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
omni_token() { cua-driver get_window_state "{\"pid\":$GPID,\"window_id\":$GWID,\"session\":\"$SESS\",\"query\":\"address and search bar\"}" 2>/dev/null | python3 -c "
import json,sys
d=json.loads(sys.stdin.read(), strict=False)
print(next((e['element_token'] for e in d['elements'] if e.get('role')=='AXTextField' and 'Address' in (e.get('label') or '')),''))"; }
shot() { cua-driver get_window_state "{\"pid\":$GPID,\"window_id\":$GWID,\"session\":\"$SESS\",\"screenshot_out_file\":\"$OUT/$1.png\"}" >/dev/null 2>&1; test -s "$OUT/$1.png" || echo "WARN: screenshot $1 missing/empty"; }
log_row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$MANIFEST"; }

say "== repro dir: $OUT =="
exec > >(tee "$OUT/run_output.txt") 2>&1   # capture-only: this transcript ships inside $OUT

# --- local pages + isolated Chrome (preflighted) ---
( cd "$HERE/srv" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) & SRV=$!
for i in $(seq 1 10); do curl -sf "http://localhost:$PORT/repro-before.html" >/dev/null && break; sleep 0.5; done
curl -sf "http://localhost:$PORT/repro-before.html" >/dev/null || { echo "FAIL: local server not serving on :$PORT (port busy?)"; exit 1; }
"$CHROME_BIN" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  "http://localhost:$PORT/repro-before.html" >/dev/null 2>&1 & CPID=$!
WIN=""
for i in $(seq 1 20); do
  sleep 1
  WIN=$(cua-driver list_windows 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((f\"{w['pid']} {w['window_id']}\" for w in d.get('windows',[])
  if w.get('is_on_screen') and w.get('pid')==$CPID and 'REPRO-BEFORE' in (w.get('title') or '')),''))")
  [ -n "$WIN" ] && break
done
[ -z "${WIN:-}" ] && { echo "FAIL: isolated Chrome window not found (pid $CPID)"; exit 1; }
read -r GPID GWID <<< "$WIN"
say "driver: $(cua-driver --version 2>/dev/null | head -1) | chrome: $("$CHROME_BIN" --version 2>/dev/null) | os: $(sw_vers -productVersion)"
say "target: pid=$GPID window=$GWID title='$(title_of_wid "$GWID")'"
log_row setup window_found "$(title_of_wid "$GWID")"
omni=$(omni_token); [ -z "$omni" ] && { echo "FAIL: omnibox element not found in window $GWID"; exit 1; }
say "omnibox token: $omni"

# ================= PHASE A — cooperative case (frontmost throughout) =================
omni=$(omni_token)
call_tool a0_click_omnibox click "{\"target\":{\"kind\":\"window\",\"pid\":$GPID,\"window_id\":$GWID},\"element_token\":\"$omni\",\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}" >/dev/null
sleep 1
omni=$(omni_token)   # token refresh after the click's own snapshot
call_tool a1_type type_text "{\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"text\":\"localhost:$PORT/repro-after.html\",\"session\":\"$SESS\"}"
log_row A1 a1_type.json "fill omnibox (frontmost; insert onto selection)"
shot a1_after_type

call_tool a2_return_bg press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"session\":\"$SESS\"}"
wait_title "$GWID" "REPRO-AFTER" 3
T=$(title_of_wid "$GWID"); say "     title after A2: '$T'"; log_row A2 a2_return_bg.json "title=$T"
shot a2_after_return

if [ "$T" != "REPRO-AFTER" ]; then
  omni=$(omni_token)
  call_tool a3_return_fg_elem press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}"
  wait_title "$GWID" "REPRO-AFTER" 4
  T=$(title_of_wid "$GWID"); say "     title after A3: '$T'"; log_row A3 a3_return_fg_elem.json "title=$T"
fi
shot a3_after

# -- reset the page for Phase B (insert APPENDS: no replace flag exists) --
omni=$(omni_token)
call_tool r0_click_omnibox click "{\"target\":{\"kind\":\"window\",\"pid\":$GPID,\"window_id\":$GWID},\"element_token\":\"$omni\",\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}" >/dev/null
sleep 1
omni=$(omni_token)
call_tool r1_type type_text "{\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"text\":\"localhost:$PORT/repro-before.html\",\"session\":\"$SESS\"}" >/dev/null
call_tool r2_return_fg_elem press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}" >/dev/null
wait_title "$GWID" "REPRO-BEFORE" 4
say "-- reset done; title now: '$(title_of_wid "$GWID")' (omnibox buffer may hold concatenated text: inserts append) --"
log_row reset r1_type+r2_return "title=$(title_of_wid "$GWID")"

# ================= PHASE B — real-session case (target NOT frontmost) =================
osascript -e 'tell application "Finder" to activate'; sleep 1
FRONT=$(lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | sed -E 's/.*="([^"]*)".*/\1/')
if [ -z "$FRONT" ] || [[ "$FRONT" != com.apple.* ]]; then
  echo "ABORT: could not prove a non-Chrome app is frontmost after Finder activation (got: '$FRONT') — Phase B precondition unverifiable"; exit 1
fi
if [ "$FRONT" = "com.google.chrome" ]; then
  echo "ABORT: Chrome is still frontmost after Finder activation — Phase B precondition failed"; exit 1
fi
say "-- Phase B precondition: frontmost bundle='$FRONT' (not Chrome) --"
log_row B_precondition frontmost "$FRONT"

omni=$(omni_token)
call_tool b1_type type_text "{\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"text\":\"localhost:$PORT/repro-after.html\",\"session\":\"$SESS\"}"
log_row B1 b1_type.json "AX insert while unfocused"
shot b1_after_ax_type_unfocused

call_tool b2_return_bg press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"session\":\"$SESS\"}"
wait_title "$GWID" "REPRO-AFTER" 3
T=$(title_of_wid "$GWID"); say "     title after B2: '$T'"; log_row B2 b2_return_bg.json "title=$T"
shot b2_after_bg_return

call_tool b3_return_fg press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}"
wait_title "$GWID" "REPRO-AFTER" 4
T=$(title_of_wid "$GWID"); say "     title after B3: '$T'"; log_row B3 b3_return_fg.json "title=$T"
shot b3_after_fg_no_element

omni=$(omni_token)
call_tool b4_return_fg_elem press_key "{\"key\":\"return\",\"pid\":$GPID,\"window_id\":$GWID,\"element_token\":\"$omni\",\"session\":\"$SESS\",\"delivery_mode\":\"foreground\"}"
wait_title "$GWID" "REPRO-AFTER" 4
T=$(title_of_wid "$GWID"); say "     title after B4: '$T'"; log_row B4 b4_return_fg_elem.json "title=$T"
shot b4_final

echo
say "== artifacts in $OUT: raw <step>.json per call, *.png screenshots, run_manifest.tsv, run_output.txt (this transcript) =="
