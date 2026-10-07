#!/bin/sh
[ ! -e /run/scansnap-maintenance ] || exit 0
# Run the scan pipeline as the dedicated scansnap user.
logger -t scansnap "Button pressed: action=$SCANBD_ACTION device=$SCANBD_DEVICE"
exec sudo -u scansnap -H /home/scansnap/bin/scansnap-upload.sh
