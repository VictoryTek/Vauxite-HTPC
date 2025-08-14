#!/usr/bin/env bash
# Minimal PIA install script for BlueBuild image builds.
# Default: deferred install at first boot to avoid CI download blocks.
# Set PIA_INSTALL_MODE=eager to try installing during build (falls back to deferred if it fails).

set -euo pipefail

PIA_URL="${PIA_DOWNLOAD_URL_OVERRIDE:-https://installers.privateinternetaccess.com/download/pia-linux-latest.run}"
PIA_RUN="$(basename "$PIA_URL")"
PIA_INSTALL_MODE="${PIA_INSTALL_MODE:-deferred}" # deferred|eager
STUB_DIR="/tmp/pia-systemctl-stub"

log() { echo "[PIA] $*"; }

if [ "$PIA_INSTALL_MODE" = "eager" ]; then
  log "Eager mode: attempting build-time install from $PIA_URL"
  if curl -fL --retry 3 --retry-delay 2 -o "/tmp/$PIA_RUN" "$PIA_URL"; then
    log "Download ok"
    chmod +x "/tmp/$PIA_RUN"
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl stub] $@ (no-op in image build)"
exit 0
EOF
    chmod +x "$STUB_DIR/systemctl"
    export PATH="$STUB_DIR:$PATH"
    if "/tmp/$PIA_RUN" --nox11 --accept; then
      log "Installed during build"
      if [ -x /opt/piavpn/bin/pia-client ] && [ ! -e /usr/bin/pia-client ]; then
        ln -s /opt/piavpn/bin/pia-client /usr/bin/pia-client || true
      fi
      SERVICE="pia-daemon.service"
      if [ -f "/usr/lib/systemd/system/$SERVICE" ] || [ -f "/etc/systemd/system/$SERVICE" ]; then
        TARGET_DIR="/usr/lib/systemd/system/multi-user.target.wants"
        mkdir -p "$TARGET_DIR"
        ln -sf "../$SERVICE" "$TARGET_DIR/$SERVICE"
      fi
      DONE_NOW=1
    else
      log "Installer execution failed (switching to deferred)" >&2
    fi
  else
    log "Download failed (switching to deferred)" >&2
  fi
else
  log "Deferred mode: skipping build-time download"
fi

if [ -z "${DONE_NOW:-}" ]; then
  log "Setting up deferred first-boot installation"
  install -d /usr/local/libexec
  cat > /usr/local/libexec/pia-deferred-install.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
URL="${PIA_DOWNLOAD_URL_OVERRIDE:-https://installers.privateinternetaccess.com/download/pia-linux-latest.run}"
RUN_FILE="$(basename "$URL")"
LOG=/var/log/pia-firstboot.log
echo "[PIA-firstboot] Downloading $URL" | tee -a "$LOG"
if curl -fL -o "/tmp/$RUN_FILE" "$URL"; then
  chmod +x "/tmp/$RUN_FILE"
  echo "[PIA-firstboot] Running installer" | tee -a "$LOG"
  if "/tmp/$RUN_FILE" --nox11 --accept >>"$LOG" 2>&1; then
    echo "[PIA-firstboot] Success" | tee -a "$LOG"
    exit 0
  fi
fi
echo "[PIA-firstboot] Failed" | tee -a "$LOG"
exit 1
EOS
  chmod +x /usr/local/libexec/pia-deferred-install.sh
  cat > /usr/lib/systemd/system/pia-deferred-install.service <<'EOF'
[Unit]
Description=Deferred PIA Client Installation
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/piavpn

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/pia-deferred-install.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /usr/lib/systemd/system/multi-user.target.wants
  ln -sf ../pia-deferred-install.service /usr/lib/systemd/system/multi-user.target.wants/pia-deferred-install.service
  log "Deferred install unit created"
fi

if [ "$PIA_INSTALL_MODE" = "eager" ] && [ -n "${DONE_NOW:-}" ]; then
  log "Script complete (installed during build)"
else
  log "Script complete (installation will occur at first boot)"
fi
