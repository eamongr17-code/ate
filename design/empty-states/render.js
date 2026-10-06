// The empty-state drawings (Paper Trail, Eamon 2026-10-06): paper-trail.html is the source, this
// renders each scene at 1x/2x/3x (ink black, paper white, transparent), and split.py turns each
// render into the two template layers the app stacks (EmptyXInk / EmptyXPaper in Assets.xcassets).
//   NODE_PATH=$(npm root -g) node design/empty-states/render.js && python3 design/empty-states/split.py
const { chromium } = require('playwright');
const path = require('path');
const here = __dirname;
(async()=>{const b=await chromium.launch();
for (const scale of [1,2,3]) {
 const p=await b.newPage({viewport:{width:400,height:300},deviceScaleFactor:scale});
 await p.goto('file://'+path.join(here,'paper-trail.html'));await p.waitForTimeout(1200);
 const ids = await p.evaluate(()=>STATES.map(s=>s.id));
 for (const id of ids) {
  await p.evaluate((id)=>{
    const s = STATES.find(x=>x.id===id);
    const svg = art(s,false).replace('viewBox="0 0 160 120"','viewBox="-10 -10 180 140" width="231" height="180"');
    document.body.style.background='transparent'; document.documentElement.style.background='transparent';
    document.querySelector('.wrap').innerHTML = `<div id="cell" class="app" style="--i:#000;--p:#fff;width:231px;height:180px;background:transparent">${svg}</div>`;
    document.querySelector('.wrap').style.padding='0';
  }, id);
  await p.waitForTimeout(150);
  await p.locator('#cell').screenshot({path:`${here}/render/${id}@${scale}x.png`, omitBackground:true});
 }
 await p.close();
}
await b.close();})();
