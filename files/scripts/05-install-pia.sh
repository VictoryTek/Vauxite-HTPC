#!/usr/bin/env bash
set -oue pipefail

set -e

PIA_URL="https://installers.privateinternetaccess.com/download/pia-linux-3.5.2-06924.run"
PIA_INSTALLER="pia-linux-3.5.2-06924.run"

# Download the PIA installer
if [ ! -f "$PIA_INSTALLER" ]; then
    echo "Downloading PIA installer..."
    wget "$PIA_URL" -O "$PIA_INSTALLER"
else
    echo "PIA installer already downloaded."
fi

# Make the installer executable
chmod +x "$PIA_INSTALLER"

echo "Running PIA installer..."
sudo ./$PIA_INSTALLER

echo "PIA installation complete."
