# matrix-backend

**Hardened NixOS infrastructure for a self-hosted, private Matrix homeserver — privacy-respecting messaging with voice and video.**

*Secrets encrypted at rest with sops-nix.  Cryptographically verified boot chain with Lanzaboote.  Flake-based CI.*

*Runs as a Proxmox VM on an encrypted ZFS pool.  Admin access restricted to a zero-trust Tailscale mesh.  Matrix client traffic on 443.*

***The system is 100% reproducible from this repository.***

[![flake check](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml/badge.svg)](https://github.com/jx-wi/matrix-backend/actions/workflows/flake-check.yml) [![NixOS](https://img.shields.io/badge/NixOS-25.11-5277C3?logo=nixos&logoColor=white)](https://nixos.org) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

**[Architecture](#architecture) · [Installation](#installation) · [Initialization](#initialization) · [Rebuilding](#rebuilding) · [Operations](#operations) · [Security](#security) · [Roadmap](#roadmap)**

## Architecture

A single NixOS guest runs the whole stack. [Caddy](https://caddyserver.com) terminates TLS on 443 and reverse-proxies three local services: [Tuwunel](https://github.com/matrix-construct/tuwunel) (the Matrix homeserver), [LiveKit](https://livekit.io) (the SFU for voice/video/screenshare), and `lk-jwt-service` (mints LiveKit access tokens for Matrix clients). WebRTC media flows directly to LiveKit on its own ports. The admin plane — SSH, rebuilds, metrics — lives entirely on a [Tailscale](https://tailscale.com) mesh and never touches the public listener.

```
                 Internet  (residential ISP, dynamic IP)
                                    │
               :443 tcp/udp · :7881 tcp · :50000-60000 udp
                                    ▼
                     ┌──────────────────────────────┐
                     │  Router (NAT, port-forward)  │ ──► 192.168.0.101
                     └──────────────────────────────┘
                                    │ LAN
                                    ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  Proxmox host  ·  encrypted ZFS pool  (full-disk encryption)     │
   │  ┌────────────────────────────────────────────────────────────┐  │
   │  │  matrix-backend  (NixOS guest — this repo)                 │  │
   │  │                                                            │  │
   │  │   Caddy :443 ──┬─ /              ──► Tuwunel       :6167   │  │
   │  │   (TLS, HSTS)  ├─ /livekit/sfu/* ──► LiveKit       :7880   │  │
   │  │                └─ /livekit/jwt/* ──► lk-jwt-service:8080   │  │
   │  │                                                            │  │
   │  │   LiveKit media (direct):  :7881 tcp · :50000-60000 udp    │  │
   │  │                                                            │  │
   │  │   Admin plane:  Tailscale (zero-trust ACLs) ──► SSH        │  │
   │  │   Secrets:      sops-nix  ◄── host SSH key derives age key │  │
   │  │   Certs:        ACME DNS-01  (no inbound :80 needed)       │  │
   │  └────────────────────────────────────────────────────────────┘  │
   └──────────────────────────────────────────────────────────────────┘
```

**Why a VM, not a dedicated host.** A private Matrix server doesn't justify a whole physical machine. Running it as a Proxmox guest gives near-bare-metal performance, lets the host carry other workloads, and — because the guest's virtual disk lives on an **encrypted ZFS pool** — provides full-disk encryption and cheap snapshots without any in-guest LUKS or changes to this repo. `disko.nix` therefore formats plain `ext4`; data-at-rest encryption is a property of the pool beneath it.

## Installation

> [!IMPORTANT]
> **Prerequisites**
> - A **Proxmox** (KVM/QEMU) host with an **encrypted ZFS pool** for the guest disk — this is what provides full-disk encryption.
> - The guest is configured for an **Intel** host (`kvm-intel` in `hardware-configuration.nix`); on AMD switch this to `kvm-amd`.
> - **Router access on the host's network** to forward the public ports to the guest: `443/tcp`, `443/udp`, `7881/tcp`, and `50000-60000/udp`.
> - A **Tailscale** account (with ACLs — see [Security](#security)) and a **DNS provider** supported by [lego](https://go-acme.github.io/lego/dns/) for ACME DNS-01.

### On the Proxmox host: encrypted ZFS pool

The guest's virtual disk lives on a dedicated, encrypted ZFS pool — this is where full-disk encryption comes from. Each service gets its **own** pool, so keys and blast radius stay isolated. Create one for matrix-backend:

```
# replace {POOL_SIZE} {POOL_NAME} {POOL_SERVICE}
#   {POOL_NAME}    LVM volume in the `pve` VG; the zpool sits on /dev/pve/{POOL_NAME}
#   {POOL_SERVICE} zpool name (per service)
#   e.g. -n zfsdata  →  /dev/pve/zfsdata  →  `lsblk` shows `pve-zfsdata ... lvm`

sudo /sbin/lvcreate -L {POOL_SIZE}G -n {POOL_NAME} pve
sudo zpool create \
  -O encryption=aes-256-gcm \
  -O keylocation=prompt \
  -O keyformat=passphrase \
  -O compression=zstd \
  -O atime=off \
  -O xattr=sa \
  -O dnodesize=auto \
  -O recordsize=16K \
  {POOL_SERVICE} /dev/pve/{POOL_NAME}
```

Then register it as Proxmox storage — **Datacenter → Storage → Add → ZFS**, select the pool, fill out — and create the guest with its disk on that storage.

> [!IMPORTANT]
> `keylocation=prompt` means the pool unlocks with a passphrase **typed at import**. After any Proxmox host reboot the pool must be unlocked manually before this guest can start — there is no unattended boot. That is the deliberate trade for a key that never sits on disk.

### In the guest

> [!NOTE]
> `disko.nix` formats `/dev/sda`. Confirm the guest's disk and adjust if needed.
>
> `systemd.network` in `configuration.nix` uses `192.168.0.1` as the gateway and `192.168.0.101/24` as the guest address. Adjust to your LAN.

> [!NOTE]
> Before deploying, set the following at the top of `configuration.nix`:
> - `homeserver` — your domain
> - `dnsProvider` — your ACME DNS challenge provider ([supported providers](https://go-acme.github.io/lego/dns/))
> - `dnsTokenEnvVar` — the env var your provider's lego driver expects for its API token

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

If all seems well, reboot the guest.

After rebooting, login / ssh in and run:

```
sudo sbctl enroll-keys --microsoft
```

## Initialization

Registration is disabled by default. To create the initial admin account:

1. SSH into matrix-backend.
2. Edit `/etc/nixos/configuration.nix`, set `allow_registration = true` inside `services.matrix-tuwunel.settings.global`.
3. Rebuild: `nh os switch /etc/nixos`.
4. In your Matrix client, connect to your homeserver URL and register using the registration token. **The first account registered is automatically an admin.**
5. Set `allow_registration = false` and rebuild again.

> [!WARNING]
> While `allow_registration = true`, anyone who reaches `:443` **and** holds the registration token can register — and whoever registers first becomes the admin. Keep the window short, and rebuild back to `false` immediately.

> [!NOTE]
> `/etc/nixos` is a working copy. Durable changes belong in this repo (see [Rebuilding](#rebuilding)) — the weekly auto-rebuild pulls from GitHub and will revert anything that only lives on the box. The registration toggle above is intentionally transient.

## Rebuilding

While ssh'ed into matrix-backend:

```
nh os switch github:jx-wi/matrix-backend
```

> [!NOTE]
> This also runs automatically. A systemd timer fires every Monday at 9am (server local time) and runs the same command against the live repo. To disable automatic updates, remove `systemd.timers.nh-os-switch` and `systemd.services.nh-os-switch` from `configuration.nix`.

The source of truth is **this GitHub repo**, not the box. Make changes here, let CI validate them ([`flake check`](.github/workflows/flake-check.yml) evaluates the config and dry-run builds the system), then merge — the guest converges on the next rebuild.

## Operations

> [!TIP]
> This section is the "how do I…" reference. For the internals behind these steps, see [`CLAUDE.md`](CLAUDE.md).

### Onboarding secrets (fresh deployment)

Secrets are encrypted to two age recipients: your **admin** key (your recovery root — generate and back it up offline) and the **host** key (derived from the guest's SSH host key). Both are listed in [`.sops.yaml`](.sops.yaml).

```
# 1. generate your admin age key (keep the private key OFFLINE and backed up)
age-keygen -o ~/.config/sops/age/keys.txt   # public key goes in .sops.yaml as &admin

# 2. derive the host recipient from the guest's SSH host public key
ssh-to-age -i ssh_host_ed25519_key.pub       # goes in .sops.yaml as &matrix-backend

# 3. create / edit each secret
sops secrets/matrix-backend/tailscale.yaml          # auth_key  (Tailscale admin console)
sops secrets/matrix-backend/dns.yaml                # token     (DNS provider API token)
sops secrets/matrix-backend/livekit.yaml            # secret    (random, e.g. `openssl rand -hex 32`)
sops secrets/matrix-backend/registration-token.yaml # token     (random)
sops secrets/matrix-backend/ssh.yaml                # ssh_host_ed25519_key (the guest's private host key)
sops secrets/matrix-backend/jaxxen/password.yaml    # hashed_password (`mkpasswd -m yescrypt`)
sops secrets/matrix-backend/garth/password.yaml     # hashed_password
```

| Secret | Consumed by | Notes |
| --- | --- | --- |
| `tailscale.yaml → auth_key` | `services.tailscale` | Reusable/ephemeral key from the Tailscale console |
| `dns.yaml → token` | ACME (DNS-01) | Your DNS provider's API token |
| `livekit.yaml → secret` | LiveKit + lk-jwt | Shared HMAC secret; both services read the same value |
| `registration-token.yaml → token` | Tuwunel | Gates registration during [Initialization](#initialization) |
| `ssh.yaml → ssh_host_ed25519_key` | bootstrap | The host private key; injected manually at install |
| `*/password.yaml → hashed_password` | login users | `mkpasswd -m yescrypt`; never store plaintext |

### Rotating keys & secrets

```
# rotate a secret value (token, password, livekit secret, …)
sops secrets/matrix-backend/<file>.yaml   # change the value, save
nh os switch github:jx-wi/matrix-backend  # or let the weekly timer apply it

# rotate a login user's SSH key
#   edit users.users.<name>.openssh.authorizedKeys.keys in configuration.nix, commit, rebuild
```

> [!CAUTION]
> **Rotating the host SSH key rotates the guest's age identity.** Every secret must be re-encrypted to the new recipient and the new private key re-injected. Update `&matrix-backend` in `.sops.yaml`, then `sops updatekeys secrets/matrix-backend/**/*.yaml`, commit, and repeat the host-key injection from [Installation](#installation). Because the repo is public, treat any past key compromise as exposing **all** historical secret versions — rotate everything.

### Backups

This repository reproduces the **system**, not its **data**. Matrix messages, accounts, media, and end-to-end device keys live in the guest's filesystem on the encrypted ZFS pool. Back them up at the pool level — ZFS snapshots plus an off-box `zfs send` are the simplest path. Without that, a lost guest is lost history.

### Troubleshooting

| Symptom | Look at | Likely fix |
| --- | --- | --- |
| Services fail after boot; secrets missing | `systemctl status sops-nix`, `journalctl -u sops-nix` | Host SSH key wrong/missing → re-inject (see Installation) |
| TLS cert won't issue/renew | `systemctl status acme-<domain>`, its journal | Bad/expired DNS token; provider/lego env var mismatch |
| Can't reach the box over Tailscale | `tailscale status`, `systemctl status tailscaled` | Expired/used auth key, or ACLs — check the Tailscale console |
| Calls connect but no audio/video | LiveKit journal, router | UDP `50000-60000` + `7881/tcp` not forwarded; NAT/`use_external_ip` |
| Rebuild failed | `systemctl status nh-os-switch`, `journalctl -u nh-os-switch` | Atomic — the box stays on the previous generation; fix and re-run |
| Need to roll back | boot menu (previous generation) or `nixos-rebuild switch --rollback` | Lanzaboote keeps the last 16 signed generations |
| Disk filling up | `journalctl --disk-usage`, Matrix media dir, `nh clean` | Prune generations; consider media retention limits |

## Security

- **Full-disk encryption** at the Proxmox/ZFS layer — each service gets its own `aes-256-gcm` pool with a passphrase-prompted key that never touches disk, unlocked manually at host boot. Data at rest is encrypted beneath the guest, with per-service key isolation.
- **Tailscale mesh with zero-trust ACLs** — the only admin/SSH plane; Matrix client traffic stays on `:443`. SSH is also reachable on the LAN as a documented break-glass path.
- **Firewall** — ingress limited to TCP 80 (HTTP→HTTPS redirect), 443 (Matrix/LiveKit), 7881 (LiveKit RTC), UDP 443 (HTTP/3), 50000–60000 (LiveKit WebRTC), and the Tailscale port; everything else dropped. Internal service ports are bound to loopback or backstopped by the firewall.
- **sops-nix / age** — secrets never stored in plaintext; multi-recipient (admin + host keys). The admin key is the offline recovery root.
- **Lanzaboote** — cryptographically verified boot chain (replaces standard systemd-boot).
- **sudo-rs** — memory-safe Rust reimplementation of sudo; `execWheelOnly`, password required.
- **Key-only SSH**, root login disabled, `su root` locked, `MaxAuthTries 3`.
- **Immutable declarative users** (`mutableUsers = false`) — no out-of-band state.
- **Kernel hardening** — `protectKernelImage`, `lockKernelModules`, and a tightened sysctl set (redirects off, syncookies, `dmesg_restrict`, martian logging).
- **Encrypted swap** with a random key per boot; zram swap (zstd) on top.
- **fail2ban** on SSH; **Caddy** sets HSTS, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, and suppresses the `Server` header.
- **CI tool versions pinned by commit hash**; inputs locked in `flake.lock`.

> [!NOTE]
> **Assumes / non-goals.** A single guest — no HA. Federation is currently **off** (closed server). Application-layer abuse controls beyond closed registration are minimal. Data-at-rest protection depends on the ZFS pool being encrypted; in-guest backups are **not** configured (see [Backups](#backups)). Flake inputs auto-update and deploy weekly — convenient, but it means upstream lands with CI gating rather than per-change human review. See [`CLAUDE.md`](CLAUDE.md) for the full threat model and deferred hardening.

## Roadmap

#### Infrastructure
- [X] Hardened NixOS server baseline
- [X] Matrix homeserver (Tuwunel)
- [X] LiveKit SFU — voice, video, and screensharing (MatrixRTC / Element Call)
- [ ] Federation — domain, DNS SRV records, enable server-to-server traffic

#### Custom features
> Aspirational — these need client-side or appservice work, not just server config.
- [ ] Tiered storage — 1G default, 16G core member, 128G admin; uploads routed to personal cloud storage, attachments render as linked previews in chat
- [ ] Cinematic mode screensharing — single priority stream upgrades to 2K@60fps via admin grant, sole-stream detection, or vote
- [ ] Soundboard — integrates with user storage, custom pop-up UI for direct audio playback into calls
