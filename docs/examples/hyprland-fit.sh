#!/bin/sh
# Example AGENT_BROWSER_GEOMETRY_CMD for Hyprland.
#
# Prints the VNC viewer window's size in physical pixels as WxH@scale, which
# agent-browser uses as the nested output size -- fitting the output to the
# window exactly, so there is no letterbox border and no resampling.
#
# This lives here as an example rather than in the tool: measuring another
# client's window needs compositor IPC, and every desktop answers it
# differently. Adapt it for sway (swaymsg -t get_tree), or pin a size with
# AGENT_BROWSER_VNC_SIZE instead.
#
#   export AGENT_BROWSER_GEOMETRY_CMD=/path/to/hyprland-fit.sh
hyprctl -j clients | python3 -c '
import json, subprocess, sys

clients = json.load(sys.stdin)
window = next((c for c in clients
               if "vnc" in (str(c.get("class", "")) + str(c.get("title", ""))).lower()),
              None)
if window is None:
    raise SystemExit(1)
monitors = json.loads(subprocess.run(["hyprctl", "-j", "monitors"],
                                     capture_output=True, text=True).stdout)
monitor = next((m for m in monitors if m.get("focused")), monitors[0])
scale = float(monitor.get("scale", 1.0))
width, height = window["size"]
print(f"{round(width * scale)}x{round(height * scale)}@{scale}")
'
