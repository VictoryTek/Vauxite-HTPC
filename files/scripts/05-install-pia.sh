#!/usr/bin/env bash
# Non-interactive Private Internet Access (PIA) client install for BlueBuild image creation.
# This runs inside the container build as root, so avoid sudo & any interactive prompts.

set -euo pipefail

PIA_VERSION="${PIA_VERSION:-3.5.2-06924}" # allow override at build time
BASE_URL="https://installers.privateinternetaccess.com/download"
PIA_RUN="pia-linux-${PIA_VERSION}.run"

# Optional: provide SHA256 to verify (set PIA_SHA256 externally if desired)
PIA_SHA256="${PIA_SHA256:-}"

WORKDIR="/tmp/pia-install"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[PIA] Downloading PIA .run installer: $PIA_RUN"
curl -fsSL -o "$PIA_RUN" "${BASE_URL}/${PIA_RUN}" || { echo "[PIA] Download failed" >&2; exit 1; }

if [ -n "$PIA_SHA256" ]; then
    echo "[PIA] Verifying checksum"
    echo "$PIA_SHA256  $PIA_RUN" | sha256sum -c - || { echo "[PIA] Checksum mismatch" >&2; exit 1; }
fi

chmod +x "$PIA_RUN"
echo "[PIA] Running installer non-interactively"
if ./$PIA_RUN --nox11 --accept >/dev/null 2>&1; then
    INSTALLED_VIA="run"
else
    echo "[PIA] Installer failed" >&2
    exit 1
fi

# Post-install validation
CLIENT_BIN="/opt/piavpn/bin/pia-client"
if ! command -v pia-client >/dev/null 2>&1; then
    if [ -x "$CLIENT_BIN" ]; then
        ln -sf "$CLIENT_BIN" /usr/bin/pia-client
    fi
fi

if ! command -v pia-client >/dev/null 2>&1; then
    echo "[PIA] pia-client binary not found after installation" >&2
    exit 1
fi

echo "[PIA] Installed via: $INSTALLED_VIA"

# Enable the daemon service at boot by creating the wants symlink (systemctl not available during build)
SERVICE="pia-daemon.service"
if [ -f "/usr/lib/systemd/system/${SERVICE}" ] || [ -f "/etc/systemd/system/${SERVICE}" ]; then
    TARGET_DIR="/usr/lib/systemd/system/multi-user.target.wants"
    mkdir -p "$TARGET_DIR"
    ln -sf "../${SERVICE}" "${TARGET_DIR}/${SERVICE}"
    echo "[PIA] Enabled ${SERVICE} via symlink"
else
    echo "[PIA] Warning: ${SERVICE} not found; service may not have been installed (headless CLI only?)"
fi

# Clean up build workspace (artifacts not needed in final image)
rm -rf "$WORKDIR"

echo "[PIA] Installation complete."
