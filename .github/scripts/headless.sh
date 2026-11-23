#!/bin/sh
#
# headless.sh <command...>: runs the command on a virtual X display (Xvfb, 24-bit)
# with a window manager, as on a desktop.
exec xvfb-run -a -s "-screen 0 1280x1024x24" sh -c 'openbox >/dev/null 2>&1 & sleep 2; "$@"' headless "$@"
