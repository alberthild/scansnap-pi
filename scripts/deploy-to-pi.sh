#!/usr/bin/env bash
# Deploy the repository files to a Raspberry Pi over SSH.
set -euo pipefail

TARGET="${1:-pi-host}"
SCAN_USER="scansnap"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REMOTE_TMP="/tmp/scansnap-pi-deploy"
SCAN_HOME="/home/$SCAN_USER"

echo "==> Deploying to $TARGET for user $SCAN_USER ..."
ssh "$TARGET" "id '$SCAN_USER' >/dev/null && mkdir -p '$REMOTE_TMP'"

scp \
  pi/bin/scansnap-upload.sh \
  pi/bin/scansnap-upload-bg.sh \
  pi/bin/scansnap-normalize-image.sh \
  pi/config/scansnap.env.example \
  pi/etc/scanbd/dll.conf \
  pi/etc/scanbd/scanner.d/fujitsu.conf \
  pi/etc/scanbd/scripts/scansnap-scan.sh \
  pi/etc/udev/rules.d/79-scansnap-ix500.rules \
  pi/etc/logrotate.d/scansnap \
  pi/etc/sudoers.d/scanbd-scansnap \
  "$TARGET:$REMOTE_TMP/"

ssh "$TARGET" "
  set -e
  sudo install -d -o '$SCAN_USER' -g '$SCAN_USER' -m755 '$SCAN_HOME/bin' '$SCAN_HOME/.config/scansnap'
  sudo install -o '$SCAN_USER' -g '$SCAN_USER' -m755 '$REMOTE_TMP/scansnap-upload.sh' '$SCAN_HOME/bin/scansnap-upload.sh'
  sudo install -o '$SCAN_USER' -g '$SCAN_USER' -m755 '$REMOTE_TMP/scansnap-upload-bg.sh' '$SCAN_HOME/bin/scansnap-upload-bg.sh'
  sudo install -o '$SCAN_USER' -g '$SCAN_USER' -m755 '$REMOTE_TMP/scansnap-normalize-image.sh' '$SCAN_HOME/bin/scansnap-normalize-image.sh'
  if [ ! -e '$SCAN_HOME/.config/scansnap/scansnap.env' ]; then
    sudo install -o '$SCAN_USER' -g '$SCAN_USER' -m600 '$REMOTE_TMP/scansnap.env.example' '$SCAN_HOME/.config/scansnap/scansnap.env'
  fi
  sudo install -m644 '$REMOTE_TMP/dll.conf' /etc/scanbd/dll.conf
  sudo install -m644 '$REMOTE_TMP/fujitsu.conf' /etc/scanbd/scanner.d/fujitsu.conf
  sudo install -m755 '$REMOTE_TMP/scansnap-scan.sh' /etc/scanbd/scripts/scansnap-scan.sh
  sudo install -m644 '$REMOTE_TMP/79-scansnap-ix500.rules' /etc/udev/rules.d/79-scansnap-ix500.rules
  sudo install -m644 '$REMOTE_TMP/scansnap' /etc/logrotate.d/scansnap
  sudo install -m440 '$REMOTE_TMP/scanbd-scansnap' /etc/sudoers.d/scanbd-scansnap
  sudo visudo -c -f /etc/sudoers.d/scanbd-scansnap
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  sudo systemctl restart scanbd
  rm -rf '$REMOTE_TMP'
"

echo "==> Deploy complete. Edit $SCAN_HOME/.config/scansnap/scansnap.env on the Pi before scanning."
