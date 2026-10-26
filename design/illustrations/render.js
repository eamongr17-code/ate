// Renders every scene in kit.js into the app's empty-state assets.
// Each scene is drawn at 1x/2x/3x (ink black, paper white, transparent) on its 180 x 140 canvas, then
// split.py turns each render into the two template layers the app stacks (EmptyXInk / EmptyXPaper).
//   NODE_PATH=$(npm root -g) node design/illustrations/render.js && python3 design/illustrations/split.py
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const here = __dirname;
const K = require('./kit.js');
fs.mkdirSync(path.join(here, 'render'), { recursive: true });
(async () => {
  const b = await chromium.launch();
  for (const scale of [1, 2, 3]) {
    const p = await b.newPage({ viewport: { width: 400, height: 300 }, deviceScaleFactor: scale });
    await p.setContent(`<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Permanent+Marker&display=swap">
      <body style="margin:0;background:transparent"><div id="cell" style="--i:#000;--p:#fff;width:231px;height:180px"></div></body>`);
    await p.waitForTimeout(1200);
    for (const scene of K.SCENES) {
      await p.evaluate((svg) => { document.getElementById('cell').innerHTML = svg; }, K.svg(scene, { pad: 10, width: 231, height: 180 }));
      await p.waitForTimeout(100);
      await p.locator('#cell').screenshot({ path: `${here}/render/${scene.id}@${scale}x.png`, omitBackground: true });
    }
    await p.close();
  }
  await b.close();
})();
