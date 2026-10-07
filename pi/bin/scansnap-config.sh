#!/usr/bin/env bash
# Shared config loader, including installations predating the public release.
SCANSNAP_CONFIG="${SCANSNAP_CONFIG:-${HOME}/.config/scansnap/scansnap.env}"
if [[ ! -r "$SCANSNAP_CONFIG" ]]; then
  echo "ERROR: $SCANSNAP_CONFIG is not readable" >&2
  return 2
fi
set -a
source "$SCANSNAP_CONFIG"
set +a
export WEBDAV_URL="${WEBDAV_URL:-${OWNCLOUD_WEBDAV_URL:-}}"
export WEBDAV_USER="${WEBDAV_USER:-${OWNCLOUD_USER:-}}"
export WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-${OWNCLOUD_PASSWORD:-}}"
