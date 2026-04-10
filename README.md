# matrix backend server configuration

## initial installation commands:

These instructions have `/dev/vda` as the drive to partition and format. Make sure you know what drive you actually want to use and adjust the `sfdisk`, `mount`, and `mkfs` commands accordingly.

In the bootable installer:

```
sudo passwd root  # use a 7+ word passphrase
```

From a dev machine:

```
# replace TARGET_HOST_IP:

ssh root@TARGET_HOST_IP
```

While ssh'ed into the installer:

```
git clone https://github.com/jx-wi/matrix-backend.git
sfdisk /dev/vda << 'EOF'
label: gpt
, 4G, U
, ,
EOF
mkfs.ext4 /dev/vda2
mkfs.vfat /dev/vda1
mount /dev/vda2 /mnt
mount /dev/vda1 -m /mnt/boot
nixos-generate-config --root /mnt --dir matrix-backend
nixos-install --flake path:matrix-backend#matrix-backend
nixos-enter --command "sbctl create-keys"
nixos-install --flake path:matrix-backend#matrix-backend
exit
```

After `exit`, run this from a dev machine with the age admin key:

```
# replace REPO_DIR and TARGET_HOST_IP

cd REPO_DIR

sops --extract '["ssh_host_ed25519_key"]' -d secrets/matrix-backend/ssh.yaml \
  | ssh root@TARGET_HOST_IP "cat > /mnt/etc/ssh/ssh_host_ed25519_key && chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key"
```

If all seems well, reboot the matrix machine.

## rebuild command:

From a host with nix sandbox:

```
nixos-rebuild switch --flake .#matrix-backend --target-host root@matrix-backend --build-host localhost
```

