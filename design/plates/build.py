#!/usr/bin/env python3
"""Build the app's live plate page from the approved engine (design/rebuild/plate-awards*.html).

    python3 design/plates/build.py

`engine.js` is the mockup engine exactly as Eamon approved it (28 Oct 2026). This script adapts it for
the app without touching how a plate looks or moves:
  * the ids become the server's award ids (0098),
  * the backstamp and the glass engraving use the app's DM Sans and carry the viewer's handle,
  * the mockup page's grid, table and buttons go; `window.ate` is the app's handle on it,
  * the first drink (the mockup's one glass) leaves the set: it was retired (0099, "just plates"),
  * every plate rests fully face-on, live and in the stills (Eamon, build 269): the entrance's lean
    ends at zero instead of snapping there on its last frame, and there is no idle sway after it,
and writes one self-contained page (three.js, the fonts and the wordmark inlined) to
App/Resources/Plates/plate-world.html, which `AtePlateView` loads into a WKWebView.
`bake.js` renders the stills the rows and grids use from the same page.
"""
import base64
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "App/Resources/Plates/plate-world.html"

IDS = {
    "d1": "dishes_1", "d10": "dishes_10", "d25": "dishes_25", "d50": "dishes_50", "d100": "dishes_100",
    "d250": "dishes_250", "d500": "dishes_500", "s5": "first_5", "s6": "first_6", "s05": "first_half",
    "odrink": "first_drink", "odessert": "first_dessert", "ocountry": "new_country", "owith": "ate_with",
    "osave": "saved_by_someone", "o10s": "saves_10", "o3same": "same_dish_3", "o5entry": "five_in_entry",
    "o3day": "three_in_day", "o5place": "five_at_place",
}

# Display fonts the numbers are lettered in, subset to "0123456789." (Google Fonts, all OFL).
FONTS = [
    ("Alfa Slab One", "normal", "400", "AlfaSlabOne-400.ttf"),
    ("Archivo Black", "normal", "400", "ArchivoBlack-400.ttf"),
    ("IM Fell English", "italic", "400", "IMFellEnglish-Italic-400.ttf"),
    ("Reem Kufi", "normal", "700", "ReemKufi-700.ttf"),
    ("Shippori Mincho B1", "normal", "800", "ShipporiMinchoB1-800.ttf"),
    ("Cormorant Garamond", "italic", "600", "CormorantGaramond-Italic-600.ttf"),
    ("Cinzel Decorative", "normal", "700", "CinzelDecorative-700.ttf"),
    ("Playfair Display", "italic", "900", "PlayfairDisplay-Italic-900.ttf"),
    ("Zen Antique", "normal", "400", "ZenAntique-400.ttf"),
    ("Yuji Syuku", "normal", "400", "YujiSyuku-400.ttf"),
    ("Bodoni Moda", "normal", "600", "BodoniModa-600.ttf"),
]
APP_FONTS = [
    ("DM Sans", "normal", "100 1000", ROOT / "App/Resources/Fonts/DMSans-Variable.ttf"),
    ("Newsreader", "italic", "200 800", ROOT / "App/Resources/Fonts/Newsreader-Italic-Variable.ttf"),
]


def sub(src, old, new, count=1):
    n = src.count(old)
    assert n == count, f"expected {count} of {old[:60]!r}, found {n}"
    return src.replace(old, new)


def engine():
    js = (HERE / "engine.js").read_text()
    for old, new in IDS.items():
        js = sub(js, f"{{id:'{old}',", f"{{id:'{new}',")
    js = sub(js, "a.id==='s05'", "a.id==='first_half'")
    js = js.replace('"Bricolage Grotesque"', '"DM Sans"')
    # the viewer's handle on the backstamp and the glass
    js = sub(js, "arcText(x,'MADE FOR @EAMON',", "arcText(x,('MADE FOR @'+HANDLE).toUpperCase(),")
    js = sub(js, "x.fillText('MADE FOR @EAMON',0,y+86)", "x.fillText(('MADE FOR @'+HANDLE).toUpperCase(),0,y+86)")
    js = sub(js, "const TAU=Math.PI*2;", "const TAU=Math.PI*2;let HANDLE='';")
    # the mockup's page furniture goes; the app drives the plate through window.ate
    js = re.sub(r"function show\(a\)\{.*?\n\}\n", "function show(a){build(a,false)}\n", js, count=1, flags=re.S)
    js = sub(js, "document.getElementById('flip').onclick=()=>{", "function flip(){")
    js = sub(js, "document.getElementById('play').onclick=()=>playIntro();\n", "")
    js = re.sub(r"/\* ---------- the set, rendered from the same plates ---------- \*/.*?(?=function setTheme)",
                APP_TAIL, js, count=1, flags=re.S)
    js = re.sub(r"function setTheme\(t\)\{.*?\nfunction start\(\)\{[^\n]*\n",
                "function start(){resize();addEventListener('resize',resize);ready()}\n", js, count=1, flags=re.S)
    # rest face-on: the lean comes back to nothing as the entrance lands, and nothing sways after
    js = sub(js, "tilt=.4*Math.sin(e*Math.PI*1.25)*(1-e*.6)", "tilt=.4*Math.sin(e*Math.PI)*(1-e*.6)")
    js = sub(js, "pivot.rotation.x=tilt+(drag||intro?0:Math.sin(idle)*.07);"
                 "pivot.rotation.y+=(drag||intro?0:Math.sin(idle*.8+1)*.09);"
                 "pivot.rotation.z=intro?spinZ:(drag?0:Math.sin(idle*.7)*.03);",
             "pivot.rotation.x=tilt;pivot.rotation.z=intro?spinZ:0;")
    js = sub(js, "'600 30px \"DM Sans\"'", "'600 30px \"DM Sans\"','500 30px \"DM Sans\"'")
    return js


APP_TAIL = r"""/* ---------- the app's handle on the plate ---------- */
A.splice(A.findIndex(a=>a.id==='first_drink'),1);  // retired (0099): the set is just plates
function shoot(a,off){pivot.position.set(0,0,0);pivot.rotation.set(a.kind==='glass'?.12:0,0,0);build(a,off);renderer.render(scene,camera);return renderer.domElement.toDataURL('image/png')}
const post=(m)=>{try{webkit.messageHandlers.plate.postMessage(m)}catch(e){}};
let running=false;
function ready(){
  window.ate={
    // {id, name, dish, date, handle, dark, intro}: the plate the page shows, with its backstamp
    show(o){const a=A.find(a=>a.id===o.id);if(!a)return false;
      a.n=o.name||a.n;a.dish=o.dish||'';a.date=o.date||'';HANDLE=o.handle||'';dark=!!o.dark;
      renderer.setSize(canvas.clientWidth,canvas.clientWidth,false);camera.position.z=6.3;catcher.visible=true;
      show(a);catcher.material.opacity=a.kind==='glass'?0:shadowOp();
      if(o.intro===false){intro=null;rot=target=0;tilt=0;pivot.position.set(0,0,0);key.position.x=-1.6;canvas.style.opacity=1}else playIntro();
      if(!running){running=true;requestAnimationFrame(tick)}return true},
    flip(){flip()},
    replay(){playIntro()},
    // a still of the front (the rows and grids), size in px; `off` = the unglazed white blank
    still(id,size,off){const a=A.find(a=>a.id===id);renderer.setSize(size,size,false);camera.position.z=4.7;catcher.visible=false;
      const url=shoot(a,!!off);renderer.setSize(canvas.clientWidth,canvas.clientWidth,false);camera.position.z=6.3;catcher.visible=true;return url},
    ids:A.map(a=>a.id)};
  post('ready');
}
"""


def font_face(family, style, weight, path):
    data = base64.b64encode(pathlib.Path(path).read_bytes()).decode()
    return (f"@font-face{{font-family:'{family}';font-style:{style};font-weight:{weight};"
            f"src:url(data:font/ttf;base64,{data}) format('truetype')}}")


def page():
    faces = [font_face(f, s, w, HERE / "fonts" / p) for f, s, w, p in FONTS]
    faces += [font_face(f, s, w, p) for f, s, w, p in APP_FONTS]
    svg = (ROOT / "App/Resources/Brand/ate-wordmark.svg").read_bytes()
    wordmark = "data:image/svg+xml;base64," + base64.b64encode(svg).decode()
    js = engine().replace("__WORDMARK__", wordmark)
    three = (HERE / "three.r128.min.js").read_text()
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<!-- Generated by design/plates/build.py from design/plates/engine.js. Do not edit by hand. -->
<style>
{chr(10).join(faces)}
html,body{{margin:0;padding:0;background:transparent;overflow:hidden;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}}
#stage{{width:100vw;height:100vw;display:block;touch-action:none;opacity:0}}
</style></head>
<body><canvas id="stage" aria-hidden="true"></canvas>
<script>{three}</script>
<script>{js}</script>
</body></html>
"""


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(page())
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")
