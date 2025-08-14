#!/usr/bin/env bash
# Non-interactive Private Internet Access (PIA) client install for BlueBuild image creation.
# This runs inside the container build as root, so avoid sudo & any interactive prompts.

set -euo pipefail

PIA_VERSION="${PIA_VERSION:-3.5.2-06924}" # allow override at build time
BASE_URL="https://installers.privateinternetaccess.com/download"
LANDING_URLS=(
    "https://www.privateinternetaccess.com/"
    "https://www.privateinternetaccess.com/pages/download"
    "https://www.privateinternetaccess.com/installer/download/linux"
)
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
        HTTP_CODE=$(curl -w "%{http_code}" -A "$UA" -H "Referer: $REF" \
                -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
                -H "Accept-Language: en-US,en;q=0.5" \
                --retry 5 --retry-delay 2 --retry-connrefused -fsSL -o "$out" "$url" 2>"$out.download.log" || true)
    if [ "$HTTP_CODE" != "200" ]; then
        echo "[PIA] Download failed (HTTP $HTTP_CODE) for $url" >&2
        cat "$out.download.log" >&2 || true
        rm -f "$out"
        return 1
    fi
    return 0
}

scrape_dynamic_url() {
    echo "[PIA] Attempting to scrape dynamic download URL from landing pages"
    local page tmp match line
    for page in "${LANDING_URLS[@]}"; do
        echo "[PIA] Fetch landing page: $page"
        tmp=$(mktemp)
        if curl -fsSL -A "$UA" -H "Referer: $REF" "$page" -o "$tmp"; then
            # Search for pia-linux-<ver>.run pattern
            match=$(grep -Eo 'https[^"'"'']+pia-linux-[0-9]\.[0-9]+\.[0-9]+-[0-9]+\.run' "$tmp" | head -n1 || true)
            if [ -n "$match" ]; then
                echo "[PIA] Found dynamic URL: $match"
                echo "$match"
                rm -f "$tmp"
                return 0
            fi
            # Try generic latest reference
            match=$(grep -Eo 'https[^"'"'']+pia-linux-latest\.run' "$tmp" | head -n1 || true)
            if [ -n "$match" ]; then
                echo "[PIA] Found dynamic latest URL: $match"
                echo "$match"
                rm -f "$tmp"
                return 0
            fi
        fi
        rm -f "$tmp"
    done
    return 1
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
            echo "[PIA] Fallback to latest failed; trying dynamic scrape" >&2
            DYNAMIC_URL=$(scrape_dynamic_url || true)
            if [ -n "$DYNAMIC_URL" ]; then
                # Derive file name from URL
                PIA_RUN="$(basename "$DYNAMIC_URL")"
                if download_installer "$DYNAMIC_URL" "$PIA_RUN"; then
                    echo "[PIA] Dynamic scrape download succeeded: $PIA_RUN"
                else
                    echo "[PIA] Dynamic scraped URL failed to download" >&2
                fi
            fi
            if [ ! -f "$PIA_RUN" ]; then
                #!/usr/bin/env bash
                # Minimal PIA installer for BlueBuild.
                # Goal: Keep build simple. If direct download (403) fails, defer install to first boot.

                set -euo pipefail

                PIA_URL="${PIA_DOWNLOAD_URL_OVERRIDE:-https://installers.privateinternetaccess.com/download/pia-linux-latest.run}"
                PIA_RUN="$(basename "$PIA_URL")"

                echo "[PIA] Attempting direct download: $PIA_URL"
                if curl -fL --retry 3 --retry-delay 2 -o "/tmp/$PIA_RUN" "$PIA_URL"; then
                    echo "[PIA] Download succeeded during build"
                    chmod +x "/tmp/$PIA_RUN"
                    # Stub systemctl so installer doesn't fail in container
                    STUB_DIR="/tmp/pia-systemctl-stub"
                    mkdir -p "$STUB_DIR"
                    cat > "$STUB_DIR/systemctl" <<'EOF'
                #!/usr/bin/env bash
                echo "[systemctl stub] $@ (no-op in build)"
                exit 0
                EOF
                    chmod +x "$STUB_DIR/systemctl"
                    export PATH="$STUB_DIR:$PATH"

                    echo "[PIA] Running installer"
                    if "/tmp/$PIA_RUN" --nox11 --accept; then
                        echo "[PIA] Installer finished"
                    else
                        echo "[PIA] Installer failed (will defer to first boot)" >&2
                        DEFER=1
                    fi
                else
                    echo "[PIA] Download failed (will defer to first boot)" >&2
                    DEFER=1
                fi

                if [ "${DEFER:-0}" = 1 ]; then
                    echo "[PIA] Setting up deferred first-boot install"
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
                    echo "[PIA] Deferred install unit created"
                else
                    # Post-install conveniences (only if we actually installed now)
                    if [ -x /opt/piavpn/bin/pia-client ] && [ ! -e /usr/bin/pia-client ]; then
                        ln -s /opt/piavpn/bin/pia-client /usr/bin/pia-client || true
                    fi
                    SERVICE="pia-daemon.service"
                    if [ -f "/usr/lib/systemd/system/$SERVICE" ] || [ -f "/etc/systemd/system/$SERVICE" ]; then
                        TARGET_DIR="/usr/lib/systemd/system/multi-user.target.wants"
                        mkdir -p "$TARGET_DIR"
                        ln -sf "../$SERVICE" "$TARGET_DIR/$SERVICE"
                    fi
                fi

                echo "[PIA] Done (immediate install ${DEFER:+skipped -> deferred})"
