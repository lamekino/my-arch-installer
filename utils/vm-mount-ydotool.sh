#!/bin/sh

vol="shared"
mnt="/net"


sleep 0.25
YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool type -d 0 \
    "mkdir -p '$mnt' && mount -t 9p -o trans=virtio '$vol' '$mnt'"
