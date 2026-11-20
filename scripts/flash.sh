#!/usr/bin/env bash
# Запись образа на диск ноутбука. Стирает всё.
#   sudo bash scripts/flash.sh /dev/nvme0n1 arch-83hl.img.zst
set -euo pipefail

DEV=${1:-}
IMG=${2:-}

if [ -z "$DEV" ] || [ -z "$IMG" ]; then
  echo "usage: sudo $0 /dev/nvme0n1 arch-83hl.img.zst|.img" >&2
  exit 1
fi
[ -b "$DEV" ] || { echo "не блочное устройство: $DEV" >&2; exit 1; }
[ -f "$IMG" ] || { echo "нет файла: $IMG" >&2; exit 1; }

lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$DEV" || true
echo
echo "ВСЁ НА $DEV БУДЕТ СТЁРТО (включая Windows)."
read -r -p "Напишите YES для продолжения: " ans
[ "$ans" = "YES" ] || { echo "отмена"; exit 1; }

case "$IMG" in
  *.zst) zstd -dc "$IMG" | dd of="$DEV" bs=16M status=progress conv=fsync ;;
  *.xz)  xz -dc  "$IMG" | dd of="$DEV" bs=16M status=progress conv=fsync ;;
  *)     dd if="$IMG" of="$DEV" bs=16M status=progress conv=fsync ;;
esac

sync
echo "готово. Выключите ноут, зайдите в BIOS, выключите Secure Boot, загружайтесь."
