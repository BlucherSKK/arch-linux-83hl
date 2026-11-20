#!/usr/bin/env bash
# Сборка ядра linux-83hl (arm64) и упаковка в out/kernel-pkg + tar.zst.
#
# Переменные окружения:
#   KERNEL_DIR   каталог исходников ядра        (по умолчанию ./kernel)
#   BUILD_DIR    каталог O=                     (по умолчанию out/kbuild)
#   PKG_DIR      куда ставить модули/Image      (по умолчанию out/kernel-pkg)
#   JOBS         параллельность                 (по умолчанию nproc)
#   LLVM         1 = clang/lld, 0 = gcc         (по умолчанию 1)
#   KDEFCONFIG   defconfig | ubuntu_x1e_defconfig | путь к .config
#                (по умолчанию defconfig; в CI — ubuntu_x1e_defconfig)
#   DTB          ожидаемый dtb (qcom/x1p42100-lenovo-ideapad-slim5x-oled.dtb)
#   EXTRA_MAKE_ARGS  доп. аргументы make
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

KERNEL_DIR=${KERNEL_DIR:-$ROOT/kernel}
BUILD_DIR=${BUILD_DIR:-$OUT/kbuild}
PKG_DIR=${PKG_DIR:-$OUT/kernel-pkg}
JOBS=${JOBS:-$(nproc)}
LLVM=${LLVM:-1}
KDEFCONFIG=${KDEFCONFIG:-defconfig}
DTB=${DTB:-}
EXTRA_MAKE_ARGS=${EXTRA_MAKE_ARGS:-}

export ARCH=arm64
if [ "$LLVM" = "1" ]; then
  export LLVM=1
  need_cmd clang ld.lld llvm-ar llvm-objcopy llvm-nm llvm-strip
else
  export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
  need_cmd "${CROSS_COMPILE}gcc"
fi

need_cmd make bc flex bison cpio tar zstd
command -v depmod >/dev/null 2>&1 || warn "depmod не найден — модули будут без modules.dep (поставьте kmod)"

[ -f "$KERNEL_DIR/Makefile" ] || die "нет исходников ядра в $KERNEL_DIR (ожидается Makefile)"

log "ядро: $KERNEL_DIR"
log "сборка: $BUILD_DIR (jobs=$JOBS, LLVM=$LLVM)"

MAKE=(make -C "$KERNEL_DIR" O="$BUILD_DIR")
if [ "${CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR=${CCACHE_DIR:-$HOME/.ccache}
  log "ccache: $CCACHE_DIR"
  MAKE+=(CC="ccache clang")
fi

# --- патчи ---------------------------------------------------------------
if compgen -G "$ROOT/patches/*.patch" >/dev/null; then
  for p in "$ROOT"/patches/*.patch; do
    log "патч: $(basename "$p")"
    if git -C "$KERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$KERNEL_DIR" apply -p1 "$p" || die "не применился $p"
    else
      patch -d "$KERNEL_DIR" -p1 -N <"$p" || die "не применился $p"
    fi
  done
fi

# --- device tree из dts/ -------------------------------------------------
DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/qcom"
if compgen -G "$ROOT/dts/*.dts*" >/dev/null; then
  mkdir -p "$DTS_DIR"
  for f in "$ROOT"/dts/*.dts*; do
    base=$(basename "$f")
    log "dts: $base"
    cp -f "$f" "$DTS_DIR/$base"
    case "$base" in
      *.dts)
        stem=${base%.dts}
        line="dtb-\$(CONFIG_ARCH_QCOM) += ${stem}.dtb"
        grep -qxF "$line" "$DTS_DIR/Makefile" || echo "$line" >>"$DTS_DIR/Makefile"
        ;;
    esac
  done
fi

# --- конфиг --------------------------------------------------------------
mkdir -p "$BUILD_DIR"
if [ -f "$KDEFCONFIG" ]; then
  log "конфиг из файла: $KDEFCONFIG"
  cp -f "$KDEFCONFIG" "$BUILD_DIR/.config"
elif [ -f "$ROOT/config/$KDEFCONFIG" ]; then
  log "конфиг из файла: config/$KDEFCONFIG"
  cp -f "$ROOT/config/$KDEFCONFIG" "$BUILD_DIR/.config"
else
  log "make $KDEFCONFIG + фрагмент config/kernel.fragment"
  "${MAKE[@]}" -s "$KDEFCONFIG"
fi
KCONFIG_CONFIG="$BUILD_DIR/.config" \
  "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$BUILD_DIR" \
  "$BUILD_DIR/.config" "$ROOT/config/kernel.fragment"
"${MAKE[@]}" -s olddefconfig

for sym in CONFIG_ARCH_QCOM CONFIG_ARM64 CONFIG_BLK_DEV_NVME CONFIG_EXT4_FS \
           CONFIG_DRM_MSM CONFIG_ATH12K CONFIG_EFI_STUB; do
  if grep -q "^${sym}=y" "$BUILD_DIR/.config"; then
    log "  $sym=y"
  elif grep -q "^${sym}=m" "$BUILD_DIR/.config"; then
    log "  $sym=m"
  else
    warn "  $sym не включён — проверьте config/kernel.fragment"
  fi
done

# --- сборка --------------------------------------------------------------
log "make Image modules dtbs"
# shellcheck disable=SC2086
"${MAKE[@]}" -j"$JOBS" $EXTRA_MAKE_ARGS Image modules dtbs

KREL=$("${MAKE[@]}" -s kernelrelease)
log "kernelrelease: $KREL"

# --- установка в пакет ---------------------------------------------------
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/boot" "$PKG_DIR/lib/modules"
cp -f "$BUILD_DIR/arch/arm64/boot/Image" "$PKG_DIR/boot/Image"
cp -f "$BUILD_DIR/.config" "$PKG_DIR/config"
cp -f "$BUILD_DIR/System.map" "$PKG_DIR/System.map"
printf '%s\n' "$KREL" >"$PKG_DIR/kernel-release.txt"

"${MAKE[@]}" -s INSTALL_MOD_PATH="$PKG_DIR" INSTALL_MOD_STRIP=1 modules_install
"${MAKE[@]}" -s INSTALL_DTBS_PATH="$PKG_DIR/boot/dtbs" dtbs_install

# --- проверка dtb --------------------------------------------------------
if [ -n "$DTB" ]; then
  [ -f "$PKG_DIR/boot/dtbs/$KREL/$DTB" ] || die "dtb не собран: $DTB"
  log "dtb: $DTB"
else
  found=$(find "$PKG_DIR/boot/dtbs/$KREL" -name '*.dtb' 2>/dev/null | head -5 || true)
  if [ -z "$found" ]; then
    warn "ни одного dtb не собрано — ядро не загрузится на ноуте без DTS"
  else
    log "dtb (первые): $(echo "$found" | xargs -n1 basename | tr '\n' ' ')"
  fi
  if ! find "$PKG_DIR/boot/dtbs/$KREL" -name '*83hl*' -o -name '*slim*' 2>/dev/null | grep -q .; then
    warn "не вижу dtb под 83HL/Slim — положите свой в dts/ (см. README)"
  fi
fi

# --- архив ---------------------------------------------------------------
TARBALL="$OUT/linux-$KERNEL_NAME-$KREL-arm64.tar.zst"
log "упаковка: $TARBALL"
tar -C "$PKG_DIR" -cf - . | zstd -T0 -"${ZSTD_LEVEL:-12}" -q -o "$TARBALL" -f

log "готово: $(human "$(stat -c %s "$TARBALL")")"
