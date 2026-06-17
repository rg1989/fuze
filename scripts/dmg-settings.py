# dmgbuild settings for the Fuse installer window.
# release.sh runs from the repo root and passes absolute paths via -D.

import os

_app = defines["app"]
_background = defines["background"]

files = [_app]
symlinks = {"Applications": "/Applications"}

# Geometry matches dmg-background.swift (660×340 pt window, 128 px icons).
background = _background
hide = [".background.png"]
icon_size = 128
text_size = 13
show_icon_preview = True
window_rect = ((200, 120), (660, 340))
icon_locations = {
    "Fuse.app": (165, 160),
    "Applications": (495, 160),
}

format = "UDZO"
filesystem = "APFS"
