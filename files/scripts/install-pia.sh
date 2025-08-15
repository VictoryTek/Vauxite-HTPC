#!/usr/bin/env bash
# install-pia.sh - Attempt unattended installation of Private Internet Access VPN client.
# Strategy:
#   1. Prefer official package repository (RPM / APT) for updates & non-interactive install.
#   2. Fallback to the .run installer if repo method unavailable (may require GUI / interaction).
# Supports running inside a BlueBuild / rpm-ostree based image OR a mutable system.
#
# Usage (mutable host): sudo ./install-pia.sh
# Usage (BlueBuild compose stage): run as root during build, or ship this script and execute post-boot.
# Env overrides:
#   PIA_VERSION   - set target version for .run fallback (default below)
#   FORCE_METHOD  - set to 'run' to skip repo attempt, or 'repo' to skip fallback
#   PIA_SHA256    - expected sha256 of the .run file to enforce integrity
#   NON_INTERACTIVE=1 - skip any optional prompts (best effort)

set -euo pipefail

PIA_VERSION="${PIA_VERSION:-3.6.2-08398}"
RUN_NAME="pia-linux-${PIA_VERSION}.run"
RUN_URL="https://installers.privateinternetaccess.com/download/${RUN_NAME}"
FORCE_METHOD="${FORCE_METHOD:-}"    # repo | run | (empty)
PIA_SHA256="${PIA_SHA256:-}"         # provide to verify integrity
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

log()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
err()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; }

need_root() { if [[ $EUID -ne 0 ]]; then err "Run as root"; exit 1; fi; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_atomic() { have_cmd rpm-ostree; }

add_repo_rpm() {
    log "Adding PIA RPM repository"
    cat >/etc/yum.repos.d/pia.repo <<'EOF'
[piavpn]
name=Private Internet Access
baseurl=https://installers.privateinternetaccess.com/repos/rpm
enabled=1
gpgcheck=1
gpgkey=https://installers.privateinternetaccess.com/repos/rpm/gpg
EOF
}

add_repo_deb() {
    log "Adding PIA APT repository"
    install -d /usr/share/keyrings
    curl -fsSL https://installers.privateinternetaccess.com/repos/apt/gpg | gpg --dearmor -o /usr/share/keyrings/pia-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/pia-archive-keyring.gpg] https://installers.privateinternetaccess.com/repos/apt stable main" \
        >/etc/apt/sources.list.d/pia.list
}

install_repo_rpm_mutable() {
    add_repo_rpm
    if have_cmd dnf; then dnf install -y pia-client; else yum install -y pia-client; fi
}

install_repo_rpm_atomic() {
    # For rpm-ostree systems, layer the package. Requires reboot afterward.
    add_repo_rpm
    if have_cmd rpm-ostree; then
        rpm-ostree install -y pia-client || return 1
        warn "rpm-ostree install queued. Reboot required to finalize PIA client layer."
    else
        return 1
    fi
}

install_repo_deb() {
    add_repo_deb
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y pia-client
}

try_repo_install() {
    if [[ "$FORCE_METHOD" == "run" ]]; then return 1; fi
    if have_cmd rpm || have_cmd dnf || have_cmd yum; then
        if is_atomic; then
            install_repo_rpm_atomic || return 1
        else
            install_repo_rpm_mutable || return 1
        fi
        return 0
    elif have_cmd apt-get; then
        install_repo_deb || return 1
        return 0
    fi
    return 1
}

fallback_run_install() {
    if [[ "$FORCE_METHOD" == "repo" ]]; then
        err "Forced repo method but repo install failed. Aborting."; exit 1
    fi
    warn "Falling back to .run installer (may be interactive)."
    if [[ ! -f $RUN_NAME ]]; then
        log "Downloading ${RUN_NAME}"
        curl -fSL "$RUN_URL" -o "$RUN_NAME"
    else
        log "Using existing ${RUN_NAME}"
    fi
    if [[ -n "$PIA_SHA256" ]]; then
        echo "${PIA_SHA256}  ${RUN_NAME}" | sha256sum -c -
    else
        warn "No checksum provided. Supply PIA_SHA256 to verify integrity."
    fi
    chmod +x "$RUN_NAME"
    # Attempt a headless / reduced UI mode first if accepted.
    set +e
    ./${RUN_NAME} --nox11 --accept || ./${RUN_NAME}
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        err ".run installer failed (exit $rc)."; exit $rc
    fi
}

post_install_notes() {
    echo
    log "PIA installed. Next steps:"
    echo "  1. Run: piactl login   (interactive; requires credentials or token)"
    echo "  2. Then: piactl set protocol wireguard (optional)"
    echo "  3. Auto-connect: piactl set auto_connect true"
    if is_atomic; then
        echo "  * If rpm-ostree layering was used, reboot before using piactl."
    fi
    echo
}

main() {
    need_root
    log "Starting PIA installation workflow (version ${PIA_VERSION})"
    if try_repo_install; then
        log "Installed via package repository."
    else
        fallback_run_install
    fi
    post_install_notes
}

main "$@"
