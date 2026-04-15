# matrix-backend

**Hardened NixOS server infrastructure for a self-hosted Matrix homeserver — federated, privacy-respecting messaging with voice and video.**

*Secrets encrypted at rest with sops-nix.  Cryptographically verified boot chain with Lanzaboote.  Flake-based CI.*

*Admin access restricted to Tailscale mesh VPN.  Matrix federation traffic on 443*

***100% reproducible from this repository.***

[![flake check](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml/badge.svg)](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml) [![NixOS](https://img.shields.io/badge/NixOS-25.11-5277C3?logo=nixos&logoColor=white)](https://nixos.org) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

> [!NOTE]
> The Matrix homeserver itself is under active development and not yet deployed.
>
> This repository currently consists of the hardened NixOS server infrastructure it will run on.

---

**[Installation](#Installation) · [Rebuilding](#Rebuilding) · [Security overview](#Security) · [Roadmap](#Roadmap)**

## Installation

> [!TIP]
> Recommended: run this as a KVM virtual machine on a host with an encrypted ZFS pool.
> KVM gives near-bare-metal performance with hardware passthrough support; ZFS encryption provides full disk encryption at the pool level without touching this repo's configuration or install process.

> [!NOTE]
> `disko.nix` is configured to format `/dev/sda`. Make sure you know what drive you actually want to use and adjust `disko.nix` accordingly.
> 
> `systemd.network` is configured to use `192.168.1.1` as the gateway and `192.168.1.101/24` as matrix-backend's IP address. Make sure you know what gateway and IP address you actually want to use and adjust `systemd.network` accordingly.

In the NixOS installer:

```
passwd nixos # use a 7+ word passphrase
```

From your dev machine:

```
# replace TARGET_HOST_IP:

ssh nixos@TARGET_HOST_IP
```

While ssh'ed into the installer:

```
sudo -i
```

```
git clone https://github.com/jx-wi/matrix-backend.git
nixos-generate-config --root /mnt --no-filesystems --dir matrix-backend
nix --experimental-features "nix-command flakes" run nixpkgs#disko -- --mode destroy,format,mount matrix-backend/disko.nix
mkdir -p /mnt/etc/nixos
cp -a matrix-backend/. /mnt/etc/nixos
nixos-install --flake /mnt/etc/nixos#matrix-backend
nixos-enter --command "sbctl create-keys"
nixos-install --flake /mnt/etc/nixos#matrix-backend
exit
```

```
exit
```

After the second `exit`, inject the SSH host key from your dev machine (with age key loaded):

```
# replace REPO_DIR and TARGET_HOST_IP

cd REPO_DIR

sops --extract '["ssh_host_ed25519_key"]' -d secrets/matrix-backend/ssh.yaml \
  | ssh nixos@TARGET_HOST_IP \
    "sudo tee /mnt/etc/ssh/ssh_host_ed25519_key > /dev/null && sudo chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key"
```

If all seems well, reboot the matrix machine.

After rebooting, login / ssh in and run:

```
sudo sbctl enroll-keys --microsoft
```

## Rebuilding

While ssh'ed into matrix-backend:

```
nh os switch github:jx-wi/matrix-backend
```

## Security

- Kernel image protection and module locking (`protectKernelImage`, `lockKernelModules`)
- Tailscale mesh VPN — admin/SSH access plane; Matrix federation traffic on 443
- sops-nix/age encryption — secrets never stored in plaintext; multi-recipient (admin + host keys)
- Lanzaboote — cryptographically verified boot chain (replaces standard systemd-boot)
- sudo-rs — memory-safe Rust reimplementation of sudo
- Key-only SSH, root login disabled, `su root` locked
- Immutable declarative users (`mutableUsers = false`) — no out-of-band state
- Encrypted swap with random key per boot
- fail2ban brute-force protection

## Roadmap

#### Infrastructure
- [X] Hardened NixOS server baseline
- [ ] Matrix homeserver (Tuwunel)
- [ ] coturn TURN server — voice, video, and screensharing relay
- [ ] Federation — open 443, DNS SRV records

#### Custom features
- [ ] Tiered storage — 1G default, 16G core member, 128G admin; uploads routed to personal cloud storage, attachments render as linked previews in chat
- [ ] Cinematic mode screensharing — single priority stream upgrades to 2K@60fps via admin grant, sole-stream detection, or vote
- [ ] Soundboard — integrates with user storage, custom pop-up UI for direct audio playback into calls

