#!/usr/bin/env bash
# Собирает готовый к записи образ: GPT (ESP + ext4 root), без установщика.
# Root не нужен: файловые системы создаются в файлах и вклеиваются dd.
#
# Переменные:
#   ROOTFS_DIR   готовый rootfs (out/rootfs)
#   IMAGE_SIZE   размер образа, напр. 8G (по умолчанию 8G)
#   IMG          путь к .img (out/arch-83hl.img)
#   ZSTD_LEVEL   уровень сжатия (по умолчанию 12)
#   NO_COMPRESS=1 не сжимать
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

ROOTFS_DIR=${ROOTFS_DIR:-$OUT/rootfs}
IMAGE_SIZE=${IMAGE_SIZE:-8G}
IMG=${IMG:-$OUT/arch-83hl.img}
ZSTD_LEVEL=${ZSTD_LEVEL:-12}
NO_COMPRESS=${NO_COMPRESS:-0}
ESP_SIZE=${ESP_SIZE:-512M}

need_cmd sgdisk mkfs.vfat mcopy mdir mkfs.ext4 e2fsck dd truncate zstd stat

[ -d "$ROOTFS_DIR" ] || die "нет rootfs: $ROOTFS_DIR"
[ -d "$ROOTFS_DIR/efi/EFI/BOOT" ] || die "нет $ROOTFS_DIR/efi/EFI/BOOT (сначала make-rootfs.sh)"
[ -f "$ROOTFS_DIR/efi/EFI/BOOT/BOOTAA64.EFI" ] || die "нет UKI BOOTAA64.EFI"

size_bytes=$(numfmt --from=iec "$IMAGE_SIZE")
esp_mib=$(( $(numfmt --from=iec "$ESP_SIZE") / 1024 / 1024 ))
[ "$esp_mib" -ge 64 ] || die "ESP слишком мал"

WORK="$OUT/image-work"
rm -rf "$WORK"; mkdir -p "$WORK"

log "образ: $IMG ($IMAGE_SIZE, ESP ${esp_mib}M)"
rm -f "$IMG"
truncate -s "$size_bytes" "$IMG"

log "GPT"
sgdisk --clear --set-alignment=2048 \
  --new=1:0:+"${esp_mib}M" --typecode=1:ef00 --change-name=1:"$ESP_LABEL" \
  --new=2:0:0             --typecode=2:8300 --change-name=2:"$IMAGE_LABEL" \
  "$IMG" >/dev/null

read -r s1 z1 <<<"$(part_geom 1 "$IMG")"
read -r s2 z2 <<<"$(part_geom 2 "$IMG")"
log "p1: сектор $s1, $((z1*512/1024/1024)) MiB; p2: сектор $s2, $((z2*512/1024/1024)) MiB"
[ $(( (s1 + z1) * 512 )) -le "$size_bytes" ] || die "p1 вне образа"
[ $(( (s2 + z2) * 512 )) -le "$size_bytes" ] || die "p2 вне образа"
[ "$z2" -gt 0 ] || die "пустой root-раздел"

# --- ESP -----------------------------------------------------------------
log "FAT32 + копирование EFI"
esp_img="$WORK/esp.img"
mkfs.vfat -F 32 -n "$ESP_LABEL" -C "$esp_img" $(( z1 / 2 )) >/dev/null
( cd "$ROOTFS_DIR/efi" && mcopy -i "$esp_img" -s ./* ::/ )
mdir -i "$esp_img" ::/EFI/BOOT >/dev/null || die "UKI не попал в ESP"

dd if="$esp_img" of="$IMG" bs=512 seek="$s1" conv=notrunc,sparse status=none

# --- root ----------------------------------------------------------------
log "ext4 + копирование rootfs"
root_img="$WORK/root.img"
# /efi — точка монтирования ESP; содержимое уже в FAT32-разделе, в ext4 его не дублируем
mkdir -p "$ROOTFS_DIR/efi"
mv "$ROOTFS_DIR/efi" "$WORK/efi-saved"
mkdir -p "$ROOTFS_DIR/efi"
restore_efi() {
  rm -rf "$ROOTFS_DIR/efi"
  mv "$WORK/efi-saved" "$ROOTFS_DIR/efi"
}
trap restore_efi EXIT
mkfs.ext4 -q -F -L "$IMAGE_LABEL" -b 4096 -d "$ROOTFS_DIR" "$root_img" $(( z2 / 8 ))
e2fsck -fn "$root_img" >/dev/null || warn "e2fsck сообщил о замечаниях (для свежей ФС это норм)"
restore_efi
trap - EXIT

dd if="$root_img" of="$IMG" bs=512 seek="$s2" conv=notrunc,sparse status=none
sync

log "проверка GPT"
sgdisk -v "$IMG" | tail -2

# --- метаданные ----------------------------------------------------------
krel=$(basename "$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)" 2>/dev/null || true)
{
  echo "image: $(basename "$IMG")"
  echo "size: $IMAGE_SIZE"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root label: $IMAGE_LABEL"
  echo "esp label: $ESP_LABEL"
  echo "kernel: ${krel:-unknown}"
  echo "partitions:"
  LC_ALL=C sgdisk -p "$IMG" | sed -n '/Number/,$p'
} >"$OUT/IMAGE_INFO.txt"

rm -rf "$WORK"

if [ "$NO_COMPRESS" != "1" ]; then
  log "сжатие zstd -$ZSTD_LEVEL"
  zstd -T0 -"$ZSTD_LEVEL" --long=27 -q -f "$IMG" -o "$IMG.zst"
  sz=$(stat -c %s "$IMG.zst")
  if [ "$sz" -gt $((1900*1024*1024)) ]; then
    log "файл > 1.9 ГиБ — режу на части для GitHub Releases"
    rm -f "$IMG.zst".part*
    split -b 1900M -d -a 2 "$IMG.zst" "$IMG.zst.part"
    rm -f "$IMG.zst"
    cat >"$IMG.zst.parts.txt" <<EOF
Образ порезан на части (лимит GitHub — 2 ГиБ на файл). Собрать обратно:

  cat $(basename "$IMG").zst.part* > $(basename "$IMG").zst
  zstd -dc $(basename "$IMG").zst | sudo dd of=/dev/nvme0n1 bs=16M status=progress conv=fsync
EOF
    ls -l "$IMG".zst.part* | awk '{print $5, $9}'
  else
    log "сжатый образ: $(human "$sz")"
  fi
fi

sha256sum "$IMG".zst* 2>/dev/null >"$OUT/SHA256SUMS.image" || true
if [ "${KEEP_IMG:-0}" != "1" ] && [ -f "$IMG.zst" ]; then
  rm -f "$IMG"   # сырой 8-гиговый файл в CI не нужен
fi
log "готово: $IMG"
