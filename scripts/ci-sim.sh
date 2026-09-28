#!/bin/bash
# Round 6 detail lane, temporary (removed before the PR is final): profile and record opening dish
# and place pages on staging's seeded data, then run the lane's UI tests.
set -uo pipefail
mkdir -p ci-out
DD=build/dd
DEST="id=$SIM_UDID"
BUNDLE=com.eamongracias.ate

xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "$DEST" -derivedDataPath "$DD" -quiet \
  2>&1 | grep -E "error:" || true
# The Feed's city ask is not what is being measured.
xcrun simctl privacy "$SIM_UDID" grant location "$BUNDLE" || true

# 1. The profile, recorded.
xcrun simctl io "$SIM_UDID" recordVideo --codec h264 --force ci-out/detail-open.mov >/dev/null 2>&1 &
REC=$!
sleep 2
TEST_RUNNER_ATE_PROFILE=1 xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "$DEST" \
  -derivedDataPath "$DD" -only-testing:AteUITests/DetailProfileUITests -resultBundlePath ci-out/profile.xcresult \
  2>&1 | tee ci-out/profile.log | grep -E "PROFILE|Test Case .*(passed|failed|skipped)|error:"
kill -INT $REC
wait $REC 2>/dev/null
grep "PROFILE" ci-out/profile.log > ci-out/profile.txt || true
container=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE" data 2>/dev/null)
[ -n "$container" ] && cp "$container/Documents/detail-timings.txt" ci-out/ 2>/dev/null
cat ci-out/detail-timings.txt 2>/dev/null

# 2. The lane's UI tests (only on a branch that has them all).
if [ "${RUN_UI:-1}" = "1" ] && grep -q "testADishPageDrawsAtOnceFromTheRowThatOpenedIt" AteUITests/DetailRound5UITests.swift; then
  xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:AteUITests/DetailRound5UITests -resultBundlePath ci-out/ui.xcresult \
    2>&1 | tee ci-out/ui.log | grep -E "Test Case .*(passed|failed)|error:|\*\* TEST"
fi
exit 0
