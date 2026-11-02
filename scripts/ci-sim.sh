#!/bin/bash
# TEMPORARY diagnostic (flaky nightly, 2 Nov): loop ListsUITests until it fails, unfiltered on failure.
set -o pipefail
xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" -quiet 2>&1 | grep -E "error:" || true
xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "id=$SIM_UDID" \
  -resultBundlePath ci-out/result.xcresult -only-testing:AteUITests/ListsUITests \
  -test-iterations 20 -run-tests-until-failure 2>&1 \
  | grep -vE "MKCoreLocationProvider|^\s*$" \
  | grep -E -A60 "Test Case .*(passed|failed)|error:|\*\* TEST|[Pp]resent|in progress|detached|hierarchy" | cut -c1-400
