#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-./scroll-verification}"
mkdir -p "$OUT"

command -v adb >/dev/null || { echo "adb not on PATH" >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "no device; start the emulator first" >&2; exit 1; }

read -r WIDTH HEIGHT <<<"$(adb shell wm size | tr -dc '0-9x' | tr 'x' ' ')"
CX=$((WIDTH / 2))
TOP=$((HEIGHT / 4))
BOTTOM=$((HEIGHT * 3 / 4))
SPAN=$((BOTTOM - TOP))
echo "screen ${WIDTH}x${HEIGHT} — dragging ${SPAN}px at x=${CX}"

shot() { adb exec-out screencap -p > "$OUT/$1.png"; }
hash_of() { md5sum "$OUT/$1.png" | cut -d' ' -f1; }

drag_down() { adb shell input swipe "$CX" "$TOP" "$CX" "$BOTTOM" "$1"; }
drag_up()   { adb shell input swipe "$CX" "$BOTTOM" "$CX" "$TOP" "$1"; }

pass=0; fail=0
check() {
  if [ "$2" != "$3" ]; then echo "  PASS  $1"; pass=$((pass + 1))
  else echo "  FAIL  $1 (screen did not change)"; fail=$((fail + 1)); fi
}

echo; echo "1. slow drag into the scrollback (2s over ${SPAN}px)"
shot 01-before
drag_down 2000; sleep 1
shot 02-after-slow-drag
check "a slow drag scrolls" "$(hash_of 01-before)" "$(hash_of 02-after-slow-drag)"

echo; echo "2. drag back down"
drag_up 2000; sleep 1
shot 03-after-return
check "the opposite drag scrolls back" "$(hash_of 02-after-slow-drag)" "$(hash_of 03-after-return)"

echo; echo "3. flick, then momentum after the finger is up"
shot 04-before-flick
drag_down 120
# Sampled immediately, then after the fling has had time to run on.
adb exec-out screencap -p > "$OUT/05-at-release.png"
sleep 1
shot 06-after-momentum
check "a flick scrolls" "$(hash_of 04-before-flick)" "$(hash_of 05-at-release)"
check "momentum keeps going after release" "$(hash_of 05-at-release)" "$(hash_of 06-after-momentum)"

echo; echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
