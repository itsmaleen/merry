"""Sunny icon: a lion-sun with a petal mane over crossed bones, in the Merry
icon's style (cream figure, teal outlines, soft shading, teal gradient).
Writes icon.svg (full colour, full bleed) and glyph.svg (one-colour template)."""
import math, sys

CREAM, SHADE, LINE = "#f7f0db", "#e6d8bb", "#0b5a62"
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
CX, CY = 512, 512


def petal(angle, length=345, width=150, bend=0.22):
    """Leaf from the centre outward, tip swept clockwise like the Sunny's mane."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)          # outward
    px, py = -uy, ux                           # sideways
    def pt(t, s):                              # t along, s across
        return CX + ux * t + px * s, CY + uy * t + py * s
    base, tip = 120, length
    sweep = bend * width
    b1, b2 = pt(base, -width * 0.42), pt(base, width * 0.42)
    tp = pt(tip, sweep)
    c1 = pt(base + (tip - base) * 0.55, -width * 0.62)
    c2 = pt(base + (tip - base) * 0.45, width * 0.55 + sweep * 0.6)
    outline = (f"M{b1[0]:.1f},{b1[1]:.1f} Q{c1[0]:.1f},{c1[1]:.1f} {tp[0]:.1f},{tp[1]:.1f} "
               f"Q{c2[0]:.1f},{c2[1]:.1f} {b2[0]:.1f},{b2[1]:.1f} Z")
    # shaded half: from the vein to the trailing edge
    v0, v1 = pt(base + 10, 0), pt(base + (tip - base) * 0.78, sweep * 0.55)
    shade = (f"M{v0[0]:.1f},{v0[1]:.1f} L{v1[0]:.1f},{v1[1]:.1f} L{tp[0]:.1f},{tp[1]:.1f} "
             f"Q{c2[0]:.1f},{c2[1]:.1f} {b2[0]:.1f},{b2[1]:.1f} Z")
    vein = f"M{v0[0]:.1f},{v0[1]:.1f} Q{pt(base + 120, sweep * 0.1)[0]:.1f},{pt(base + 120, sweep * 0.1)[1]:.1f} {v1[0]:.1f},{v1[1]:.1f}"
    return outline, shade, vein


def bone(angle, half=370, r=38, w=46):
    """A bone through the centre, knobbed at both ends."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)
    px, py = -uy, ux
    parts = []
    for s in (-1, 1):
        ex, ey = CX + ux * half * s, CY + uy * half * s
        for k in (-1, 1):
            parts.append(f'<circle cx="{ex + px * r * 0.8 * k:.1f}" cy="{ey + py * r * 0.8 * k:.1f}" r="{r}"/>')
    shaft = (f'<line x1="{CX - ux * half:.1f}" y1="{CY - uy * half:.1f}" '
             f'x2="{CX + ux * half:.1f}" y2="{CY + uy * half:.1f}" stroke-width="{w}"/>')
    return parts, shaft


def figure(mono=False):
    fill = "#000" if mono else CREAM
    line = "none" if mono else LINE
    g = []
    # crossed bones behind everything: outline pass, then fill pass, so the
    # knobs read as one shape
    for stroke_w, colour in ((28, line), (0, fill)):
        if colour == "none":
            continue
        for ang in (35, 145):
            knobs, shaft = bone(ang)
            extra = stroke_w
            g.append(f'<g fill="{colour}" stroke="{colour}" stroke-width="{extra}">'
                     + "".join(knobs) + "</g>")
            g.append(shaft.replace('stroke-width="46"', f'stroke-width="{46 + extra}"')
                     .replace("<line", f'<line stroke="{colour}" stroke-linecap="butt"'))
    # mane
    for i in range(10):
        o, s, v = petal(-90 + i * 36 + 18)
        if mono:
            g.append(f'<path d="{o}" fill="#000"/>')
            g.append(f'<path d="{v}" fill="none" stroke="#fff" stroke-width="14" stroke-linecap="round"/>')
        else:
            g.append(f'<path d="{o}" fill="{CREAM}"/>')
            g.append(f'<path d="{s}" fill="{SHADE}"/>')
            g.append(f'<path d="{o}" fill="none" stroke="{LINE}" stroke-width="18" stroke-linejoin="round"/>')
            g.append(f'<path d="{v}" fill="none" stroke="{LINE}" stroke-width="12" stroke-linecap="round"/>')
    # face
    fl = "#fff" if mono else LINE
    if mono:
        g.append(f'<circle cx="{CX}" cy="{CY}" r="205" fill="#fff"/>')
        g.append(f'<circle cx="{CX}" cy="{CY}" r="182" fill="#000"/>')
    else:
        g.append(f'<circle cx="{CX}" cy="{CY}" r="195" fill="{CREAM}" stroke="{LINE}" stroke-width="20"/>')
        g.append(f'<path d="M{CX-150},{CY+124} A195,195 0 0 0 {CX+150},{CY+124} A260,260 0 0 1 {CX-150},{CY+124}Z" fill="{SHADE}"/>')
    # eyes: ringed, looking up and out
    for sx in (-1, 1):
        ex, ey = CX + sx * 78, CY - 52
        g.append(f'<circle cx="{ex}" cy="{ey}" r="46" fill="{"#000" if mono else CREAM}" stroke="{fl}" stroke-width="14"/>')
        g.append(f'<circle cx="{ex + sx * 8}" cy="{ey - 4}" r="27" fill="{fl}"/>')
        if not mono:
            g.append(f'<circle cx="{ex + sx * 8 - 9}" cy="{ey - 13}" r="7" fill="{CREAM}"/>')
    # nose and the line down to the grin
    g.append(f'<path d="M{CX-24},{CY+8} Q{CX},{CY-2} {CX+24},{CY+8} Q{CX+20},{CY+28} {CX},{CY+34} Q{CX-20},{CY+28} {CX-24},{CY+8}Z" fill="{fl}"/>')
    # grin: wide half-moon of teeth
    top, w = CY + 62, 118
    mouth = f"M{CX-w},{top} Q{CX},{top-26} {CX+w},{top} Q{CX+w-8},{top+104} {CX},{top+110} Q{CX-w+8},{top+104} {CX-w},{top}Z"
    g.append(f'<path d="{mouth}" fill="{"#000" if mono else CREAM}" stroke="{fl}" stroke-width="14" stroke-linejoin="round"/>')
    g.append(f'<path d="M{CX},{CY+34} L{CX},{top+110}" stroke="{fl}" stroke-width="11" stroke-linecap="round"/>')
    return "\n".join(g)


icon = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
    <stop offset="0" stop-color="#0c8089"/><stop offset="1" stop-color="#003f48"/>
  </linearGradient>
  <filter id="lift" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#00252b" flood-opacity="0.45"/>
  </filter>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<g filter="url(#lift)"><g transform="translate(512 512) scale(1.16) translate(-512 -512)">
{figure()}
</g></g>
</svg>'''

glyph = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="132 132 760 760" width="1024" height="1024">
{figure(mono=True)}
</svg>'''

open(f"{OUT}/icon.svg", "w").write(icon)
open(f"{OUT}/glyph.svg", "w").write(glyph)
