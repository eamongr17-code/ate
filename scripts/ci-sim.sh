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

# 1 + 3: the bar at rest and minimised, with each Feed icon candidate, light and dark.
for icon in feed newspaper utensilsCrossed compass globe layoutList; do
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

echo "== sheets"
python3 -m pip install --quiet pillow > /dev/null 2>&1
python3 - <<'PY'
import os
from PIL import Image, ImageDraw
OUT = os.path.join(os.getcwd(), 'ci-out')
SH, ST = f'{OUT}/shots', f'{OUT}/stills'
BAR = (0, 2300, 1206, 2622)
TOP = (0, 0, 1206, 560)

def sheet(rows, box, out, labels=None, gap=12):
    w, h = box[2] - box[0], box[3] - box[1]
    cols = max(len(r) for r in rows)
    left = 260 if labels else 0
    img = Image.new('RGB', (left + cols * (w + gap), len(rows) * (h + gap)), (240, 98, 63))
    draw = ImageDraw.Draw(img)
    for y, row in enumerate(rows):
        if labels:
            draw.text((12, y * (h + gap) + h // 2), labels[y], fill=(255, 255, 255))
        for x, path in enumerate(row):
            if os.path.exists(path):
                img.paste(Image.open(path).convert('RGB').crop(box), (left + x * (w + gap), y * (h + gap)))
    img.save(out)

icons = ['feed', 'newspaper', 'utensilsCrossed', 'compass', 'globe', 'layoutList']
sheet([[f'{SH}/icon-{i}-light-bar-rest.png', f'{SH}/icon-{i}-dark-bar-rest.png'] for i in icons], BAR,
      f'{ST}/feed-icon-candidates.png', labels=['users (today)', 'newspaper', 'utensils-crossed', 'compass',
                                                 'globe', 'layout-list'])
sheet([[f'{SH}/icon-feed-light-bar-minimised.png', f'{SH}/icon-feed-dark-bar-minimised.png']], BAR,
      f'{ST}/bar-minimised-fixed.png')
for screen in ['Feed', 'Journal', 'Search']:
    for mode in ['light', 'dark']:
        sheet([[f'{SH}/header{v}-{screen}-{mode}-{s}.png' for v in 'AB'] for s in ['compact', 'rest']], TOP,
              f'{ST}/compact-header-{screen}-{mode}-A-vs-B.png')
print(sorted(os.listdir(ST)))
PY
rm -rf $DD
echo R6-DONE
