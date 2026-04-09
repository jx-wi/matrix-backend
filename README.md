# matrix backend server configuration

### rebuild command:
From a host with nix sandbox:
```
nixos-rebuild switch --flake .#matrix-backend --target-host root@matrix-backend --build-host localhost
```

### initial installation commands:

```
sudo -i
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
```

```
nixos-install --flake path:matrix-backend#matrix-backend
```
NOTE: `nixos-install` WILL FAIL TO INSTALL THE BOOTLOADER THE FIRST TIME - THIS IS INTENDED

```
nixos-enter --command "sbctl create-keys"
nixos-install --flake path:matrix-backend#matrix-backend
```
NOTE: `nixos-install` SHOULD WORK THIS TIME SINCE SECURE BOOT KEYS WERE CREATED

