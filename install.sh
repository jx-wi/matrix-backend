#!/usr/bin/env bash
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
exit 0
