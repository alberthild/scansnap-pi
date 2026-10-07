#!/usr/bin/env bash
# Run as root after staging the repository's pi/ tree.
set -euo pipefail
SCAN_USER="${1:?scan user required}"
STAGE="${2:?staging directory required}"
[[ "$SCAN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
SCAN_HOME="$(getent passwd "$SCAN_USER" | cut -d: -f6)"
[[ "$SCAN_HOME" == "/home/$SCAN_USER" ]] || { echo 'Expected /home/USER for systemd template' >&2; exit 2; }
BACKUP="/var/backups/scansnap/$(date +%Y%m%d-%H%M%S)"
install -d -m700 "$BACKUP"
[[ ! -d "$SCAN_HOME/bin" ]] || cp -a "$SCAN_HOME/bin" "$BACKUP/bin"
[[ ! -d "$SCAN_HOME/.config/scansnap" ]] || cp -a "$SCAN_HOME/.config/scansnap" "$BACKUP/config"
echo "Backup: $BACKUP"
BUTTON=/etc/scanbd/scripts/scansnap-scan.sh
if [[ -f "$BUTTON" ]]; then
  cp -a "$BUTTON" "$BACKUP/button-script"
  { head -n 1 "$BUTTON"; echo '[ ! -e /run/scansnap-maintenance ] || exit 0'; tail -n +2 "$BUTTON"; } > "$STAGE/guard-button"
  install -o root -g root -m755 "$STAGE/guard-button" "$BUTTON"
fi
touch /run/scansnap-maintenance
trap 'rm -f /run/scansnap-maintenance; systemctl start scanbd' EXIT
# Let actions already launched before the guard reach their scan process.
sleep 1
if pgrep -u "$SCAN_USER" -f "(bash $SCAN_HOME/bin/scansnap-upload|scansnap-queue.py capture)" >/dev/null; then
  echo 'A scan/upload is active; wait for completion before deploying.' >&2; exit 3
fi
for state in capturing queued processing; do
  if [[ -d "$SCAN_HOME/scansnap-spool/$state" ]] && [[ -n "$(ls -A "$SCAN_HOME/scansnap-spool/$state")" ]]; then
    echo 'Queue is not empty; wait for completion before deploying.' >&2; exit 3
  fi
done
for script in "$STAGE"/pi/bin/*.sh; do bash -n "$script"; done
python3 -m py_compile "$STAGE/pi/bin/scansnap-queue.py" "$STAGE/pi/libexec/scansnap-status-led.py"
systemctl stop "scansnap-worker@$SCAN_USER.service" 2>/dev/null || true
systemctl stop scanbd
install -d -o "$SCAN_USER" -g "$SCAN_USER" -m755 "$SCAN_HOME/bin" "$SCAN_HOME/.config/scansnap"
# Preserve existing credentials. Adapt a legacy owncloud.env through a new,
# protected config file without printing or copying its values.
if [[ ! -e "$SCAN_HOME/.config/scansnap/scansnap.env" ]]; then
  if [[ -e "$SCAN_HOME/.config/scansnap/owncloud.env" ]]; then
    python3 - "$SCAN_HOME" <<'PY'
from pathlib import Path
import re, shlex, sys
home=Path(sys.argv[1])
old=(home/'bin/scansnap-upload.sh').read_text()
match=re.search(r'^(?:SCANNER_DEVICE|DEVICE)=["\'](fujitsu:[^"\']+)["\']',old,re.M)
if not match:
    raise SystemExit('Cannot migrate scanner ID automatically; existing configuration preserved')
config=home/'.config/scansnap/scansnap.env'
lines=['source "$HOME/.config/scansnap/owncloud.env"', 'SCANNER_DEVICE='+shlex.quote(match.group(1))]
for key in ('SOURCE','MODE','RESOLUTION','PAGE_WIDTH','PAGE_HEIGHT','BLANK_THRESHOLD','JPEG_QUALITY'):
    matches=re.findall(r'^'+key+r'=(.*)$',old,re.M)
    for value in matches:
        if '$' in value or '`' in value:
            continue
        values=shlex.split(value,comments=True)
        if len(values)==1:
            lines.append(key+'='+shlex.quote(values[0]))
config.write_text('\n'.join(lines)+'\n')
config.chmod(0o600)
PY
  else
    install -m600 "$STAGE/pi/config/scansnap.env.example" "$SCAN_HOME/.config/scansnap/scansnap.env"
  fi
  chown "$SCAN_USER:$SCAN_USER" "$SCAN_HOME/.config/scansnap/scansnap.env"
fi
for script in "$STAGE"/pi/bin/*; do
  [[ -f "$script" ]] || continue
  if [[ "$(basename "$script")" == scansnap-normalize-image.sh && -f "$SCAN_HOME/bin/scansnap-normalize-image.sh" ]]; then continue; fi
  install -o "$SCAN_USER" -g "$SCAN_USER" -m755 "$script" "$SCAN_HOME/bin/$(basename "$script")"
done
install -d -m755 /usr/local/libexec
install -o root -g root -m755 "$STAGE/pi/libexec/scansnap-status-led.py" /usr/local/libexec/scansnap-status-led
sed "s/^scansnap ALL/$SCAN_USER ALL/" "$STAGE/pi/etc/sudoers.d/scansnap-led" > "$STAGE/led-sudoers"
sed "s/(scansnap)/($SCAN_USER)/;s|/home/scansnap|$SCAN_HOME|g" "$STAGE/pi/etc/sudoers.d/scanbd-scansnap" > "$STAGE/scan-sudoers"
visudo -cf "$STAGE/led-sudoers"
visudo -cf "$STAGE/scan-sudoers"
install -o root -g root -m440 "$STAGE/led-sudoers" /etc/sudoers.d/scansnap-led
install -o root -g root -m440 "$STAGE/scan-sudoers" /etc/sudoers.d/scanbd-scansnap
sed "s|-u scansnap|-u $SCAN_USER|;s|/home/scansnap|$SCAN_HOME|g" "$STAGE/pi/etc/scanbd/scripts/scansnap-scan.sh" > "$STAGE/button-script"
install -m755 "$STAGE/button-script" /etc/scanbd/scripts/scansnap-scan.sh
install -m644 "$STAGE/pi/etc/scanbd/dll.conf" /etc/scanbd/dll.conf
install -m644 "$STAGE/pi/etc/scanbd/scanner.d/fujitsu.conf" /etc/scanbd/scanner.d/fujitsu.conf
install -m644 "$STAGE/pi/etc/udev/rules.d/79-scansnap-ix500.rules" /etc/udev/rules.d/79-scansnap-ix500.rules
sed "s|/home/scansnap|$SCAN_HOME|;s/create 0644 scansnap scansnap/create 0644 $SCAN_USER $SCAN_USER/" "$STAGE/pi/etc/logrotate.d/scansnap" > "$STAGE/logrotate"
install -m644 "$STAGE/logrotate" /etc/logrotate.d/scansnap
install -m644 "$STAGE/pi/etc/systemd/system/"*.service /etc/systemd/system/
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger
systemctl enable --now scansnap-status-led.service
systemctl enable --now "scansnap-worker@$SCAN_USER.service"
rm -f /run/scansnap-maintenance
systemctl start scanbd
trap - EXIT
echo "Installed capture queue and worker for $SCAN_USER. Legacy pending/failed PDFs preserved."
