#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - First Boot Initialization
# Generates unique machine-id and SSH host keys, logs fingerprints,
# validates SSH config, and sets up completion marker.
# ==============================================================================

echo "m80ta-firstboot: starting first boot initialization..." | logger -t m80ta-firstboot

# 1. Generate unique machine-id if missing or empty
if [ ! -s /etc/machine-id ]; then
    echo "m80ta-firstboot: generating unique machine-id..." | logger -t m80ta-firstboot
    systemd-machine-id-setup
fi

# 2. Generate unique SSH host keys if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "m80ta-firstboot: generating unique SSH host keys..." | logger -t m80ta-firstboot
    ssh-keygen -A
fi

# 3. Log SSH host key fingerprints to journal
echo "m80ta-firstboot: SSH host key fingerprints:" | logger -t m80ta-firstboot
for pubkey in /etc/ssh/ssh_host_*_key.pub; do
    if [ -f "$pubkey" ]; then
        fp=$(ssh-keygen -l -f "$pubkey")
        echo "m80ta-firstboot: $fp" | logger -t m80ta-firstboot
    fi
done

# 4. Validate SSH daemon configuration
if command -v sshd >/dev/null 2>&1; then
    sshd -t || {
        echo "m80ta-firstboot: ERROR: sshd -t validation failed!" | logger -t m80ta-firstboot
        exit 1
    }
fi

# 5. Ensure user vivotab ownership, permissions, and GPU render group
if id vivotab >/dev/null 2>&1; then
    chown -R 1000:1000 /home/vivotab
    if [ -d /home/vivotab/.ssh ]; then
        chmod 700 /home/vivotab/.ssh
        if [ -f /home/vivotab/.ssh/authorized_keys ]; then
            chmod 600 /home/vivotab/.ssh/authorized_keys
        fi
    fi
    usermod -aG render vivotab 2>/dev/null || true
fi

echo "m80ta-firstboot: initialization successfully completed." | logger -t m80ta-firstboot
