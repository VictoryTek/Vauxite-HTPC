#!/usr/bin/env bash
set -oue pipefail

# Enable Background Logo GNOME extension
gnome-extensions enable background-logo@fedorahosted.org || true
