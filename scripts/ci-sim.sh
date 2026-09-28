#!/bin/bash
# Round 6 stills (Journal + Search lane): the date-range explorations A and B, light and dark, and
# "Your top dishes". Run by sim.yml with $SIM_UDID booted; writes PNGs to ci-out/. Temporary — removed
# before the PR is final.
set -uo pipefail
OUT=ci-out
mkdir -p "$OUT"
BUNDLE=com.eamongracias.ate

xcodebuild build -project Ate.xcodeproj -scheme Ate -configuration Debug \
  -destination "id=$SIM_UDID" -derivedDataPath build/dd 2>&1 \
  | grep -E "error:|\*\* BUILD" | tee "$OUT/build.log"
grep -q "BUILD SUCCEEDED" "$OUT/build.log" || { echo "build failed"; exit 1; }
APP=build/dd/Build/Products/Debug-iphonesimulator/Ate.app
[ -d "$APP" ] || { echo "no app built"; exit 1; }

xcrun simctl install "$SIM_UDID" "$APP"
xcrun simctl privacy "$SIM_UDID" grant location "$BUNDLE" || true
xcrun simctl privacy "$SIM_UDID" grant photos "$BUNDLE" || true
xcrun simctl location "$SIM_UDID" set -37.8136,144.9631 || true
xcrun simctl status_bar "$SIM_UDID" override --time 9:41 --batteryState charged --batteryLevel 100 || true

# shot <name> <light|dark> <seconds> [launch args...]
shot() {
  local name=$1 mode=$2 wait=$3
  shift 3
  xcrun simctl ui "$SIM_UDID" appearance "$mode"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE" 2>/dev/null
  xcrun simctl launch "$SIM_UDID" "$BUNDLE" -ate-ui-testing -ate-debug-signin "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$SIM_UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "shot $name"
}

# Sign in once, and let the first reads land.
shot warm light 20

for mode in light dark; do
  for v in A B; do
    shot "date-$v-journal-sheet-$mode" $mode 16 -ate-r6-date $v -ate-journal-filtered -ate-r6-window custom -ate-journal-filter-open
    shot "date-$v-search-sheet-$mode" $mode 16 -ate-r6-date $v -ate-open-search -ate-search-scope dishes \
      -ate-search-query pa -ate-search-filtered -ate-r6-window custom -ate-search-filter-open
  done
  shot "date-B-journal-sheet-preset-$mode" $mode 16 -ate-r6-date B -ate-journal-filtered -ate-r6-window preset -ate-journal-filter-open
  shot "date-journal-filtered-$mode" $mode 14 -ate-journal-filtered -ate-r6-window custom
  shot "date-search-filtered-$mode" $mode 14 -ate-open-search -ate-search-scope dishes -ate-search-query pa \
    -ate-search-filtered -ate-r6-window custom
  shot "date-saved-filtered-$mode" $mode 14 -ate-open-saved -ate-journal-filtered -ate-r6-window preset
  shot "you-top-dishes-$mode" $mode 14 -ate-open-you
done
# warm.png stays: it shows whether the staging sign-in landed.
ls "$OUT"
