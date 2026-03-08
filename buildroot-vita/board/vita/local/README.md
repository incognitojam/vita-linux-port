# Local overlay (not committed)

This directory is a second rootfs overlay applied after `board/vita/overlay/`.
Everything here is gitignored. Place files using the same directory structure
as the target rootfs — they will be copied directly.

## Typical contents

### `etc/wpa_supplicant.conf` — WiFi credentials

```
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="YourNetworkName"
    psk="YourPassword"
}
```

### `root/.ssh/authorized_keys` — SSH public keys for root login

```
ssh-ed25519 AAAA... user@host
```

### `etc/ssh/ssh_host_*_key` — Pre-generated SSH host keys

Avoids slow key generation on boot. Generate once:

```sh
ssh-keygen -t ed25519 -f etc/ssh/ssh_host_ed25519_key -N ""
ssh-keygen -t ecdsa -f etc/ssh/ssh_host_ecdsa_key -N ""
ssh-keygen -t rsa -b 4096 -f etc/ssh/ssh_host_rsa_key -N ""
```

If not provided, openssh will generate them on first boot.
