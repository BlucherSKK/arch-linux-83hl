#!/usr/bin/env bash
# Общие функции для скриптов сборки. Подключать через: source scripts/lib.sh
set -euo pipefail

: "${ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${OUT:=$ROOT/out}"
: "${CACHE:=$OUT/cache}"

KERNEL_NAME="${KERNEL_NAME:-83hl}"
IMAGE_LABEL="${IMAGE_LABEL:-arch83hl}"
ESP_LABEL="${ESP_LABEL:-ESP83HL}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "не найдена команда: $c"
  done
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

human() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"
}

# Первый сектор и размер (в секторах) раздела $1 образа $2
part_geom() {
  local n=$1 img=$2 info s z
  info=$(LC_ALL=C sgdisk -i "$n" "$img") || return 1
  s=$(awk -F: '/^First sector/    { print $2 }' <<<"$info" | awk '{ print $1 }')
  z=$(awk -F: '/^Partition size/  { print $2 }' <<<"$info" | awk '{ print $1 }')
  [ -n "$s" ] && [ -n "$z" ] || return 1
  printf '%s %s\n' "$s" "$z"
}

# Сколько всего секторов в файле
file_sectors() {
  local bytes
  bytes=$(stat -c %s "$1")
  echo $(( bytes / 512 ))
}
