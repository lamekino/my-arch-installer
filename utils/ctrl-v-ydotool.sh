#!/bin/sh

sleep 0.25
YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool type -d 0 "$(wl-paste)"
