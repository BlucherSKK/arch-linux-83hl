#!/usr/bin/env bash
# Достаёт прошивки ADSP/CDSP/GPU для 83HL из дампа Windows DriverStore.
#
#   bash scripts/extract-firmware.sh [DUMP_DIR] [OUT_DIR]
#   bash scripts/extract-firmware.sh --tar          # ещё и firmware-83hl.tar.gz
#
# DUMP_DIR по умолчанию ../83/drivers (тот самый дамп),
# OUT_DIR  по умолчанию ./firmware.
#
# Что копируется в qcom/x1p42100/LENOVO/83HL/:
#   qcadsp8380.mbn adsp_dtbs.elf *.jsn      (qcsubsys_ext_adsp8380)
#   qccdsp8380.mbn cdsp_dtbs.elf *.jsn      (qcnspmcdm_ext_cdsp8380 / qcsubsys_ext_cdsp8380)
#   qcdxkmsucpurwa.mbn                      (qcdx8380, zap shader для Adreno X1-45)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

MAKE_TAR=0
if [ "${1:-}" = "--tar" ]; then MAKE_TAR=1; shift; fi

DUMP=${1:-${DUMP_DIR:-$ROOT/../83/drivers}}
OUT=${2:-${FIRMWARE_OUT:-$ROOT/firmware}}
MACHINE=${MACHINE:-83HL}
DEST="$OUT/qcom/x1p42100/LENOVO/$MACHINE"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$DUMP" ] || die "нет каталога дампа: $DUMP"

newest() { ls -dt "$@" 2>/dev/null | head -1; }

adsp=$(newest "$DUMP"/qcsubsys_ext_adsp8380.inf_arm64_*)
cdsp=$(newest "$DUMP"/qcnspmcdm_ext_cdsp8380.inf_arm64_*)
[ -n "$cdsp" ] || cdsp=$(newest "$DUMP"/qcsubsys_ext_cdsp8380.inf_arm64_*)
gpu=$(newest "$DUMP"/qcdx8380.inf_arm64_*)

[ -n "$adsp" ] || die "не нашёл qcsubsys_ext_adsp8380.inf_arm64_* в $DUMP"
[ -n "$cdsp" ] || die "не нашёл qcnspmcdm_ext_cdsp8380.inf_arm64_* в $DUMP"
[ -n "$gpu" ]  || die "не нашёл qcdx8380.inf_arm64_* в $DUMP"

log "adsp: $adsp"
log "cdsp: $cdsp"
log "gpu:  $gpu"

mkdir -p "$DEST"

copy() { # copy <file> [<file>...]
  local f
  for f in "$@"; do
    [ -f "$f" ] || die "нет файла: $f"
    cp -f "$f" "$DEST/"
  done
}

copy "$adsp/qcadsp8380.mbn" "$adsp/adsp_dtbs.elf"
copy "$cdsp/qccdsp8380.mbn" "$cdsp/cdsp_dtbs.elf"
copy "$gpu/qcdxkmsucpurwa.mbn"

# .jsn-файлы (описания образов для ADSP/CDSP) — если есть
shopt -s nullglob
jsn=("$adsp"/*.jsn "$cdsp"/*.jsn)
[ ${#jsn[@]} -gt 0 ] && cp -f "${jsn[@]}" "$DEST/"

log "готово: $DEST"
ls -lh "$DEST"

if [ "$MAKE_TAR" = "1" ]; then
  tar -czf "$OUT/../firmware-83hl.tar.gz" -C "$OUT" qcom
  log "архив: $(cd "$OUT/.." && pwd)/firmware-83hl.tar.gz"
  echo "Залейте его как release asset и задайте FIRMWARE_URL в переменных репозитория."
fi
