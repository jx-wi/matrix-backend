# matrix-backend

**Hardened NixOS server infrastructure for a self-hosted, private Matrix homeserver — privacy-respecting messaging with voice and video.**

*Secrets encrypted at rest with sops-nix.  Cryptographically verified boot chain with Lanzaboote.  Flake-based CI.*

*Admin access restricted to Tailscale mesh VPN.  Matrix client traffic on 443.*

***100% reproducible from this repository.***

[![flake check](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml/badge.svg)](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml) [![NixOS](https://img.shields.io/badge/NixOS-25.11-5277C3?logo=nixos&logoColor=white)](https://nixos.org) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

**[Installation](#Installation) · [Initial account creation](#Initialization) · [Rebuilding](#Rebuilding) · [Security overview](#Security) · [Roadmap](#Roadmap)**

## Installation

> [!TIP]
> Recommended: run this as a KVM virtual machine on a host with an encrypted ZFS pool.
> KVM gives near-bare-metal performance with hardware passthrough support; ZFS encryption provides full disk encryption at the pool level without touching this repo's configuration or install process.

> [!NOTE]
> `disko.nix` is configured to format `/dev/sda`. Make sure you know what drive you actually want to use and adjust `disko.nix` accordingly.
>
> `systemd.network` in `configuration.nix` is configured to use `192.168.0.1` as the gateway and `192.168.0.101/24` as matrix-backend's IP address. Make sure you know what gateway and IP address you actually want to use and adjust `systemd.network` accordingly.

> [!NOTE]
> Before deploying, set the following variables at the top of `configuration.nix`:
> - `homeserver` — your domain
> - `dnsProvider` — your ACME DNS challenge provider ([supported providers](https://go-acme.github.io/lego/dns/))
> - `dnsTokenEnvVar` — the env var your DNS provider's lego driver expects for its API token

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
nix --experimental-features "nix-command flakes" run nixpkgs#disko -- --mode destroy,format,mount matrix-backend/disko.nix
nixos-generate-config --root /mnt --no-filesystems --dir matrix-backend
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

> [!NOTE]
> The SSH host key is injected manually rather than managed by sops-nix at runtime. This is a bootstrapping requirement: sops-nix derives its age decryption key from the host's SSH key, so the SSH key must already exist before sops can decrypt any secret — including itself.

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

## Initialization

Registration is disabled by default. To create the initial admin account:

1. SSH into matrix-backend
2. Edit `/etc/nixos/configuration.nix`, set `allow_registration = true` inside `services.matrix-tuwunel.settings.global`
3. Rebuild: `nh os switch /etc/nixos`
4. In your Matrix client, connect to your homeserver URL and register using the registration token. The first account registered is automatically an admin.
5. Set `allow_registration = false` and rebuild again.

## Rebuilding

While ssh'ed into matrix-backend:

```
nh os switch github:jx-wi/matrix-backend
```

> [!NOTE]
> This also runs automatically. A systemd timer fires every Monday at 9am (server local time) and runs the same command against the live repo. To disable automatic updates, remove `systemd.timers.nh-os-switch` and `systemd.services.nh-os-switch` from `configuration.nix`.

## Security

- Kernel image protection and module locking (`protectKernelImage`, `lockKernelModules`)
- Tailscale mesh VPN — admin/SSH access plane only; Matrix client traffic on 443
- Firewall — ingress limited to TCP 80 (HTTP→HTTPS redirect), 443 (Matrix/LiveKit), 7881 (LiveKit RTC), UDP 443 (HTTP/3), 50000–60000 (LiveKit WebRTC), and the Tailscale port; everything else dropped
- sops-nix/age encryption — secrets never stored in plaintext; multi-recipient (admin + host keys)
- Lanzaboote — cryptographically verified boot chain (replaces standard systemd-boot)
- sudo-rs — memory-safe Rust reimplementation of sudo
- Key-only SSH, root login disabled, `su root` locked
- Immutable declarative users (`mutableUsers = false`) — no out-of-band state
- Encrypted swap with random key per boot (on-disk swapfile); zram swap enabled (75% RAM, zstd)
- fail2ban brute-force protection
- Caddy — HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy on all responses; HTTP → HTTPS redirect (automatic); Server header not emitted
- CI tool versions pinned by commit hashes

## Roadmap

#### Infrastructure
- [X] Hardened NixOS server baseline
- [X] Matrix homeserver (Tuwunel)
- [X] LiveKit SFU — voice, video, and screensharing (MatrixRTC / Element Call)
- [ ] Federation — domain, DNS SRV records, enable server-to-server traffic

#### Custom features
- [ ] Tiered storage — 1G default, 16G core member, 128G admin; uploads routed to personal cloud storage, attachments render as linked previews in chat
- [ ] Cinematic mode screensharing — single priority stream upgrades to 2K@60fps via admin grant, sole-stream detection, or vote
- [ ] Soundboard — integrates with user storage, custom pop-up UI for direct audio playback into calls
