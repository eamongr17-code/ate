#!/bin/bash
# Round 6 compose exploration: records the Post loading-state variants (A, B) in light and dark,
# with stills, on the CI simulator. Temporary: removed before the PR is final.
#
# The whole test is recorded, then trimmed to the Post tap: the test log's own clock (the suite's
# start plus the tap's `t =`) against the recording's start says where the tap is in the movie.
set -u
DD=build/dd
OUT=ci-out
mkdir -p "$OUT"

xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
  -derivedDataPath "$DD" 2>&1 | grep -E "error:|\*\* TEST BUILD" || true

now() { python3 -c 'import time; print(time.time())'; }

run() {
  local name=$1 variant=$2 appearance=$3
  xcrun simctl ui "$SIM_UDID" appearance "$appearance"
  local log="$OUT/$name.log" raw="$OUT/$name.mov"
  rm -rf "$OUT/$name.xcresult"
  xcrun simctl io "$SIM_UDID" recordVideo --codec=h264 --force "$raw" > /dev/null 2>&1 &
  local rec=$!
  sleep 1
  local rec_start
  rec_start=$(now)
  TEST_RUNNER_ATE_R6_DRIVE=1 TEST_RUNNER_ATE_VARIANT=$variant \
  xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
    -derivedDataPath "$DD" -only-testing:AteUITests/PostingExploreDrive/testPosting \
    -resultBundlePath "$OUT/$name.xcresult" > "$log" 2>&1
  kill -INT "$rec"; wait "$rec" 2>/dev/null
  grep -E "Test Case .*(passed|failed)|error:" "$log"

  # Where the Post tap sits in the movie.
  local tap
  tap=$(python3 - "$log" "$rec_start" <<'PY'
import re, sys, time, datetime
log = open(sys.argv[1]).read()
rec_start = float(sys.argv[2])
suite = re.search(r"Test Case '.*testPosting\]' started at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", log) \
    or re.search(r"Test Suite 'Selected tests' started at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", log)
tap = re.search(r"t =\s+([\d.]+)s Tap \"composer\.post\"", log)
if not (suite and tap):
    print(0); sys.exit(0)
started = time.mktime(datetime.datetime.strptime(suite.group(1), "%Y-%m-%d %H:%M:%S.%f").timetuple()) \
    + float("0." + suite.group(1).split(".")[1])
print(max(0.0, started + float(tap.group(1)) - rec_start))
PY
)
  echo "$name: Post tap at ${tap}s into the recording"
  if [ -f "$raw" ]; then
    local from
    from=$(python3 -c "print(max(0.0, $tap - 2.0))")
    avconvert --preset Preset960x540 --source "$raw" --output "$OUT/$name.mp4" --replace \
      --start "$from" --duration 16 > /dev/null 2>&1 && rm -f "$raw"
    # Contact sheets: the tap and the hold (0.12s apart), then the hand-off and the receipt.
    swift scripts/ci-frames.swift "$OUT/$name.mp4" "$OUT/$name-sheet-hold.png" 1.6 0.12 40 2> /dev/null
    swift scripts/ci-frames.swift "$OUT/$name.mp4" "$OUT/$name-sheet-handoff.png" 5.5 0.25 40 2> /dev/null
  fi
  mkdir -p "$OUT/$name-shots"
  xcrun xcresulttool export attachments --path "$OUT/$name.xcresult" --output-path "$OUT/$name-shots" > /dev/null 2>&1
  python3 - "$OUT/$name-shots" "$name" <<'PY'
import json, os, sys
d, name = sys.argv[1], sys.argv[2]
try:
    manifest = json.load(open(os.path.join(d, "manifest.json")))
except Exception:
    sys.exit(0)
for test in manifest:
    for a in test.get("attachments", []):
        human = a["suggestedHumanReadableName"]
        src = os.path.join(d, a["exportedFileName"])
        if human.endswith(".png") and not human.startswith("Complete"):
            os.replace(src, os.path.join(os.path.dirname(d), f"{name}-{human.split('_')[0]}.png"))
PY
  rm -rf "$OUT/$name-shots" "$OUT/$name.xcresult"
}

run A-pill-light A light
run B-page-light B light
run A-pill-dark A dark
run B-page-dark B dark
ls -la "$OUT"
