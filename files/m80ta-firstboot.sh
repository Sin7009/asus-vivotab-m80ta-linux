#!/bin/bash
set -euo pipefail

# First-boot initialization for Asus VivoTab Note 8 (M80TA)

# 1. Generate unique machine-id if missing
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup
fi

# 2. Generate unique SSH host keys (only if missing)
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "Generating unique SSH host keys..."
    ssh-keygen -A
fi

# 3. Ensure proper permissions on user home
if [ -d /home/vivotab ]; then
    chown -R vivotab:vivotab /home/vivotab
fi

echo "M80TA firstboot setup completed."
