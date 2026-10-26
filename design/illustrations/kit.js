// Ate's illustration kit: "Paper Trail", the hand-drawn ink drawings over every empty state.
//
// The grammar, in one line: SOMETHING PRINTED MEETS SOMETHING EATEN, AND ONE THING IS UP TO NO GOOD.
// Every drawing pairs one thing from the docket's world (a docket, a spike, a rail, a menu card)
// with one from the table's (a fork, a plate, an olive, a ring left by a glass), plus at most one
// wink: the bit of mischief that tells you what kind of empty this is. That is BRAND.md's "tension
// between the mess of food and the structure of receipts", drawn small.
//
// The hand: one marker (outline 3.6, detail 2, hatching 1.6, round caps), on a 160 x 120 stage,
// bent by one wobble filter. Two inks only: ink (`--i`, the app's foreground) and paper (`--p`, the
// slip colour). Hatching at -35 degrees does every fill a colour would; solid ink only on things
// smaller than about 20 units. Marker lettering only for numbers and short caps (`#0001`, `1 2 3`).
//
// Parts are plain functions returning SVG; a scene is data: which parts, where, at what tilt. A new
// empty state is a new entry in SCENES. render.js turns SCENES into the app's assets.
(function (root) {
  const K = {};
  K.STAGE = { w: 160, h: 120 };
  K.W = { outline: 3.6, detail: 2, hatch: 1.6 };

  // Seeded randomness, so a drawing is identical on every render.
  let seed = 11;
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  K.reseed = (s) => { seed = s; };
  let uid = 0;

  const I = 'var(--i)';
  const P = 'var(--p)';
  const S = (w = K.W.outline) => `stroke="${I}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"`;
  const n1 = (v) => +v.toFixed(1);

  // ---------- The hand's marks ----------

  /** A blank line on a docket: short dashes, a little uneven. */
  const blanks = (x1, x2, y) => {
    let o = '';
    for (let x = x1; x < x2 - 3; x += 7) {
      o += `<line x1="${x}" y1="${y}" x2="${n1(x + 3 + rnd() * 1.5)}" y2="${n1(y + (rnd() - 0.5))}" ${S(K.W.detail)}/>`;
    }
    return o;
  };
  /** Hatching clipped to a shape: the drawings' answer to a fill. */
  const hatch = (d, gap = 4.5, ang = -35) => {
    const id = 'h' + uid++;
    const k = Math.tan((ang * Math.PI) / 180);
    let l = '';
    for (let x = -200; x < 260; x += gap) l += `<line x1="${x}" y1="-100" x2="${n1(x - 200 * k)}" y2="100" ${S(K.W.hatch)}/>`;
    return `<clipPath id="${id}"><path d="${d}"/></clipPath><g clip-path="url(#${id})">${l}</g>`;
  };
  /** Marker lettering: numbers and short caps only. */
  const marker = (x, y, t, s = 10, a = 0) =>
    `<text x="${x}" y="${y}" text-anchor="middle" font-family="Permanent Marker, cursive" font-size="${s}" fill="${I}" transform="rotate(${a} ${x} ${y})">${t}</text>`;
  /** The torn foot every docket has: teeth fitted to its width, run right to left. */
  const teeth = (w, d = 6) => {
    const n = Math.max(2, Math.round(w / 12));
    const t = w / n;
    return Array.from({ length: n }, () => `l${n1(-t / 2)} ${d} ${n1(-t / 2)} ${-d}`).join(' ');
  };
  const paperPath = (d, w = K.W.outline) => `<path d="${d}" fill="${P}" ${S(w)}/>`;
  const inkPath = (d, w = K.W.outline) => `<path d="${d}" fill="${I}" ${S(w)}/>`;
  const line = (d, w = K.W.outline) => `<path d="${d}" fill="none" ${S(w)}/>`;

  K.marks = { blanks, hatch, marker, teeth, paperPath, inkPath, line, S };

  // ---------- Parts ----------
  // Each part draws in its own box from (0,0) and reports it; a scene places it with x, y, r
  // (degrees, about the box's centre) and s (scale).

  const PARTS = {};
  const part = (name, about, world, box, draw) => { PARTS[name] = { name, about, world, box, draw }; };

  // The docket's world: paper, printed or about to be.

  part('docket', 'A docket: paper with a torn foot. Blank dashes where print would go; an optional order number, numbered lines, or a bite out of its corner.', 'paper',
    (o) => [o.w || 72, (o.h || 76) + 6],
    (o) => {
      const w = o.w || 72, h = o.h || 76;
      let top = `M0 0 H${w}`;
      if (o.bite) {
        // Three bites' worth of scallops out of the top-right corner, then down the side.
        const b = o.bite === true ? 30 : o.bite;
        const r = b / 3.4;
        top = `M0 0 H${w - b} A${n1(r)} ${n1(r)} 0 0 0 ${n1(w - b * 0.58)} ${n1(b * 0.24)} A${n1(r)} ${n1(r)} 0 0 0 ${n1(w - b * 0.26)} ${n1(b * 0.56)} A${n1(r)} ${n1(r)} 0 0 0 ${w} ${b}`;
      }
      let o2 = paperPath(`${top} V${h} ${teeth(w)} Z`);
      let y = 14;
      if (o.number) { o2 += marker(w / 2, 16, o.number, 10, -2); y = 30; }
      const lines = o.lines ?? 3;
      for (let k = 0; k < lines; k++) {
        const ly = y + k * (o.gap || 11);
        if (o.numbered) {
          o2 += marker(11, ly + 3, String(k + 1), 10);
          o2 += blanks(20, w - 10 - (k === lines - 1 ? 8 : 0), ly);
        } else {
          o2 += blanks(10, w - 10 - (k % 3 === 2 ? 14 : 0) - (o.bite && k === 0 ? 22 : 0), ly);
        }
      }
      return o2;
    });

  part('slot', "The printer's mouth: the bar a docket feeds out of.", 'paper',
    (o) => [o.w || 110, 13],
    (o) => `<rect x="0" y="0" width="${o.w || 110}" height="13" rx="6" fill="${I}" ${S()}/>`);

  part('spike', 'An order spike: a weighted base and one long pin, nothing on it.', 'paper',
    () => [76, 96],
    () => line('M38 88 V8') + line('M36 8 L38 2', 2.6) +
      `<path d="M2 90 q36 -14 72 0 q-36 14 -72 0 Z" fill="${I}" ${S()}/>` +
      `<path d="M18 88 q11 -4 20 -4" fill="none" stroke="${P}" stroke-width="2" stroke-linecap="round"/>`);

  part('rail', 'The ticket rail over a kitchen pass, its clips hanging empty.', 'paper',
    (o) => [o.w || 140, 26],
    (o) => {
      const w = o.w || 140;
      const n = o.clips || 4;
      let c = '';
      for (let k = 0; k < n; k++) {
        const cx = (w / (n + 1)) * (k + 1);
        c += `<path d="M${n1(cx - 4)} 12 h8 l-1 10 h-6 Z" fill="${I}" ${S(2)}/>`;
      }
      return c + `<rect x="0" y="0" width="${w}" height="12" rx="3" fill="${P}" ${S()}/>` +
        `<circle cx="10" cy="6" r="2.4" fill="${I}"/><circle cx="${w - 10}" cy="6" r="2.4" fill="${I}"/>`;
    });

  part('tent', 'A table-number card, folded and standing, its number not written yet.', 'paper',
    () => [30, 32],
    () => paperPath('M4 30 L15 2 L26 30 Z') + paperPath('M15 2 L28 6 L26 30', 2.4) + blanks(10, 21, 20));

  part('plane', 'A docket folded into a paper plane, torn foot and all.', 'paper',
    () => [64, 34],
    () => paperPath('M0 14 L64 2 L22 34 Z') + paperPath('M0 14 L64 2 L26 20 Z') +
      line('M26 20 L22 34', 2.4) + line('M6 16 l4 3 4 -3 4 3', 2));

  // The table's world: what was eaten, or is about to be.

  part('fork', 'A fork, four tines.', 'food',
    () => [14, 58],
    () => paperPath('M1 14 V20 Q1 27 7 27 Q13 27 13 20 V14') +
      line('M7 27 V56') + line('M1 2 V14 M5 2 V14 M9 2 V14 M13 2 V14', 2.4));

  part('knife', 'A table knife.', 'food',
    () => [12, 58],
    () => paperPath('M3 2 Q11 6 10 30 H3 Z') + line('M6.5 30 V56'));

  part('chopsticks', 'A pair of chopsticks, resting.', 'food',
    () => [70, 12],
    () => line('M2 4 L68 2', 3) + line('M2 10 L68 9', 3));

  part('olive', 'One cocktail olive, pimento and all.', 'food',
    () => [24, 18],
    () => `<ellipse cx="12" cy="9" rx="11" ry="8" fill="${P}" ${S()}/><circle cx="4.5" cy="9" r="3.4" fill="${I}"/>` + line('M12 14 q4 1 7 -2', 1.8));

  part('ring', 'The ring a glass leaves on paper: broken, uneven, unmistakable.', 'food',
    (o) => [2 * (o.r || 13) + 4, 2 * (o.r || 13) + 4],
    (o) => {
      const r = o.r || 13, c = r + 2;
      return `<circle cx="${c}" cy="${c}" r="${r}" fill="none" ${S(2.2)} stroke-dasharray="${n1(r * 2.4)} 4 ${n1(r * 1.2)} 6 ${n1(r * 2.2)} 3"/>` +
        `<circle cx="${c}" cy="${c}" r="${r - 3}" fill="none" ${S(1.4)} stroke-dasharray="${n1(r * 1.6)} 9 ${n1(r * 0.9)} 14"/>`;
    });

  part('crumbs', 'A few crumbs.', 'food',
    (o) => [o.spread || 24, 10],
    (o) => {
      const n = o.n || 4, w = o.spread || 24;
      let c = '';
      for (let k = 0; k < n; k++) c += `<circle cx="${n1((w / n) * (k + 0.5) + (rnd() - 0.5) * 3)}" cy="${n1(5 + (rnd() - 0.5) * 6)}" r="${n1(1.4 + rnd() * 1.3)}" fill="${I}"/>`;
      return c;
    });

  part('plate', 'A clean plate, seen from the table: rim and well.', 'food',
    (o) => [o.w || 84, (o.w || 84) * 0.42],
    (o) => {
      const w = o.w || 84, h = w * 0.42;
      return `<ellipse cx="${w / 2}" cy="${n1(h / 2)}" rx="${w / 2 - 2}" ry="${n1(h / 2 - 2)}" fill="${P}" ${S()}/>` +
        `<ellipse cx="${w / 2}" cy="${n1(h / 2 + 1)}" rx="${n1(w * 0.3)}" ry="${n1(h * 0.27)}" fill="none" ${S(K.W.detail)}/>`;
    });

  part('bowl', 'A bowl of noodle soup, broth hatched. Drawn as back and front so something can land in it.', 'food',
    () => [84, 46],
    (o) => {
      const back = `<ellipse cx="42" cy="12" rx="40" ry="10" fill="${P}" ${S()}/>` +
        hatch('M8 12 a34 7 0 0 0 68 0 a34 7 0 0 0 -68 0 Z', 4) + line('M2 12 A40 10 0 0 1 82 12');
      const front = paperPath('M2 12 Q6 46 42 46 Q78 46 82 12 A40 10 0 0 1 2 12 Z') +
        line('M12 18 q4 -6 8 0 t8 0 M50 20 q4 -6 8 0 t8 0', 2);
      return o.half === 'back' ? back : o.half === 'front' ? front : back + front;
    });

  part('napkin', 'A folded gingham napkin: the restaurant cloth, checked in hatching.', 'food',
    (o) => [o.w || 30, o.h || 52],
    (o) => {
      const w = o.w || 30, h = o.h || 52;
      const d = `M4 0 H${w} L${w - 4} ${h} H0 Z`;
      let v = '';
      for (let x = 2; x < w; x += 12) v += `M${x} 0 h6 v${h} h-6 Z `;
      for (let y = 4; y < h; y += 12) v += `M0 ${y} h${w} v6 h${-w} Z `;
      return paperPath(d) + hatch(v, 4.2, 45) + `<path d="${d}" fill="none" ${S()}/>`;
    });

  part('takeaway', 'A takeaway pail, folded shut, wire handle up: dinner for later.', 'food',
    () => [44, 50],
    () => paperPath('M4 16 L10 48 H34 L40 16 Z') + paperPath('M4 16 L12 6 H32 L40 16 Z') +
      line('M14 6 L22 16 L30 6', 2.2) + line('M8 18 Q22 -14 36 18', 2.4) + line('M22 26 v8', 2));

  part('photo', 'An instant photo: a white border, a fat chin, and whatever was in front of the lens.', 'paper',
    () => [54, 62],
    (o) => paperPath('M0 0 H54 V62 H0 Z') + `<rect x="6" y="6" width="42" height="40" fill="none" ${S(K.W.detail)}/>` +
      (o.inside === 'plate' ? `<ellipse cx="27" cy="28" rx="15" ry="7" fill="none" ${S(K.W.detail)}/><ellipse cx="27" cy="28" rx="8" ry="3.6" fill="none" ${S(1.4)}/>` : hatch('M6 6 H48 V46 H6 Z', 4)));

  // The wink: one small thing up to no good.

  part('pencil', 'A pencil, sharpened, waiting for your words.', 'wink',
    () => [56, 14],
    () => paperPath('M8 1 h34 v12 h-34 Z') + paperPath('M42 1 l12 6 -12 6 Z') +
      `<path d="M50 5 l4 2 -4 2 Z" fill="${I}"/>` + paperPath('M8 1 h-7 v12 h7') + line('M4 2 V12', 2));

  part('bookmark', 'The save ribbon, notched.', 'wink',
    () => [18, 38],
    () => inkPath('M0 0 h18 v38 l-9 -8 -9 8 Z'));

  part('clip', 'The clip a docket hangs from.', 'wink',
    () => [24, 12],
    (o) => `<path d="M0 0 h24 v12 h-24 Z" fill="${I}" ${S()}/>`);

  part('fly', 'A fly, and the loop it just flew.', 'wink',
    () => [70, 34],
    () => `<path d="M2 32 q14 -16 26 -4 t26 -6 q8 -6 12 -14" fill="none" stroke="${I}" stroke-width="1.8" stroke-dasharray="2 4" stroke-linecap="round"/>` +
      `<g transform="translate(62 8) rotate(-30)"><ellipse cx="0" cy="0" rx="5" ry="3.5" fill="${I}" ${S(2)}/>` +
      `<path d="M-1 -2 q-5 -9 -9 -3 q2 4 9 3 M1 -2 q3 -9 8 -5 q-2 4 -8 5" fill="${P}" ${S(1.6)}/></g>`);

  part('zzz', 'Asleep.', 'wink',
    () => [22, 22],
    () => marker(8, 20, 'z', 11, 8) + marker(17, 9, 'z', 8, 8));

  part('lens', 'A magnifying glass, pulling a face at what it found.', 'wink',
    () => [56, 56],
    () => line('M36 36 L52 52', 7) + `<circle cx="22" cy="22" r="20" fill="${P}" ${S(3.8)}/>` +
      line('M14 18 v4 M30 17 v4', 3) + line('M15 30 L30 29', 2.8));

  part('bell', 'The counter bell. Nobody has rung it.', 'wink',
    () => [64, 40],
    () => `<rect x="0" y="31" width="64" height="8" rx="4" fill="${P}" ${S()}/>` +
      paperPath('M9 31 Q9 11 32 11 Q55 11 55 31 Z') + hatch('M40 31 Q52 26 49 15 Q55 21 55 31 Z', 3.4) +
      line('M9 31 Q9 11 32 11 Q55 11 55 31') + line('M32 11 V4', 3) +
      `<rect x="26" y="0" width="12" height="4" rx="2" fill="${I}" ${S(2)}/>` + line('M17 24 Q19 17 26 15', 2));

  part('splash', 'Drops, flying.', 'wink',
    () => [40, 20],
    () => line('M4 18 l-4 -6 M10 10 l-2 -8 M30 10 l3 -8 M36 18 l4 -6', 2.6));

  part('streaks', 'Speed: where something just flew from.', 'wink',
    () => [30, 18],
    () => line('M0 2 h18 M6 9 h24 M2 16 h14', 2.2));

  part('sparkle', 'A shine: spotless.', 'wink',
    () => [16, 16],
    () => line('M8 0 V16 M0 8 H16', 2.4) + line('M3 3 L13 13 M13 3 L3 13', 1.2));

  K.PARTS = PARTS;

  // ---------- Scenes ----------
  // One per KIND of empty, never per screen: the same situation looks the same wherever it happens.

  K.SCENES = [
    {
      id: 'journal', asset: 'Journal', kind: 'Your record has nothing yet',
      idea: 'Docket #0001 feeding out of the printer, every line blank, the pencil and a fork laid down beside it.',
      seed: 46,
      parts: [
        ['docket', { x: 40, y: 22, w: 84, h: 70, number: '#0001', lines: 3 }],
        ['slot', { x: 25, y: 13 }],
        ['fork', { x: 20, y: 70, r: -62, s: 0.82 }],
        ['pencil', { x: 100, y: 78, r: -38 }],
      ],
    },
    {
      id: 'lists', asset: 'Lists', kind: 'No lists',
      idea: "An order spike with nothing on it but the olive from somebody's martini.",
      seed: 53,
      parts: [
        ['spike', { x: 42, y: 12 }],
        ['olive', { x: 63, y: 44, r: -10, s: 1.45 }],
        ['docket', { x: 100, y: 58, w: 36, h: 32, lines: 2, r: 8 }],
      ],
    },
    {
      id: 'list', asset: 'List', kind: 'A list, or a pick, with nothing on it',
      idea: 'A numbered docket clipped at the top, three blank lines, and the ring a glass left on it.',
      seed: 60,
      parts: [
        ['docket', { x: 44, y: 18, w: 72, h: 76, numbered: true, lines: 3, gap: 16 }],
        ['clip', { x: 68, y: 10 }],
        ['ring', { x: 92, y: 60, r: 15 }],
      ],
    },
    {
      id: 'saved', asset: 'Saved', kind: 'Nothing kept for later',
      idea: 'A blank docket with the save ribbon on it, and a takeaway pail beside it: dinner, for later.',
      seed: 67,
      parts: [
        ['docket', { x: 30, y: 14, w: 72, h: 78, lines: 4 }],
        ['bookmark', { x: 92, y: 6 }],
        ['takeaway', { x: 102, y: 46, r: 6, s: 1.15 }],
      ],
    },
    {
      id: 'rail', asset: 'Rail', kind: 'Nobody has written here yet',
      idea: 'The kitchen ticket rail with every clip empty, and a fly doing laps.',
      seed: 74,
      parts: [
        ['rail', { x: 10, y: 28, w: 140, clips: 4 }],
        ['fly', { x: 52, y: 66 }],
      ],
    },
    {
      id: 'setting', asset: 'Setting', kind: 'Nothing eaten here yet',
      idea: "A clean place setting on a gingham napkin, the table card unwritten, the plate so clean it shines.",
      seed: 81,
      parts: [
        ['tent', { x: 104, y: 26, s: 0.9 }],
        ['napkin', { x: 14, y: 52, w: 28, h: 50 }],
        ['fork', { x: 21, y: 52, s: 0.8 }],
        ['plate', { x: 46, y: 60, w: 76 }],
        ['knife', { x: 128, y: 52, s: 0.8 }],
        ['sparkle', { x: 50, y: 52, s: 0.8 }],
      ],
    },
    {
      id: 'bell', asset: 'Bell', kind: 'Nothing new',
      idea: 'The counter bell, unrung, asleep on the pass beside a blank docket.',
      seed: 88,
      parts: [
        ['docket', { x: 22, y: 34, w: 44, h: 50, lines: 3, r: -6 }],
        ['bell', { x: 62, y: 50, s: 1.15 }],
        ['zzz', { x: 120, y: 28 }],
      ],
    },
    {
      id: 'search', asset: 'Search', kind: 'Nothing matched',
      idea: 'The lens went over every docket and found one crumb.',
      seed: 95,
      parts: [
        ['docket', { x: 26, y: 12, w: 60, h: 80, lines: 4 }],
        ['crumbs', { x: 58, y: 70, n: 2, spread: 10, s: 1.3 }],
        ['lens', { x: 78, y: 50 }],
      ],
    },
    {
      id: 'unplugged', asset: 'Unplugged', kind: "Couldn't reach Ate",
      idea: 'The order went out as a paper plane and landed in the soup.',
      seed: 102,
      parts: [
        ['streaks', { x: 14, y: 24, r: 44 }],
        ['bowl', { x: 42, y: 70, half: 'back' }],
        ['plane', { x: 38, y: 47, r: 44, s: 1.1 }],
        ['bowl', { x: 42, y: 70, half: 'front' }],
        ['splash', { x: 50, y: 58, s: 1.1 }],
      ],
    },
    {
      id: 'torn', asset: 'Torn', kind: 'It is gone',
      idea: 'A docket with a bite out of it. Somebody ate that.',
      seed: 109,
      parts: [
        ['docket', { x: 44, y: 14, w: 72, h: 78, lines: 4, bite: 34, number: '#0412' }],
        ['crumbs', { x: 112, y: 28, n: 3, spread: 22, r: 30 }],
      ],
    },
    {
      id: 'photos', asset: 'Photos', kind: 'No meals in your photos', optional: true,
      idea: 'Two instant photos: one of the dark, one of a plate with nothing on it.',
      seed: 116,
      parts: [
        ['photo', { x: 40, y: 24, r: -10 }],
        ['photo', { x: 70, y: 30, r: 7, inside: 'plate' }],
        ['fork', { x: 120, y: 54, r: 24, s: 0.8 }],
      ],
    },
  ];

  // ---------- Drawing ----------

  K.place = (name, o = {}) => {
    const p = PARTS[name];
    if (!p) return '';
    const [w, h] = p.box(o);
    const s = o.s || 1;
    return `<g transform="translate(${o.x || 0} ${o.y || 0}) scale(${s}) rotate(${o.r || 0} ${n1(w / 2)} ${n1(h / 2)})">${p.draw(o)}</g>`;
  };

  /** The `hand` filter: a slow wobble bends every line, a fine one roughs its edge like marker. */
  K.FILTER = `<filter id="hand" x="-15%" y="-15%" width="130%" height="130%">
      <feTurbulence type="fractalNoise" baseFrequency=".035" numOctaves="2" seed="4" result="wob"/>
      <feDisplacementMap in="SourceGraphic" in2="wob" scale="4.5" xChannelSelector="R" yChannelSelector="G" result="bent"/>
      <feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="1" seed="9" result="grain"/>
      <feDisplacementMap in="bent" in2="grain" scale="1.6" xChannelSelector="R" yChannelSelector="G"/>
    </filter>`;

  /** A scene's drawing, as SVG content on the 160 x 120 stage (no <svg> wrapper). */
  K.scene = (scene) => {
    K.reseed(scene.seed || 11);
    let body = scene.parts.map(([name, o]) => K.place(name, o)).join('');
    if (scene.id === 'lists') {
      // The pin goes through the olive: redraw its tip over it.
      body += `<g transform="translate(42 12)">${line('M38 33 V8')}${line('M36 8 L38 2', 2.6)}</g>`;
    }
    return `<g filter="url(#hand)">${body}</g>`;
  };

  /** A whole <svg> for a scene. `pad` widens the viewBox (the app's assets use 10: 180 x 140). */
  K.svg = (scene, { pad = 0, width, height, label } = {}) => {
    const vb = `${-pad} ${-pad} ${160 + 2 * pad} ${120 + 2 * pad}`;
    const size = width ? ` width="${width}" height="${height || (width * (120 + 2 * pad)) / (160 + 2 * pad)}"` : '';
    return `<svg viewBox="${vb}"${size} role="img" aria-label="${label || scene.kind}" style="overflow:visible"><defs>${K.FILTER}</defs>${K.scene(scene)}</svg>`;
  };

  root.AteKit = K;
  if (typeof module !== 'undefined') module.exports = K;
})(typeof window !== 'undefined' ? window : globalThis);
