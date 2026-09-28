# Layout of NetworkMonitor.dmg, read by dmgbuild. Run through Scripts/make-dmg.sh.
#
# dmgbuild writes the Finder window's .DS_Store itself instead of scripting
# Finder, so building the image never opens a window and works headless.
#
# The icon positions are the centres the background was drawn around; see
# Scripts/make-dmg-background.swift before moving either.

import os.path

app = defines["app"]  # noqa: F821 — injected by dmgbuild from -D app=...
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE: smaller than UDZO, and opens on every macOS this app supports
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = "Resources/DMG/background.tiff"
window_rect = ((200, 130), (600, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (150, 215),
    "Applications": (450, 215),
}
