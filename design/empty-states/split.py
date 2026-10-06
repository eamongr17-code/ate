"""Split each render into the app's two template layers: ink (dark coverage) and paper (light coverage)."""
import os
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', '..', 'App', 'Resources', 'Assets.xcassets', 'EmptyStates')
NAMES = {'journal': 'Journal', 'lists': 'Lists', 'list': 'List', 'saved': 'Saved',
         'feed': 'Rail', 'notifs': 'Printer', 'search': 'Search', 'error': 'Torn'}

for scene, name in NAMES.items():
    for scale in (1, 2, 3):
        rgba = np.asarray(Image.open(f'{HERE}/render/{scene}@{scale}x.png').convert('RGBA')).astype(float) / 255
        alpha, light = rgba[..., 3], rgba[..., :3].mean(-1)
        for layer, cover in (('Ink', alpha * (1 - light)), ('Paper', alpha * light)):
            out = np.zeros(rgba.shape)
            out[..., 3] = cover
            png = Image.fromarray((out * 255).round().astype('uint8'), 'RGBA')
            png.save(f'{OUT}/Empty{name}{layer}.imageset/Empty{name}{layer}@{scale}x.png', optimize=True)
