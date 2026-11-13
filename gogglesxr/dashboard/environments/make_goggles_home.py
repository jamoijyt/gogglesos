#!/usr/bin/env python3
"""Draws goggles-home.jpg, the GogglesXR home environment: a 360-degree picture
(equirectangular, 2:1) shown around you in the headset when no game is running.

A calm night in Goggles colours: a dark teal sky with stars and a faint green aurora,
low hills on the horizon, and a glowing green grid on the floor fading into mist.
Needs numpy and Pillow (only to redraw it; the JPEG is committed).

  python3 make_goggles_home.py [output.jpg]
"""
import sys

import numpy as np
from PIL import Image

W, H = 4096, 2048
EYE = 1.6                                     # eye height above the floor, metres
rng = np.random.default_rng(7)

u = (np.arange(W) + 0.5) / W
v = (np.arange(H) + 0.5) / H
lon = (u - 0.5) * 2 * np.pi                   # -pi..pi, 0 = straight ahead (-Z)
lat = (0.5 - v) * np.pi                       # +pi/2 = straight up
LON, LAT = np.meshgrid(lon, lat)
dx, dy, dz = np.cos(LAT) * np.sin(LON), np.sin(LAT), -np.cos(LAT) * np.cos(LON)

img = np.zeros((H, W, 3), np.float32)

# Sky: deep teal overhead, lighter towards a green-tinted horizon
up = np.clip(dy, 0, 1)
zenith, horizon = np.array([0.012, 0.045, 0.045]), np.array([0.06, 0.20, 0.17])
sky = horizon + (zenith - horizon) * (up ** 0.45)[..., None]
img[:] = sky

# Aurora: thin green curtains hanging over one part of the sky, brightest at their lower edge
base = 0.42 + 0.10 * np.sin(LON * 1.7 + 0.8) + 0.04 * np.sin(LON * 4.1)
above = LAT - base
height = np.where(above > 0, np.exp(-above / 0.20), np.exp(-(above / 0.025) ** 2))
rays = (0.5 + 0.5 * np.sin(LON * 41 + 3 * np.sin(LON * 6.0))) ** 3 * 0.7 + 0.3
reach = np.clip(np.cos(LON - 0.9) * 1.3, 0, 1) ** 2
glow = height * rays * reach * (dy > 0)
colour = np.where((above > 0.12)[..., None], np.array([0.06, 0.30, 0.30]), np.array([0.12, 0.48, 0.26]))
img += glow[..., None] * colour * 0.55

# Stars: sharp points, more overhead, fading near the horizon
stars = rng.random((H, W)) > 0.9993
brightness = rng.random((H, W)) * 0.8 + 0.2
img += (stars * brightness * np.clip(dy * 3, 0, 1))[..., None] * np.array([0.85, 0.95, 0.9])

# Hills on the horizon: a dark silhouette with a slightly lighter rim
ridge = (0.035 + 0.025 * np.sin(LON * 3 + 1.0) + 0.015 * np.sin(LON * 7.3 + 2.0)
         + 0.008 * np.sin(LON * 17 + 0.4))
hill = (LAT > -0.002) & (LAT < ridge)
img[hill] = np.array([0.012, 0.04, 0.035])
rim = (LAT < ridge) & (LAT > ridge - 0.004) & (LAT > 0)
img[rim] = np.array([0.08, 0.30, 0.18])

# Floor: a glowing green grid on dark ground, seen in perspective, fading into mist
floor = dy < -1e-4
t = np.where(floor, EYE / np.maximum(-dy, 1e-4), 0)
gx, gz = dx * t, dz * t
dist = np.hypot(gx, gz)
cell = 2.0
# You stand in the middle of a square, not on a line
fx, fz = np.abs(((gx + cell / 2) / cell) % 1 - 0.5), np.abs(((gz + cell / 2) / cell) % 1 - 0.5)
width = 0.012 + 0.0025 * dist                 # lines don't vanish into noise far away
line = np.clip(1 - (0.5 - np.maximum(fx, fz)) / width, 0, 1) ** 2
fade = np.exp(-dist / 28)
ground = np.array([0.008, 0.03, 0.026])
grid = np.array([0.24, 0.86, 0.52])
floor_colour = ground + (line * fade)[..., None] * grid
# A soft pool of light under you
floor_colour += (np.exp(-(dist / 2.2) ** 2) * 0.10)[..., None] * np.array([0.3, 1.0, 0.65])
mist = np.clip(1 - fade * 1.4, 0, 1) ** 2
floor_colour = floor_colour * (1 - mist[..., None]) + horizon * mist[..., None]
img[floor] = floor_colour[floor]

# Horizon glow
img += (np.exp(-(LAT / 0.035) ** 2) * 0.18)[..., None] * np.array([0.25, 0.95, 0.55])

out = (np.clip(img, 0, 1) ** (1 / 1.1) * 255).astype(np.uint8)
Image.fromarray(out).save(sys.argv[1] if len(sys.argv) > 1 else "goggles-home.jpg", quality=86, optimize=True,
                          progressive=True)
