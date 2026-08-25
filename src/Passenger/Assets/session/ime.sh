# The human's *own* fcitx5, told to attach to this display as well.
#
# Not a second instance: fcitx5 exposes OpenWaylandConnection precisely so one
# process can serve more than one compositor, so the session gets the real
# config, the real dictionaries and whatever has been learned in them -- live,
# rather than as a copy that would go stale and could not be written back to.
# It needs no teardown either: fcitx5 drops the connection when the display does.
dbus-send --session --dest=org.fcitx.Fcitx5 --type=method_call /controller \
  org.fcitx.Fcitx.Controller1.OpenWaylandConnection string:"$WAYLAND_DISPLAY" \
  || echo "no IME: fcitx5 did not answer on the session bus"
