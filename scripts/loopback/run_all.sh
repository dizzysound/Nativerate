#!/bin/bash
# Runs the loopback test: for each test file, record the loopback input with ./recorder, play the
# file through Music into the Nativerate device, then compare. Prints a summary table and exits
# non-zero if any case failed or was not run.
#
# Run it in Terminal (not over SSH: macOS gives SSH sessions silence from audio inputs).
# Before you start (see README): Nativerate running with Exclusive Mode on and Music's output set
# to the device, Music volume at max, Sound Check/EQ/Sound Enhancer off, TotalMix loopback at 0 dB.
#
# Usage: ./run_all.sh [rate ...]      default: all rates, 24-bit then 16-bit
# Env:   DEV="Babyface Pro"   input device (also the output device whose format is asserted)
#        PLAYER=music|manual|afplay   music (default) plays via Music; manual asks you to press
#                                     play in Music; afplay bypasses Nativerate and tests nothing
#                                     of it (harness smoke test only)
#        TOL=N          accept up to N LSB deviation, reported as "not bit-perfect". Default 0,
#                       or 1 on macOS 26+ where Music scales output by about 0.99999997.
#        CONTROL=neg    negative control: set the TotalMix fader to -0.1 dB first. The case must
#                       FAIL; the run is OK only if it does.
#        CH=N           input channel count override (default: read from the recording)
set -u
cd "$(dirname "$0")"
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
DEV="${DEV:-Babyface Pro}"
PLAYER="${PLAYER:-music}"
CONTROL="${CONTROL:-}"
RATES="${*:-44100 48000 88200 96000 176400 192000}"
MACOS_MAJOR=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
if [ -z "${TOL:-}" ]; then
  if [ "${MACOS_MAJOR:-0}" -ge 26 ]; then
    TOL=1
    echo "note: macOS $(sw_vers -productVersion): Music scales its output by ~0.99999997, so this run accepts <= 1 LSB (TOL=1)."
    echo "      A pass is then 'within tolerance', not bit-perfect. Use macOS 25 or earlier for a strict result."
  else
    TOL=0
  fi
fi
[ "$PLAYER" = afplay ] && echo "warning: PLAYER=afplay does not go through Music or Nativerate. Results do not test Nativerate."
[ -n "$CONTROL" ] && [ "$CONTROL" != neg ] && { echo "CONTROL must be 'neg' or empty"; exit 2; }

[ -d signals ] || python3 make_signal.py signals || exit 1
if [ ! -x recorder ] || [ rec.swift -nt recorder ]; then swiftc -O rec.swift -o recorder || exit 1; fi
mkdir -p rec

play() { # file duration_seconds
  case "$PLAYER" in
    afplay) afplay "$1" ;;
    manual) read -r -p "Play $(basename "$1") in Music to the Nativerate device, then press Return when it has ended: " _ ;;
    music)
      osascript -e "tell application \"Music\" to play (POSIX file \"$1\")" || return 1
      sleep 3
      local t=0
      while [ "$(osascript -e 'tell application "Music" to player state as string')" = playing ]; do
        sleep 1; t=$((t + 1)); [ "$t" -gt "$(($2 + 30))" ] && { echo "Music still playing after timeout"; osascript -e 'tell application "Music" to stop'; return 1; }
      done ;;
    *) echo "unknown PLAYER=$PLAYER"; return 1 ;;
  esac
}

pair=""
results=()   # "rate bits result"
failed=0
add() { results+=("$1|$2|$3"); }

for rate in $RATES; do
  for bits in 24 16; do
    [ -n "$CONTROL" ] && { [ "$rate" = "${RATES%% *}" ] && [ "$bits" = 24 ] || continue; }
    ref="$PWD/signals/ref_${rate}_${bits}.wav"
    rec="rec/rec_${rate}_${bits}.wav"
    echo "== $rate Hz $bits-bit"
    rm -f "$rec"   # a stale recording must never be compared
    secs=$(python3 -c "import wave;w=wave.open('$ref');print(int(w.getnframes()/w.getframerate())+4)")
    ./recorder "$DEV" "$rate" "$((secs + 2))" "$rec" "$bits" &
    rec_pid=$!
    sleep 2
    play "$ref" "$secs"; play_rc=$?
    wait "$rec_pid"; rec_rc=$?
    if [ "$play_rc" -ne 0 ]; then echo "FAIL: playback failed"; add "$rate" "$bits" "FAIL playback"; failed=1; continue; fi
    if [ "$rec_rc" -eq 3 ]; then echo "FAIL: output stream format is not $rate Hz $bits-bit integer"; add "$rate" "$bits" "FAIL output format"; failed=1; continue; fi
    if [ "$rec_rc" -ne 0 ] || [ ! -s "$rec" ]; then echo "FAIL: recorder exit $rec_rc"; add "$rate" "$bits" "FAIL recorder exit $rec_rc"; failed=1; continue; fi
    # Find the loopback pair once: accept a pair only when compare.py explicitly says LOCATED.
    if [ -z "$pair" ]; then
      nch=${CH:-$(python3 -c "import wavio;print(wavio.header('$rec')[1])")}
      for l in $(seq 1 2 "$((nch - 1))"); do
        out=$(python3 compare.py "$ref" "$rec" --channels "$l,$((l + 1))" --probe)
        case "$out" in LOCATED*) pair="$l,$((l + 1))"; echo "loopback on channels $pair of $nch"; break ;; esac
      done
      if [ -z "$pair" ]; then
        echo "FAIL: marker not found on any of $nch channels (check TotalMix loopback, fader 0 dB, Music volume max)"
        if [ -n "$CONTROL" ]; then add "$rate" "$bits" "control: failed as expected"; else add "$rate" "$bits" "FAIL marker not found"; failed=1; fi
        continue
      fi
    fi
    python3 compare.py "$ref" "$rec" --channels "$pair" --tolerance "$TOL"; rc=$?
    if [ -n "$CONTROL" ]; then
      if [ "$rc" -ne 0 ]; then add "$rate" "$bits" "control OK: failed as expected"
      else add "$rate" "$bits" "CONTROL BROKEN: passed with the fader at -0.1 dB"; failed=1; fi
    elif [ "$rc" -eq 0 ]; then add "$rate" "$bits" "PASS$([ "$TOL" -gt 0 ] && echo " (<= $TOL LSB)")"
    else add "$rate" "$bits" "FAIL compare exit $rc"; failed=1; fi
  done
done

echo
echo "== Summary (player $PLAYER, tolerance $TOL LSB${CONTROL:+, negative control})"
printf '%-8s %-5s %s\n' rate bits result
for r in "${results[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-8s %-5s %s\n' "$a" "$b" "$c"; done
exit "$failed"
