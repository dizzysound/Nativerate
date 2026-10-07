#!/bin/bash
# Runs the whole loopback test: for each test file, record the loopback input with sox,
# play the file in Music (through Nativerate), then compare.
# Run it in Terminal (not over SSH: macOS gives SSH sessions silence from audio inputs).
# Usage: ./run_all.sh [rate ...]   e.g. ./run_all.sh 96000   (default: all rates)
set -u
cd "$(dirname "$0")"
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
DEV="${DEV:-Babyface Pro (73020432)}"
CH="${CH:-14}"
RATES="${*:-44100 48000 88200 96000 176400 192000}"
[ -d signals ] || python3 make_signal.py signals
mkdir -p rec
pair=""

for rate in $RATES; do
  for bits in 24 16; do
    ref="$PWD/signals/ref_${rate}_${bits}.wav"
    rec="rec/rec_${rate}_${bits}.wav"
    secs=$(python3 -c "import wave;w=wave.open('$ref');print(int(w.getnframes()/w.getframerate())+4)")
    echo "== $rate Hz $bits-bit"
    sox -q --buffer 262144 -t coreaudio "$DEV" -c "$CH" -b 24 -r "$rate" "$rec" trim 0 "$((secs + 2))" &
    sox_pid=$!
    sleep 2
    osascript -e "tell application \"Music\" to play (add POSIX file \"$ref\")" >/dev/null
    wait "$sox_pid"
    osascript -e 'tell application "Music" to stop' >/dev/null
    # Find the loopback channel pair once (the first pair where the marker is found).
    if [ -z "$pair" ]; then
      for l in $(seq 1 2 "$CH"); do
        out=$(python3 compare.py "$ref" "$rec" --channels "$l,$((l + 1))")
        case "$out" in *"marker not found"*) ;; *) pair="$l,$((l + 1))"; echo "loopback on channels $pair"; break ;; esac
      done
      [ -z "$pair" ] && { echo "FAIL: marker not found on any channel pair (check TotalMix loopback, fader 0 dB, Music volume max)"; continue; }
    fi
    python3 compare.py "$ref" "$rec" --channels "$pair"
  done
done
