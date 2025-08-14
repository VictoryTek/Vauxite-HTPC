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

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36 BlueBuild-PIA-Install/1.0"
REF="https://www.privateinternetaccess.com/"
PIA_DOWNLOAD_URL_OVERRIDE="${PIA_DOWNLOAD_URL_OVERRIDE:-}"

download_installer() {
    local url="$1" out="$2"
    echo "[PIA] Attempt download: $url"
    # Use --retry for transient network issues, capture HTTP code for diagnostics
    HTTP_CODE=$(curl -w "%{http_code}" -A "$UA" -H "Referer: $REF" --retry 5 --retry-delay 2 \
        --retry-connrefused -fsSL -o "$out" "$url" 2>"$out.download.log" || true)
    if [ "$HTTP_CODE" != "200" ]; then
        echo "[PIA] Download failed (HTTP $HTTP_CODE) for $url" >&2
        cat "$out.download.log" >&2 || true
        rm -f "$out"
        return 1
    fi
    return 0
}

if [ -n "$PIA_DOWNLOAD_URL_OVERRIDE" ]; then
    echo "[PIA] Using override URL: $PIA_DOWNLOAD_URL_OVERRIDE"
    if ! download_installer "$PIA_DOWNLOAD_URL_OVERRIDE" "$PIA_RUN"; then
        echo "[PIA] Override URL download failed" >&2; exit 1; fi
else
    echo "[PIA] Downloading PIA .run installer: $PIA_RUN"
    if ! download_installer "${BASE_URL}/${PIA_RUN}" "$PIA_RUN"; then
        echo "[PIA] Primary versioned download failed; trying 'latest' fallback" >&2
        LATEST_RUN="pia-linux-latest.run"
        if download_installer "${BASE_URL}/${LATEST_RUN}" "$LATEST_RUN"; then
            echo "[PIA] Fallback succeeded with latest; using $LATEST_RUN"
            PIA_RUN="$LATEST_RUN"
            PIA_VERSION="latest"
        else
            echo "[PIA] Fallback to latest failed" >&2
            exit 1
        fi
    fi
fi

if [ -n "$PIA_SHA256" ]; then
    echo "[PIA] Verifying checksum"
    echo "$PIA_SHA256  $PIA_RUN" | sha256sum -c - || { echo "[PIA] Checksum mismatch" >&2; exit 1; }
fi

chmod +x "$PIA_RUN"
echo "[PIA] Preparing environment for non-interactive install"

# Provide a stub systemctl to prevent failures when installer tries to start/enable services inside build container
STUB_DIR="/tmp/pia-systemctl-stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl stub] $@ (no-op during image build)"
exit 0
EOF
chmod +x "$STUB_DIR/systemctl"
export PATH="$STUB_DIR:$PATH"

LOG_FILE="/var/log/pia-install.log"
echo "[PIA] Running installer non-interactively (logging to $LOG_FILE)"
if ./$PIA_RUN --nox11 --accept 2>&1 | tee "$LOG_FILE"; then
    INSTALLED_VIA="run"
else
    STATUS=$?
    echo "[PIA] Installer failed, tail of log:" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit $STATUS
fi

# Remove stub from PATH for subsequent steps (keep log)
PATH="${PATH#${STUB_DIR}:}"

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
