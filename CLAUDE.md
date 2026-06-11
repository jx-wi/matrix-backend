# CLAUDE.md

Working notes for this repo — the detail that doesn't belong in the polished [`README.md`](README.md). Audience: Claude (or any maintainer) making changes here. Read this before editing.

## What this repo is

A single NixOS flake that fully defines one host, `matrix-backend`: a private Matrix homeserver (Tuwunel) with a LiveKit SFU for calls, fronted by Caddy, with sops-nix secrets and a Lanzaboote-verified boot chain. There is no application code — everything is declarative Nix. The interesting files:

| File | Role |
| --- | --- |
| `flake.nix` | Inputs (nixpkgs 25.11, lanzaboote, sops-nix, disko) + the one `nixosConfigurations.matrix-backend`. |
| `configuration.nix` | **The whole system.** Services, secrets wiring, firewall, users, hardening. Start here. |
| `disko.nix` | Disk layout: GPT, 4G `ESP` (vfat) + `root` (ext4, 100%). Plain ext4 on purpose (see FDE below). |
| `hardware-configuration.nix` | Generated. QEMU-guest profile, `kvm-intel`, virtio modules. |
| `.sops.yaml` | Two age recipients (`&admin`, `&matrix-backend`) and per-file creation rules. |
| `secrets/` | sops-encrypted YAML. Ciphertext is safe to commit; the repo is public. |
| `ssh_host_ed25519_key.pub` | The guest's **public** host key. `ssh-to-age` of this == the `&matrix-backend` recipient. |
| `.github/workflows/` | `flake-check` (PR gate) and `flake-update` (weekly auto-update + auto-merge). |

## Deployment environment (ground truth)

- Runs as a **Proxmox (KVM/QEMU) guest**, not on bare metal. `services.qemuGuest.enable`, `kvm-intel`, and the `qemu-guest.nix` profile all assume this.
- **Full-disk encryption is provided by the Proxmox host's encrypted ZFS pool**, beneath the guest's virtual disk. That's why `disko.nix` is plain ext4 and there's no in-guest LUKS. If you ever move off encrypted-ZFS hosting, data-at-rest encryption disappears — add LUKS to `disko.nix` in that case.
  - The host delegates a **separate encrypted pool per service** (per-service key isolation). Pools are `aes-256-gcm`, `keyformat=passphrase` + `keylocation=prompt` (key entered at import, never on disk), `compression=zstd`, `atime=off`, `xattr=sa`, `dnodesize=auto`, `recordsize=16K` (small-random-I/O tuning, RocksDB-friendly). The zpool sits on an LVM LV in the `pve` VG — ZFS-on-LVM — so encrypted pools can be carved from the existing volume group without dedicating physical disks. The LV shows up under device-mapper as `pve-<lvname>` (e.g. `pve-zfsdata` → `/dev/pve/zfsdata`, type `lvm` in `lsblk`); the zpool is created on that node. Full recipe in the README.
  - **Consequence of `keylocation=prompt`:** a Proxmox host reboot does not auto-start this guest — someone must unlock the pool (passphrase) first. No unattended recovery; factor it into "is it down?" triage and maintenance windows.
- Hosted on **consumer hardware over a residential ISP (Spectrum, dynamic IP)**, and **the host operator is not the maintainer**. Implications: no SLA, public reachability depends on the host router forwarding `443/tcp+udp`, `7881/tcp`, `50000-60000/udp` to `192.168.0.101`, and the public DNS A record must track a dynamic WAN IP (there is **no in-guest dynamic-DNS updater** — it's handled upstream).
- The admin plane is a **Tailscale tailnet with strict zero-trust ACLs** defined in the Tailscale admin console (external to this repo). `trustedInterfaces = [ "tailscale0" ]` trusts the tailnet at the host firewall; the ACLs are what actually constrain who can reach the node. Treat the ACL policy as an unversioned dependency — if you change the access model, it lives there, not here.
- Intel host → `kvm-intel`. On AMD, switch to `kvm-amd` in `hardware-configuration.nix`.

## Source-of-truth model (important)

There are effectively two places config can live, and only one wins:

1. **This GitHub repo `main`** — the real source of truth.
2. **`/etc/nixos` on the guest** — a working copy. Edits here are transient.

`systemd.timers.nh-os-switch` fires **Monday 09:00 server-local** and runs `nh os switch github:jx-wi/matrix-backend` as root, converging the box on repo `main`. So any change made only on the box is reverted at the next tick. The Initialization registration-toggle in the README exploits this deliberately (open registration, create admin, it auto-closes). For anything durable: change it here, push, let it deploy.

CI auto-update chain: `flake-update.yml` runs **Monday 06:00 UTC**, does `nix flake update`, opens a PR, and `gh pr merge --auto --squash` with `secrets.PAT`. `flake-check.yml` evaluates + dry-run builds. ~3h later the guest pulls and switches. Net effect: **upstream input bumps reach production with CI gating, not per-change human review.** See [Threat model](#threat-model--deferred-hardening).

## Architecture internals

Request paths (all TLS terminates at Caddy on `:443`):

- `/.well-known/matrix/server` → static `{"m.server":"<domain>:443"}` (advertised even though federation is off — harmless).
- `/.well-known/matrix/client` → homeserver base URL + `org.matrix.msc4143.rtc_foci` pointing at the LiveKit JWT endpoint. This is what makes Element Call autodiscover.
- `/livekit/jwt/*` → `lk-jwt-service` on `127.0.0.1:8080` (mints LiveKit JWTs for Matrix users).
- `/livekit/sfu/*` → LiveKit HTTP/WS on `127.0.0.1:7880`.
- everything else → Tuwunel on `127.0.0.1:6167` (`encode zstd gzip`).

Media is **not** proxied: LiveKit takes WebRTC directly on `7881/tcp` and `50000-60000/udp`, with `use_external_ip = true` so ICE candidates carry the STUN-discovered WAN IP (this is the fragile bit behind NAT — calls fail if the UDP range isn't forwarded 1:1).

Port exposure reality:
- Public (must be forwarded): `80`, `443` (tcp+udp), `7881/tcp`, `50000-60000/udp`.
- Loopback only: Tuwunel `6167` (`address = ["127.0.0.1"]`), node_exporter `9100`.
- Bound `0.0.0.0` but **firewall-dropped** from outside: LiveKit `7880`, lk-jwt `8080`. Only Caddy (localhost) reaches them. Defense-in-depth would bind these to loopback too, but the firewall is the backstop.
- `tailscale0` is a trusted interface — anything the host listens on is reachable from the tailnet (subject to ACLs).

`lk-jwt-service` and LiveKit share one secret: `sops.templates."livekit.key"` renders `lk-jwt-service: <secret>` and both services read it. The homeserver name is passed to lk-jwt via `LIVEKIT_FULL_ACCESS_HOMESERVERS`.

## Secrets model

sops-nix decrypts at activation using an age key **derived from the guest's SSH host key** (`age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]`). Verified: `ssh-to-age -i ssh_host_ed25519_key.pub` == `age1qe93cz32rplg562cu33ajftnc05mh9fmeduz9qcvsu2jy3denuqqhmt39p` == `&matrix-backend` in `.sops.yaml`.

The chicken-and-egg: sops can't decrypt `ssh.yaml` (which contains the host private key) using a key it doesn't have yet. So the host key is **injected manually** during install (README → Installation). On a fresh machine you bootstrap with the **admin** age key, which is therefore the true recovery root — if it's lost you can't extract the host key from sops to stand up a replacement. Keep the admin private key offline and backed up.

`neededForUsers = true` on the two password secrets makes sops decrypt them early enough to create users. Owners/modes are set per-secret (e.g. `dns_token` is `acme:0400`, `livekit_secret` is `livekit:livekit:0400`). When adding a secret: add the file + a `.sops.yaml` rule, add the `sops.secrets.<name>` block with the right `owner`/`group`/`mode`, and reference `config.sops.secrets.<name>.path`.

Because the repo is public, every historical ciphertext is downloadable. Compromise of **either** the admin key or the host key retroactively decrypts all past secret versions — rotation after a suspected leak must assume everything is burned.

## Making changes safely

The maintainer has **limited access to the production network** (no-access router at their location) and does not run the host. So the loop is: change here → validate locally/CI → push → it deploys. Verification is remote (Tailscale SSH + `journalctl`).

Local checks that work **without any production/router access**:

```
nix flake check --show-trace                       # evaluates the config (what CI runs)
nix build .#nixosConfigurations.matrix-backend.config.system.build.toplevel --dry-run
nixos-rebuild build-vm --flake .#matrix-backend     # boots a throwaway local QEMU VM
```

`build-vm` is the closest thing to a test rig and needs no inbound networking — it runs entirely on the dev machine. Caveat: sops secrets won't decrypt inside it (no host age key), so secret-dependent services will fail to start there; it still validates evaluation, boot, the boot loader, and anything not gated on a secret. There is no NixOS VM integration test in `flake.nix` yet — adding one (`checks.<system>`) would be the highest-value testing improvement given the access constraints.

After merging, confirm on the box over Tailscale: `systemctl --failed`, `journalctl -u <svc> -b`, `tailscale status`, `nh os switch github:jx-wi/matrix-backend` if you don't want to wait for the timer.

## Non-obvious choices (don't "fix" these without reading)

- **4G ESP** — Lanzaboote stores signed kernel+initrd per generation; with `configurationLimit = 16` the default 512M–1G ESP overflows. Keep it roomy.
- **`environment.binsh = dash`** — smaller/faster `/bin/sh`, reduced surface. Scripts assuming bashisms in `/bin/sh` will break.
- **`zramSwap.memoryPercent = 75`** — aggressive; sized for a small-RAM guest. Tune to the actual VM allocation. Disk swap is an 8G `randomEncryption` swapfile (new key per boot → no hibernation, fine for a server).
- **`lockKernelModules = true`** — modules not loaded by boot can't load later. `wireguard` is force-loaded for this reason. If you add a service needing a module (e.g. something pulling a new netfilter module at runtime), add it to `boot.kernelModules` or it'll fail post-boot.
- **node_exporter on `127.0.0.1:9100`** — exporter is enabled but nothing scrapes it, and loopback-binding means it isn't reachable over Tailscale without a tunnel. It's a stub; wiring Prometheus/Grafana/alerting is deferred work, not a finished feature.
- **Port 80 open but ACME uses DNS-01** — `:80` exists only for the human-friendly HTTP→HTTPS redirect; cert issuance never needs inbound 80.
- **`fail2ban` only has the sshd jail** — and SSH is key-only, so that jail rarely does anything. The password-authenticated surface that actually matters is Matrix `/login` on `:443`, which has no jail.
- **Two SSH paths** — Tailscale SSH (`--ssh`) for the tailnet, plus the normal `sshd` on `:22`. `services.openssh.openFirewall` defaults true, so `:22` is also open on the LAN. It's a real break-glass path; tighten with `openFirewall = false` if you want Tailscale-only, but then a tailnet/tailscaled outage locks you out.

## Threat model & deferred hardening

What this design protects against: remote compromise of the public listener (small surface, hardened services, loopback binding), boot-chain tampering (Lanzaboote), secret theft from the repo (sops), credential brute-force over SSH (key-only), and disk theft (encrypted ZFS pool). What it does **not** currently cover, roughly by impact:

- **No in-guest backups.** Repo reproduces config, not data. Mitigation lives at the ZFS layer (snapshots + off-box `zfs send`) and is the host operator's responsibility — confirm it actually happens.
- **Auto-merge + auto-deploy** means a malicious/compromised upstream that passes `nix flake check` can reach root on the box with no human reviewing the diff. `flake check` validates buildability, not intent. The `secrets.PAT` is a high-value credential (repo write → root). De-risking options: drop auto-merge (manual review), pin nixpkgs to an explicit rev and bump deliberately, or add a soak delay before the guest pulls. Confirm branch protection actually requires the `flake check` status, or the merge isn't gated.
- **App-layer abuse controls are thin** — no rate limiting on Matrix login beyond whatever Tuwunel does by default; no media retention/upload caps, so the single ext4 root can fill from uploads.
- **No alerting** — failures (rebuild, cert, service crash, disk full) are silent until someone notices. node_exporter is present but unscraped.
- **Partial kernel hardening** relative to the "hardened" label — `linuxPackages_latest` (not the hardened kernel/profile), no AppArmor/lockdown LSM, sysctl omits `kptr_restrict`, `yama.ptrace_scope`, `rp_filter`, BPF hardening. Deliberate tradeoffs, but worth knowing.
- **DuckDNS is the DNS root of trust** — no DNSSEC; account/token compromise → ACME DNS-01 → valid cert → MITM.

None of these are bugs to fix blindly; they're the known edges of the current tradeoffs. Touch them intentionally.

## Conventions

- **Commits:** `type: imperative subject`, lowercase. Types in use: `feat:`, `security:`, `flake:`, `nixos:`, `docs:`. One logical change per commit.
- **Changes flow through PRs to `main`** (CI runs `flake check` + dry-run build). The repo auto-merges only the bot's flake-update PRs.
- **Never commit plaintext secrets.** Edit with `sops <file>`; `.gitignore` covers `*.yaml.dec` but don't rely on it. Adding/removing a recipient → `sops updatekeys` the affected files.
- **Formatting:** no enforced formatter yet; match the existing 2-space Nix style in `configuration.nix`.
- **Don't add inbound ports** without also documenting the router forward they require — an open firewall port does nothing if the host router doesn't forward it, and vice versa.
