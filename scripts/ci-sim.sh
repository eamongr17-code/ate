#!/bin/bash
# Round 6 compose exploration: records the Post loading-state variants (A, B) in light and dark,
# with stills, on the CI simulator. Temporary: removed before the PR is final.
set -u
DD=build/dd
OUT=ci-out
mkdir -p "$OUT"

xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
  -derivedDataPath "$DD" 2>&1 | grep -E "error:|\*\* TEST BUILD" || true

run() {
  local name=$1 variant=$2 appearance=$3
  xcrun simctl ui "$SIM_UDID" appearance "$appearance"
  local log="$OUT/$name.log" raw="$OUT/$name.mov" rec=""
  rm -rf "$OUT/$name.xcresult"
  TEST_RUNNER_ATE_R6_DRIVE=1 TEST_RUNNER_ATE_VARIANT=$variant \
  xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
    -derivedDataPath "$DD" -only-testing:AteUITests/PostingExploreDrive/testPosting \
    -resultBundlePath "$OUT/$name.xcresult" > "$log" 2>&1 &
  local xpid=$! start=0
  while kill -0 $xpid 2>/dev/null; do
    if [ -z "$rec" ] && grep -q "ATE-CUE" "$log" 2>/dev/null; then
      xcrun simctl io "$SIM_UDID" recordVideo --codec=h264 --force "$raw" > /dev/null 2>&1 &
      rec=$!
      start=$(date +%s)
    fi
    if [ -n "$rec" ] && [ "$rec" != done ] && [ $(( $(date +%s) - start )) -gt 17 ]; then
      kill -INT "$rec"; wait "$rec" 2>/dev/null; rec=done
    fi
    sleep 0.2
  done
  if [ -n "$rec" ] && [ "$rec" != done ]; then kill -INT "$rec"; wait "$rec" 2>/dev/null; fi
  grep -E "Test Case .*(passed|failed)|error:" "$log"
  if [ -f "$raw" ]; then
    avconvert --preset Preset960x540 --source "$raw" --output "$OUT/$name.mp4" --replace > /dev/null 2>&1 && rm -f "$raw"
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
