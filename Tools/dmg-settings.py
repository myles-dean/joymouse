# dmgbuild settings for JoyMouse.dmg (used by release.sh):
#   dmgbuild -s Tools/dmg-settings.py -D app=build/JoyMouse.app "JoyMouse" build/JoyMouse-<version>.dmg
import os.path

app = defines.get("app", "build/JoyMouse.app")  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"            # the mounted volume's icon

background = "Resources/dmg-background.png"    # 640 x 400 (Tools/dmg-background.swift)
window_rect = ((200, 120), (640, 432))      # height includes Finder's ~32 pt title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
# Icon centres; must match Tools/dmg-background.swift (appX, appsX, iconY).
icon_locations = {app_name: (170, 185), "Applications": (470, 185)}
