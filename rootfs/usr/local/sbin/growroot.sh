#!/bin/bash
# Первый буст: растянуть последний раздел (root) на весь диск и resize2fs.
set -euo pipefail
[ -e /var/lib/growroot.done ] && exit 0

root_src=$(findmnt -n -o SOURCE /)
[ -b "$root_src" ] || { echo "root не блочное устройство: $root_src"; exit 0; }

part=$(basename "$root_src")
parent=$(lsblk -no PKNAME "$root_src" | head -1)
[ -n "$parent" ] || { echo "не нашёл родительский диск"; exit 0; }
num=$(cat "/sys/class/block/$part/partition")

echo "growroot: /dev/$parent partition $num"
echo ", +" | sfdisk --no-reread --force -N "$num" "/dev/$parent" || true
partx -u "/dev/$parent" || true
udevadm settle || true
resize2fs "$root_src"
touch /var/lib/growroot.done
echo "growroot: готово"
