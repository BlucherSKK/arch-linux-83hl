# Прошивки для 83HL

Сюда `scripts/extract-firmware.sh` складывает файлы из Windows-дампа:

```
firmware/qcom/x1p42100/LENOVO/83HL/
  qcadsp8380.mbn  adsp_dtbs.elf  adspr.jsn adsps.jsn adspua.jsn battmgr.jsn
  qccdsp8380.mbn  cdsp_dtbs.elf  cdspr.jsn
  qcdxkmsucpurwa.mbn
```

Без них нет звука (ADSP/CDSP не поднимаются) и GPU-акселерации
(`msm` не может загрузить zap shader). Подробности — `docs/83hl-linux.md`.

## Как заполнить

```bash
bash scripts/extract-firmware.sh          # из ../83/drivers
bash scripts/extract-firmware.sh --tar    # + firmware-83hl.tar.gz
```

`make-rootfs.sh` копирует содержимое этого каталога в
`/usr/lib/firmware/` образа.

## Почему файлов нет в git

Это прошивки Qualcomm из OEM-пакета Lenovo — их не стоит класть в
публичный репозиторий. Каталог исключён в `.gitignore` (кроме этого
README).

В CI задайте secret или variable `FIRMWARE_URL` — ссылку на
`firmware-83hl.tar.gz`. Подходит обычная ссылка Google Drive
(`/file/d/<id>/view?usp=sharing`, доступ «все, у кого есть ссылка») —
workflow сам превратит её в прямую. Необязательно можно задать
`FIRMWARE_SHA256`.

Если репозиторий приватный и вы хотите самодостаточную сборку, можно
закоммитить файлы принудительно:

```bash
git add -f firmware/qcom
```
