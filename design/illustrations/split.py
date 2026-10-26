"""Split each render into the app's two template layers: ink (dark coverage) and paper (light coverage)."""
import json
import os
import re

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', '..', 'App', 'Resources', 'Assets.xcassets', 'EmptyStates')
# Every scene's id and asset name, read from kit.js so the two never drift.
SCENES = re.findall(r"id: '(\w+)', asset: '(\w+)'", open(os.path.join(HERE, 'kit.js')).read())

for scene, name in SCENES:
    for layer in ('Ink', 'Paper'):
        folder = f'{OUT}/Empty{name}{layer}.imageset'
        os.makedirs(folder, exist_ok=True)
        images = [{'filename': f'Empty{name}{layer}@{s}x.png', 'idiom': 'universal', 'scale': f'{s}x'} for s in (1, 2, 3)]
        with open(f'{folder}/Contents.json', 'w') as f:
            json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1},
                       'properties': {'template-rendering-intent': 'template'}}, f, indent=2)
    for scale in (1, 2, 3):
        rgba = np.asarray(Image.open(f'{HERE}/render/{scene}@{scale}x.png').convert('RGBA')).astype(float) / 255
        alpha, light = rgba[..., 3], rgba[..., :3].mean(-1)
        for layer, cover in (('Ink', alpha * (1 - light)), ('Paper', alpha * light)):
            out = np.zeros(rgba.shape)
            out[..., 3] = cover
            png = Image.fromarray((out * 255).round().astype('uint8'), 'RGBA')
            png.save(f'{OUT}/Empty{name}{layer}.imageset/Empty{name}{layer}@{scale}x.png', optimize=True)
