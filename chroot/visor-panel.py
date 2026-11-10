#!/usr/bin/python3
"""Draw the Goggles "Visor" taskbar background for the Plasma desktop theme.

A Plasma panel background is one SVG holding nine tiles (corners, edges, centre) that Plasma
stretches around the panel, plus the same nine again as a blur mask and as a drop shadow.
This follows the layout of Breeze's widgets/panel-background.svgz, with:
  - strongly rounded corners (16 px instead of 6), so a floating panel reads as a visor/pill
  - a glowing accent line along the top edge
  - a faint light rim on the other edges

  visor-panel.py OPACITY > panel-background.svg      (OPACITY 0..1 of the glass fill)

Colours come from the theme at run time through the ColorScheme-* classes.
"""
import sys

R = 16          # corner radius = size of the corner tiles and thickness of the edge tiles
C = 32          # length of the stretchable part of each tile
S = 10          # shadow width
RIM = 0.10      # opacity of the light rim on the sides and bottom
GLOW = 6        # height of the glow under the accent line


def main(opacity):
    o = f"{opacity:g}"
    bg = f'class="ColorScheme-Background" fill="currentColor" opacity="{o}"'
    rim = f'class="ColorScheme-Text" fill="currentColor" opacity="{RIM}"'
    rim_stroke = f'class="ColorScheme-Text" stroke="currentColor" stroke-opacity="{RIM}" fill="none"'
    acc = 'class="ColorScheme-Highlight" fill="currentColor"'
    out = []
    w = out.append

    w(f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="240" height="130" viewBox="0 0 240 130">
  <defs>
    <style type="text/css" id="current-color-scheme">
      .ColorScheme-Text {{ color:#e6f3ee; stop-color:#e6f3ee; }}
      .ColorScheme-Background {{ color:#0e1c19; stop-color:#0e1c19; }}
      .ColorScheme-Highlight {{ color:#3ddc84; stop-color:#3ddc84; }}
    </style>
    <linearGradient id="glow" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" class="ColorScheme-Highlight" style="stop-color:currentColor;stop-opacity:0.38"/>
      <stop offset="1" class="ColorScheme-Highlight" style="stop-color:currentColor;stop-opacity:0"/>
    </linearGradient>
    <linearGradient id="arc" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" class="ColorScheme-Highlight" style="stop-color:currentColor;stop-opacity:0.95"/>
      <stop offset="0.75" class="ColorScheme-Highlight" style="stop-color:currentColor;stop-opacity:0"/>
    </linearGradient>
    <linearGradient id="side">
      <stop offset="0" style="stop-color:#000;stop-opacity:0.22"/>
      <stop offset="0.3333" style="stop-color:#000;stop-opacity:0.11"/>
      <stop offset="0.5" style="stop-color:#000;stop-opacity:0.055"/>
      <stop offset="0.5833" style="stop-color:#000;stop-opacity:0.027"/>
      <stop offset="1" style="stop-color:#000;stop-opacity:0"/>
    </linearGradient>
    <linearGradient id="side-up" xlink:href="#side" gradientUnits="userSpaceOnUse" x1="0" y1="{S}" x2="0" y2="0"/>
    <linearGradient id="side-left" xlink:href="#side" gradientUnits="userSpaceOnUse" x1="{S}" y1="0" x2="0" y2="0"/>
    <radialGradient id="corner" gradientUnits="userSpaceOnUse" cx="{R + S}" cy="{R + S}" r="{R + S}">''')
    k0, span = R / (R + S), S / (R + S)
    w(f'      <stop offset="{k0:.4f}" style="stop-color:#000;stop-opacity:0"/>')
    for t, a in ((0, 0.22), (0.3333, 0.11), (0.5, 0.055), (0.5833, 0.027), (1, 0)):
        w(f'      <stop offset="{k0 + t * span:.4f}" style="stop-color:#000;stop-opacity:{a}"/>')
    w('''    </radialGradient>
    <clipPath id="clip-tl"><path d="M0,%d A%d,%d 0 0 1 %d,0 V%d Z"/></clipPath>
  </defs>''' % (R, R, R, R, R))

    # ------------------------------------------------------------ the panel itself
    x0, y0 = 0, S                     # same origin as Breeze
    xs = (x0, x0 + R, x0 + R + C)     # left, centre, right columns
    ys = (y0, y0 + R, y0 + R + C)     # top, centre, bottom rows
    quarter = f"M0,{R} A{R},{R} 0 0 1 {R},0 V{R} Z"              # top-left corner shape
    arc = f"M0.5,{R} A{R - 0.5},{R - 0.5} 0 0 1 {R},0.5"         # its outline, half a pixel in

    def corner(el, tx, ty, flip_x, flip_y, top):
        sx, sy = (-1 if flip_x else 1), (-1 if flip_y else 1)
        ox, oy = tx + (R if flip_x else 0), ty + (R if flip_y else 0)
        w(f'  <g id="{el}" transform="matrix({sx},0,0,{sy},{ox},{oy})">')
        w(f'    <path d="{quarter}" {bg}/>')
        w(f'    <path d="{arc}" {rim_stroke}/>')
        if top:
            w(f'    <rect width="{R}" height="{GLOW}" fill="url(#glow)" clip-path="url(#clip-tl)"/>')
            w(f'    <path d="{arc}" fill="none" stroke="url(#arc)"/>')
        w('  </g>')

    corner("topleft", xs[0], ys[0], False, False, True)
    corner("topright", xs[2], ys[0], True, False, True)
    corner("bottomleft", xs[0], ys[2], False, True, False)
    corner("bottomright", xs[2], ys[2], True, True, False)

    w(f'''  <g id="top" transform="translate({xs[1]},{ys[0]})">
    <rect width="{C}" height="{R}" {bg}/>
    <rect width="{C}" height="{GLOW}" fill="url(#glow)"/>
    <rect width="{C}" height="1" {acc} opacity="0.95"/>
  </g>
  <g id="bottom" transform="translate({xs[1]},{ys[2]})">
    <rect width="{C}" height="{R}" {bg}/>
    <rect y="{R - 1}" width="{C}" height="1" {rim}/>
  </g>
  <g id="left" transform="translate({xs[0]},{ys[1]})">
    <rect width="{R}" height="{C}" {bg}/>
    <rect width="1" height="{C}" {rim}/>
  </g>
  <g id="right" transform="translate({xs[2]},{ys[1]})">
    <rect width="{R}" height="{C}" {bg}/>
    <rect x="{R - 1}" width="1" height="{C}" {rim}/>
  </g>
  <g id="center" transform="translate({xs[1]},{ys[1]})">
    <rect width="{C}" height="{C}" {bg}/>
  </g>''')

    # Space kept between the panel edge and its contents (same 4 px as Breeze)
    cx, cy = xs[1] + C // 2 - 2, ys[1] + C // 2 - 2
    right, bottom = xs[2] + R, ys[2] + R
    w(f'''  <rect id="hint-top-margin" x="{cx}" y="{ys[0]}" width="4" height="4" fill="#f0f"/>
  <rect id="hint-bottom-margin" x="{cx}" y="{bottom - 4}" width="4" height="4" fill="#f0f"/>
  <rect id="hint-left-margin" x="{xs[0]}" y="{cy}" width="4" height="4" fill="#f0f"/>
  <rect id="hint-right-margin" x="{right - 4}" y="{cy}" width="4" height="4" fill="#f0f"/>''')

    # Thick panels (same values as Breeze)
    ty = bottom + S + 8
    w(f'''  <rect id="thick-center" x="{xs[1]}" y="{ty + 8}" width="{C}" height="16" {bg}/>
  <rect id="thick-hint-top-margin" x="{cx}" y="{ty}" width="4" height="8" fill="#808"/>
  <rect id="thick-hint-bottom-margin" x="{cx}" y="{ty + 24}" width="4" height="8" fill="#808"/>
  <rect id="thick-hint-left-margin" x="{xs[1] - 8}" y="{ty + 14}" width="8" height="4" fill="#808"/>
  <rect id="thick-hint-right-margin" x="{xs[1] + C}" y="{ty + 14}" width="8" height="4" fill="#808"/>''')

    # ------------------------------------------------------------ blur mask
    # Same tiles; corners one pixel smaller so no blurred pixel shows outside the rounded edge
    mx = right + S + 2 * R + C + 2 * S + 12      # to the right of the shadow tiles
    mxs = (mx, mx + R, mx + R + C)
    mq = f"M1,{R} H0 H{R} V0 V1 A{R - 1},{R - 1} 0 0 0 1,{R} Z"

    def mask_corner(el, tx, ty_, flip_x, flip_y):
        sx, sy = (-1 if flip_x else 1), (-1 if flip_y else 1)
        ox, oy = tx + (R if flip_x else 0), ty_ + (R if flip_y else 0)
        w(f'  <path id="{el}" d="{mq}" transform="matrix({sx},0,0,{sy},{ox},{oy})"/>')

    mask_corner("mask-topleft", mxs[0], ys[0], False, False)
    mask_corner("mask-topright", mxs[2], ys[0], True, False)
    mask_corner("mask-bottomleft", mxs[0], ys[2], False, True)
    mask_corner("mask-bottomright", mxs[2], ys[2], True, True)
    w(f'''  <rect id="mask-top" x="{mxs[1]}" y="{ys[0]}" width="{C}" height="{R}"/>
  <rect id="mask-bottom" x="{mxs[1]}" y="{ys[2]}" width="{C}" height="{R}"/>
  <rect id="mask-left" x="{mxs[0]}" y="{ys[1]}" width="{R}" height="{C}"/>
  <rect id="mask-right" x="{mxs[2]}" y="{ys[1]}" width="{R}" height="{C}"/>
  <rect id="mask-center" x="{mxs[1]}" y="{ys[1]}" width="{C}" height="{C}"/>''')

    # ------------------------------------------------------------ drop shadow
    # Each tile is the shadow (S wide) plus the part of the panel it sits against, left clear
    T = R + S
    sx0 = right + 12
    sxs = (sx0, sx0 + T, sx0 + T + C)
    sys_ = (0, T, T + C)
    clear = 'fill="#000" fill-opacity="0.004" opacity="0.001"'
    sc = f"M0,0 H{T} V{S} A{R},{R} 0 0 0 {S},{T} H0 Z"

    def shadow_corner(el, tx, ty_, flip_x, flip_y):
        fx, fy = (-1 if flip_x else 1), (-1 if flip_y else 1)
        ox, oy = tx + (T if flip_x else 0), ty_ + (T if flip_y else 0)
        w(f'  <g id="{el}" transform="matrix({fx},0,0,{fy},{ox},{oy})">')
        w(f'    <rect width="{T}" height="{T}" {clear}/>')
        w(f'    <path d="{sc}" fill="url(#corner)"/>')
        w('  </g>')

    shadow_corner("shadow-topleft", sxs[0], sys_[0], False, False)
    shadow_corner("shadow-topright", sxs[2], sys_[0], True, False)
    shadow_corner("shadow-bottomleft", sxs[0], sys_[2], False, True)
    shadow_corner("shadow-bottomright", sxs[2], sys_[2], True, True)
    w(f'''  <g id="shadow-top" transform="translate({sxs[1]},{sys_[0]})">
    <rect width="{C}" height="{T}" {clear}/>
    <rect width="{C}" height="{S}" fill="url(#side-up)"/>
  </g>
  <g id="shadow-bottom" transform="matrix(1,0,0,-1,{sxs[1]},{sys_[2] + T})">
    <rect width="{C}" height="{T}" {clear}/>
    <rect width="{C}" height="{S}" fill="url(#side-up)"/>
  </g>
  <g id="shadow-left" transform="translate({sxs[0]},{sys_[1]})">
    <rect width="{T}" height="{C}" {clear}/>
    <rect width="{S}" height="{C}" fill="url(#side-left)"/>
  </g>
  <g id="shadow-right" transform="matrix(-1,0,0,1,{sxs[2] + T},{sys_[1]})">
    <rect width="{T}" height="{C}" {clear}/>
    <rect width="{S}" height="{C}" fill="url(#side-left)"/>
  </g>
  <g id="shadow-center" transform="translate({sxs[1]},{sys_[1]})">
    <rect width="{C}" height="{C}" {clear}/>
  </g>''')
    scx, scy = sxs[1] + C // 2, sys_[1] + C // 2
    sr, sb = sxs[2] + T, sys_[2] + T
    for kind, colour, dx in (("margin", "#f0f", -3), ("inset", "#0f0", 1)):
        w(f'''  <rect id="shadow-hint-top-{kind}" x="{scx + dx}" y="0" width="2" height="{S}" fill="{colour}"/>
  <rect id="shadow-hint-bottom-{kind}" x="{scx + dx}" y="{sb - S}" width="2" height="{S}" fill="{colour}"/>
  <rect id="shadow-hint-left-{kind}" x="{sxs[0]}" y="{scy + dx}" width="{S}" height="2" fill="{colour}"/>
  <rect id="shadow-hint-right-{kind}" x="{sr - S}" y="{scy + dx}" width="{S}" height="2" fill="{colour}"/>''')

    w('</svg>')
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    try:
        value = float(sys.argv[1])
        if not 0 < value <= 1:
            raise ValueError
    except (IndexError, ValueError):
        sys.exit("usage: visor-panel.py OPACITY   (0 < OPACITY <= 1)")
    main(value)
