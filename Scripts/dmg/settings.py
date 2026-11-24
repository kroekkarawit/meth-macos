# dmgbuild settings for Meth's drag-and-drop installer.
import os.path

app = defines["app"]
background = defines["background"]

format = "UDZO"
filesystem = "HFS+"
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]
icon_locations = {os.path.basename(app): (180, 190), "Applications": (480, 190)}
background = background
window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
