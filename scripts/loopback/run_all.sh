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
#                       or 1 on macOS 26 only, where Music scales output by about 0.99999997.
#        CONTROL=neg    negative control, first rate at 24-bit only: the case must PASS at 0 dB,
#                       then you set the TotalMix fader to -0.1 dB when asked and the same case
#                       must exit 1 (samples differ). OK only if both hold.
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
  if [ "${MACOS_MAJOR:-0}" -eq 26 ]; then
    TOL=1
    echo "note: macOS $(sw_vers -productVersion): Music scales its output by ~0.99999997, so this run accepts <= 1 LSB (TOL=1)."
    echo "      A pass is then 'within tolerance', not bit-perfect. Use macOS 15 or earlier, or 27 or later, for a strict result."
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
      local t=3
      while [ "$(osascript -e 'tell application "Music" to player state as string')" = playing ]; do
        sleep 1; t=$((t + 1))
        if [ "$t" -gt "$(($2 + 30))" ]; then echo "Music still playing after timeout"; osascript -e 'tell application "Music" to stop'; return 1; fi
      done
      # The file is about $2 s minus the 5 s margin long; Music stopping much earlier means it did not play it.
      if [ "$t" -lt "$(($2 - 8))" ]; then echo "Music stopped after $t s, expected about $(($2 - 5)) s"; return 1; fi
      return 0 ;;
    *) echo "unknown PLAYER=$PLAYER"; return 1 ;;
  esac
}

pair=""
results=()   # "rate bits result"
failed=0
add() { results+=("$1|$2|$3"); }

# run_case rate bits: record + play + locate the pair + compare. Sets CASE_RC to the compare exit
# code (0 pass, 1 samples differ, 2 marker/format error) or CASE_ERR to a failure label.
run_case() {
  local rate=$1 bits=$2 ref rec secs
  CASE_RC=""; CASE_ERR=""; CASE_FMT=""
  ref="$PWD/signals/ref_${rate}_${bits}.wav"
  rec="rec/rec_${rate}_${bits}.wav"
  rm -f "$rec"   # a stale recording must never be compared
  # 5 s margin on top of the file: recorder start (2 s), Music start (3 s) and slack.
  secs=$(python3 -c "import wave;w=wave.open('$ref');print(int(w.getnframes()/w.getframerate())+5)")
  # Prime the DAC rate: Nativerate switches it when playback starts, and the recorder opens the
  # input at the case rate. Start playback, wait for the rate, stop, then record.
  if [ "$PLAYER" = music ]; then
    osascript -e "tell application \"Music\" to play (POSIX file \"$ref\")" >/dev/null
    ./recorder "$DEV" "$rate" --wait-rate 30; local prime_rc=$?
    osascript -e 'tell application "Music" to stop' >/dev/null
    if [ "$prime_rc" -ne 0 ]; then echo "FAIL: DAC did not switch to $rate Hz"; CASE_ERR="FAIL rate switch"; return; fi
  fi
  ./recorder "$DEV" "$rate" "$((secs + 5))" "$rec" "$bits" &
  local rec_pid=$!
  sleep 2
  play "$ref" "$secs"; local play_rc=$?
  wait "$rec_pid"; local rec_rc=$?
  if [ "$play_rc" -ne 0 ]; then echo "FAIL: playback failed"; CASE_ERR="FAIL playback"; return; fi
  # Format check result (3 = never integer, 4 = the device has no integer format) is kept, and the
  # sample compare below still runs, so one run reports both.
  CASE_FMT=""
  case "$rec_rc" in
    3) echo "FAIL: output stream format was never $rate Hz $bits-bit integer"; CASE_FMT="format FAIL"; rec_rc=0 ;;
    4) echo "note: device has no integer output format, format not checked"; CASE_FMT="format n/a"; rec_rc=0 ;;
  esac
  if [ "$rec_rc" -ne 0 ] || [ ! -s "$rec" ]; then echo "FAIL: recorder exit $rec_rc"; CASE_ERR="FAIL recorder exit $rec_rc"; return; fi
  # Find the loopback pair once: accept a pair only when compare.py explicitly says LOCATED.
  if [ -z "$pair" ]; then
    local nch l out
    nch=${CH:-$(python3 -c "import wavio;print(wavio.header('$rec')[1])")}
    for l in $(seq 1 2 "$((nch - 1))"); do
      out=$(python3 compare.py "$ref" "$rec" --channels "$l,$((l + 1))" --probe)
      case "$out" in LOCATED*) pair="$l,$((l + 1))"; echo "loopback on channels $pair of $nch"; break ;; esac
    done
    if [ -z "$pair" ]; then
      echo "FAIL: marker not found on any of $nch channels (check TotalMix loopback, fader 0 dB, Music volume max)"
      CASE_ERR="FAIL marker not found"; return
    fi
  fi
  python3 compare.py "$ref" "$rec" --channels "$pair" --tolerance "$TOL"; CASE_RC=$?
}

for rate in $RATES; do
  for bits in 24 16; do
    [ -n "$CONTROL" ] && { [ "$rate" = "${RATES%% *}" ] && [ "$bits" = 24 ] || continue; }
    echo "== $rate Hz $bits-bit"
    if [ -n "$CONTROL" ]; then
      # Negative control, two steps in one run: first locate the pair and PASS at 0 dB (so the
      # setup is proven good), then you drop the fader to -0.1 dB and compare must exit 1
      # (samples differ). Exit 2 (marker or format error) is not a valid control.
      echo "Step 1: TotalMix fader at 0 dB. The case must PASS."
      run_case "$rate" "$bits"
      if [ -n "$CASE_ERR" ]; then add "$rate" "$bits" "$CASE_ERR (step 1, 0 dB)"; failed=1; continue; fi
      if [ "$CASE_RC" -ne 0 ]; then add "$rate" "$bits" "CONTROL INVALID: no PASS at 0 dB (compare exit $CASE_RC)"; failed=1; continue; fi
      read -r -p "Step 2: set the TotalMix output fader to -0.1 dB, then press Return: " _
      run_case "$rate" "$bits"
      read -r -p "Put the fader back to 0 dB, then press Return: " _
      if [ -n "$CASE_ERR" ]; then add "$rate" "$bits" "$CASE_ERR (step 2, -0.1 dB)"; failed=1; continue; fi
      case "$CASE_RC" in
        1) add "$rate" "$bits" "control OK: PASS at 0 dB, samples differ at -0.1 dB" ;;
        0) add "$rate" "$bits" "CONTROL BROKEN: passed with the fader at -0.1 dB"; failed=1 ;;
        *) add "$rate" "$bits" "CONTROL INVALID: compare exit $CASE_RC at -0.1 dB"; failed=1 ;;
      esac
      continue
    fi
    run_case "$rate" "$bits"
    fmt=""; [ -n "$CASE_FMT" ] && fmt="; $CASE_FMT"
    [ "$CASE_FMT" = "format FAIL" ] && failed=1
    if [ -n "$CASE_ERR" ]; then add "$rate" "$bits" "$CASE_ERR$fmt"; failed=1
    elif [ "$CASE_RC" -eq 0 ]; then add "$rate" "$bits" "samples PASS$([ "$TOL" -gt 0 ] && echo " (<= $TOL LSB)")$fmt"
    else add "$rate" "$bits" "samples FAIL (compare exit $CASE_RC)$fmt"; failed=1; fi
  done
done

echo
echo "== Summary (player $PLAYER, tolerance $TOL LSB${CONTROL:+, negative control})"
printf '%-8s %-5s %s\n' rate bits result
for r in "${results[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-8s %-5s %s\n' "$a" "$b" "$c"; done
exit "$failed"
