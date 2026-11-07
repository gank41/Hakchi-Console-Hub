"""Finder layout for the local Hakchi Console Hub installer image."""
import os

application = defines["app"]
readme = defines["readme"]
files = [application, readme]
symlinks = {"Applications": "/Applications"}
background = "builtin-arrow"
window_rect = ((160, 160), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 96
text_size = 12
icon_locations = {
    os.path.basename(application): (140, 120),
    "Applications": (500, 120),
    os.path.basename(readme): (320, 245),
}
