"""Render an SVG to PNG with headless Chromium. render.py in.svg out.png size [transparent]"""
import sys, pathlib
from playwright.sync_api import sync_playwright

src, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
transparent = len(sys.argv) > 4
svg = pathlib.Path(src).read_text().replace('width="1024" height="1024"', f'width="{size}" height="{size}"', 1)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": size, "height": size})
    pg.set_content(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
    pg.screenshot(path=out, omit_background=transparent, clip={"x": 0, "y": 0, "width": size, "height": size})
    b.close()
