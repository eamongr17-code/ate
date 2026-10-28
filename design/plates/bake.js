// Renders the still of every plate the rows and grids use, from the same page the app loads live.
//
//   python3 design/plates/build.py && node design/plates/bake.js
//
// Needs Playwright's Chromium. Writes App/Resources/Plates/plate-<award>.png (360 px, transparent).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const DIR = path.join(ROOT, 'App/Resources/Plates');
const SIZE = 360;

(async () => {
  const browser = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 390, height: 390 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('file://' + path.join(DIR, 'plate-world.html'));
  await page.waitForFunction(() => window.ate, null, { timeout: 120000 });
  for (const id of await page.evaluate(() => window.ate.ids)) {
    const url = await page.evaluate(([id, size]) => window.ate.still(id, size, false), [id, SIZE]);
    fs.writeFileSync(path.join(DIR, `plate-${id}.png`), Buffer.from(url.split(',')[1], 'base64'));
    console.log(id);
  }
  await browser.close();
  if (errors.length) { console.error(errors); process.exit(1); }
})();
