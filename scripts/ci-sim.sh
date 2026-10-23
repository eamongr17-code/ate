#!/bin/bash
# The Simulator run's script (sim.yml): drives the glass headers in dark and light, records the
# screen, and prints a contact sheet of the top of each recording as base64 between markers, so
# the run's log alone carries the frames.
set -euo pipefail
: "${SIM_UDID:?}"
command -v ffmpeg >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install ffmpeg >/dev/null
mkdir -p ci-out
xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
  -derivedDataPath dd -quiet
for mode in dark light; do
  xcrun simctl ui "$SIM_UDID" appearance "$mode"
  xcrun simctl io "$SIM_UDID" recordVideo --codec h264 --force "ci-out/$mode.mp4" &
  rec=$!
  sleep 2
  TEST_RUNNER_HEADER_DRIVE=1 xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate \
    -destination "id=$SIM_UDID" -derivedDataPath dd -only-testing:AteUITests/HeaderScrollUITests \
    2>&1 | grep -E "Test Case .*(passed|failed|skipped)|error:" || true
  kill -INT "$rec"; wait "$rec" || true
  rm -rf "ci-out/f-$mode"; mkdir -p "ci-out/f-$mode"
  # The top 44% of the screen (status bar, header, the page under it), 6 frames a second.
  ffmpeg -v error -i "ci-out/$mode.mp4" -vf "fps=1,crop=iw:ih*0.32:0:0,scale=360:-2" "ci-out/f-$mode/%04d.png"
  n=$(ls "ci-out/f-$mode" | wc -l | tr -d ' ')
  rows=$(( (n + 5) / 6 ))
  ffmpeg -v error -framerate 1 -i "ci-out/f-$mode/%04d.png" -vf "tile=6x$rows" -frames:v 1 -q:v 11 \
    "ci-out/sheet-$mode.jpg"
  echo "frames=$n bytes=$(wc -c < "ci-out/sheet-$mode.jpg")"
  echo "==SHEET $mode BEGIN=="
  base64 -i "ci-out/sheet-$mode.jpg" -b 2000
  echo "==SHEET $mode END=="
done
