"""Split each render into the app's two template layers: ink (dark coverage) and paper (light coverage)."""
import os
import re

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', '..', 'App', 'Resources', 'Assets.xcassets', 'EmptyStates')
# Every scene's id and asset name, read from kit.js so the two never drift.
# Air kept above and below the drawing, in 3x pixels (2pt): room for the marker's wobble.
MARGIN = 6
SCENES = re.findall(r"id: '(\w+)', asset: '(\w+)'", open(os.path.join(HERE, 'kit.js')).read())

for scene, name in SCENES:
    for layer in ('Ink', 'Paper'):
        folder = f'{OUT}/Empty{name}{layer}.imageset'
        if not os.path.exists(f'{folder}/Contents.json'):
            # A new scene: its image set, as Xcode writes one, marked as a template so it takes a tint.
            os.makedirs(folder, exist_ok=True)
            images = ',\n'.join(f'    {{ "filename" : "Empty{name}{layer}@{s}x.png", "idiom" : "universal", "scale" : "{s}x" }}'
                                 for s in (1, 2, 3))
            with open(f'{folder}/Contents.json', 'w') as f:
                f.write('{\n  "images" : [\n' + images + '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
                        '  "properties" : {\n    "template-rendering-intent" : "template"\n  }\n}\n')
    # Trimmed top and bottom to the drawing (all three scales cut at the same points), so the line sits
    # right under what is drawn, not under the stage's empty air (Eamon, 27 Oct). The width stays the
    # stage's, so every drawing keeps one scale.
    big = np.asarray(Image.open(f'{HERE}/render/{scene}@3x.png').convert('RGBA'))[..., 3]
    rows = np.nonzero(big.max(1) > 8)[0]
    top, bottom = max(rows[0] - MARGIN, 0), min(rows[-1] + 1 + MARGIN, big.shape[0])
    top, bottom = top - top % 3, bottom + (-bottom) % 3
    for scale in (1, 2, 3):
        rgba = np.asarray(Image.open(f'{HERE}/render/{scene}@{scale}x.png').convert('RGBA')).astype(float) / 255
        rgba = rgba[top * scale // 3:bottom * scale // 3]
        alpha, light = rgba[..., 3], rgba[..., :3].mean(-1)
        for layer, cover in (('Ink', alpha * (1 - light)), ('Paper', alpha * light)):
            out = np.zeros(rgba.shape)
            out[..., 3] = cover
            png = Image.fromarray((out * 255).round().astype('uint8'), 'RGBA')
            png.save(f'{OUT}/Empty{name}{layer}.imageset/Empty{name}{layer}@{scale}x.png', optimize=True)
