#!/bin/zsh
# Round 6 chrome explorations, on the CI simulator (sim.yml runs this with $SIM_UDID booted).
# Writes stills, recordings and comparison sheets into ci-out/. Temporary: removed before the PR is final.
set -u
OUT=$PWD/ci-out
SHOTS=$OUT/shots
mkdir -p $SHOTS $OUT/stills
U=$SIM_UDID
DD=$PWD/ci-dd

xcrun simctl status_bar $U override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

echo "== build-for-testing"
xcodebuild build-for-testing -project Ate.xcodeproj -scheme Ate -destination "id=$U" -derivedDataPath $DD \
  > $OUT/build.log 2>&1 || { tail -50 $OUT/build.log; exit 1; }

# drive <tag> <test> <light|dark> <record 0|1> [launch args...]
drive() {
  local tag=$1 test=$2 mode=$3 rec=$4
  shift 4
  xcrun simctl ui $U appearance $mode
  export TEST_RUNNER_R6_TAG=$tag TEST_RUNNER_R6_SHOTS=$SHOTS TEST_RUNNER_R6_ARGS="$*"
  local rp=""
  if [[ $rec == 1 ]]; then
    xcrun simctl io $U recordVideo --codec h264 --force $OUT/raw-$tag.mov > /dev/null 2>&1 &
    rp=$!
    sleep 1
  fi
  xcodebuild test-without-building -project Ate.xcodeproj -scheme Ate -destination "id=$U" -derivedDataPath $DD \
    -only-testing:AteUITests/R6ChromeDriveUITests/$test > $OUT/drive-$tag.log 2>&1
  echo "$tag: $(grep -cE 'Test Case.*passed' $OUT/drive-$tag.log) passed"
  if [[ -n $rp ]]; then
    kill -INT $rp; wait $rp
    avconvert --preset Preset960x540 --source $OUT/raw-$tag.mov --output $OUT/$tag.mov --replace > /dev/null 2>&1 \
      && rm -f $OUT/raw-$tag.mov
  fi
}

RUN_ICONS=${RUN_ICONS:-0}  # the icon candidates are captured (run 36370514674); headers only now
# 1 + 3: the bar at rest and minimised, with each Feed icon candidate, light and dark.
[[ $RUN_ICONS == 1 ]] && for icon in feed newspaper utensilsCrossed compass globe layoutList; do
  for mode in light dark; do
    drive "icon-$icon-$mode" testDriveBar $mode 0 -ate-r6-feed-icon $icon
  done
done

# 2: the compact header, A and B, on Feed, Journal and Search, light and dark, recorded.
for variant in A B; do
  for screen in Feed Journal Search; do
    for mode in light dark; do
      drive "header$variant-$screen-$mode" testDrive$screen $mode 1 -ate-r6-header $variant
    done
  done
done

# Sheets are built from ci-out/shots after download (the runner has no PIL).
rm -rf $DD
echo R6-DONE
