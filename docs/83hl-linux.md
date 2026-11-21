# Linux на IdeaPad Slim 5x 14Q8X9 (83HL)

Сводка по [issue #94](https://github.com/jglathe/linux_ms_dev_kit/issues/94)
(звук/GPU/прошивки) и [issue #102](https://github.com/jglathe/linux_ms_dev_kit/issues/102)
(глубокий s2idle на EL2). Всё, что здесь описано, проверено владельцами
таких же ноутов, а не выведено из дампа.

## 1. Ядро

| | |
|---|---|
| репозиторий | <https://github.com/jglathe/linux_ms_dev_kit> (это полноценное дерево Linux, не только скрипты) |
| ветка | `jg/ubuntu-qcom-x1e-7.2.y`, HEAD `d84d9b29` → `7.2.9-jg-0` |
| конфиг | `arch/arm64/configs/ubuntu_x1e_defconfig` |
| DTB (OLED) | `qcom/x1p42100-lenovo-ideapad-slim5x-oled.dtb` |
| DTB (LCD) | `qcom/x1p42100-lenovo-ideapad-slim5x-lcd.dtb` |

`83HL` выпускается в двух вариантах: OLED (2.8K) и LCD/IPS (WUXGA
1920×1200). DTB отличаются только подсветкой (PWM). В CI/скриптах по
умолчанию берётся **LCD** — это вариант с WUXGA. Для OLED-ноута задайте
`DTB=qcom/x1p42100-lenovo-ideapad-slim5x-oled.dtb`.

Почему 7.2.x, хотя Jens считает лучшим 7.1.13-jg-0: DTS для Slim 5x
(`x1p42100-lenovo-ideapad-slim5x*.dts`) появился только в 7.2.x. В 7.2.x
были проблемы с lid switch, в 7.2.9 они исправлены — на этой версии
крышка/s2idle работают.

`ubuntu_x1e_defconfig` — это конфиг, на котором у людей работает всё
(Wi-Fi, GPU, звук, KVM), поэтому мы берём его целиком и только дополняем
`config/kernel.fragment`:

* `CONFIG_LOCALVERSION="-83hl"` — версия ядра получается `7.2.9-83hl`;
* без debug info/BTF — сборка заметно быстрее, модули меньше;
* без подписи модулей и без ключей Ubuntu;
* `CONFIG_HOTPLUG_PCI_PCIE=y`, `CONFIG_CRYPTO_DEV_QCE=m` — из issue #102,
  нужны для ухода PCIe root port в D3 и для `sync_state` interconnect.

Сборка: `scripts/build-kernel.sh` (`KDEFCONFIG=ubuntu_x1e_defconfig`),
в CI — job `kernel` (timeout 180 мин: в конфиге ~6200 модулей).

## 2. Прошивки ADSP/CDSP/GPU

Без них нет ни звука, ни GPU-акселерации: remoteproc остаётся в
`attached`, `q6apm`/`q6prm` не поднимаются, SoundWire и кодеки висят в
deferred probe.

DT просит файлы по путям:

```
qcom/x1p42100/LENOVO/83HL/qcadsp8380.mbn     # ADSP
qcom/x1p42100/LENOVO/83HL/adsp_dtbs.elf
qcom/x1p42100/LENOVO/83HL/qccdsp8380.mbn     # CDSP
qcom/x1p42100/LENOVO/83HL/cdsp_dtbs.elf
qcom/x1p42100/LENOVO/83HL/qcdxkmsucpurwa.mbn # GPU zap shader (Adreno X1-45)
```

Плюс `.jsn`-описания (`adspr.jsn`, `adsps.jsn`, `adspua.jsn`,
`battmgr.jsn`, `cdspr.jsn`) — их тоже кладём рядом.

Откуда взять: из Windows-дампа `83/drivers` (DriverStore). Каталоги:

| файлы | каталог |
|---|---|
| `qcadsp8380.mbn`, `adsp_dtbs.elf`, `*.jsn` | `qcsubsys_ext_adsp8380.inf_arm64_*` |
| `qccdsp8380.mbn`, `cdsp_dtbs.elf`, `*.jsn` | `qcnspmcdm_ext_cdsp8380.inf_arm64_*` (или `qcsubsys_ext_cdsp8380.*`) |
| `qcdxkmsucpurwa.mbn` | `qcdx8380.inf_arm64_*` |

```bash
# из корня initish; дамп по умолчанию ../83/drivers
bash scripts/extract-firmware.sh

# то же + архив firmware-83hl.tar.gz для FIRMWARE_URL
bash scripts/extract-firmware.sh --tar
```

Скрипт раскладывает файлы в `firmware/qcom/x1p42100/LENOVO/83HL/`,
`make-rootfs.sh` копирует их в `/usr/lib/firmware/` образа.

В CI прошивок нет (они не в git). Рабочая схема — Google Drive:

1. залить `firmware-83hl.tar.gz` на Google Drive и открыть доступ
   «все, у кого есть ссылка»;
2. положить ссылку в secret репозитория **`FIRMWARE_URL`**
   (Settings → Secrets and variables → Actions → Secrets);
3. при желании — `FIRMWARE_SHA256` с контрольной суммой архива.

`make-rootfs.sh` понимает обычную ссылку вида
`https://drive.google.com/file/d/<id>/view?usp=sharing` и сам превращает
её в прямую `uc?export=download&confirm=t&id=<id>`. Если Drive вернёт
HTML вместо архива (закрыт доступ, кончилась квота), сборка упадёт с
понятной ошибкой.

Альтернативы: закоммитить `firmware/` в приватный репозиторий или
собрать образ локально с `firmware/`.

**Лицензия:** это прошивки Qualcomm из OEM-пакета Lenovo. Для публичного
репозитория их лучше не коммитить, а раздавать ссылкой на свой архив.

`linux-firmware-qcom` (ставится в образ из репозитория ALARM) даёт
остальное: `qcom/gen71500_sqe.fw.zst`, `qcom/gen71500_gmu.bin.zst`,
`qcom/x1e80100/X1E80100-Romulus-tplg.bin.zst`, Wi-Fi/BT для WCN7850.

Проверка после загрузки:

```bash
cat /sys/class/remoteproc/remoteproc0/state     # running
dmesg | grep -iE 'adsp|cdsp|q6|adreno'
```

## 3. Звук

Карта регистрируется как `X1E80100-LENOVO-Ideapad-5`, а topology-файла
с таким именем в linux-firmware нет. Рабочее решение из issue #94 —
симлинк на Romulus:

```
/usr/lib/firmware/qcom/x1e80100/X1E80100-LENOVO-Ideapad-5-tplg.bin
  -> X1E80100-Romulus-tplg.bin
```

В `linux-firmware-qcom` у ALARM файл лежит несжатым (`.bin`), в upstream —
ещё и `.bin.zst`. `make-rootfs.sh` сам подбирает расширение и создаёт
симлинк (плюс вариант `-2in1`). В образ также ставятся
`alsa-utils` и `alsa-ucm-conf`.

```bash
aplay -l                       # должна быть карта X1E80100-LENOVO-Ideapad-5
alsamixer                      # проверить, что каналы не в mute
speaker-test -c2 -twav
```

Если карты нет — смотреть `dmesg | grep -iE 'adsp|q6apm|soundwire'`:
почти всегда это отсутствующая прошивка ADSP (см. выше).

## 4. GPU

Adreno X1-45 (`msm`) требует zap shader `qcdxkmsucpurwa.mbn` (лежит в
Windows-дампе) и `gen71500_sqe.fw.zst` + `gen71500_gmu.bin.zst` из
`linux-firmware-qcom`.

```bash
dmesg | grep -i adreno
glxinfo -B        # если поставить mesa-utils
```

## 5. Wi-Fi / Bluetooth

WCN7850 (FastConnect 7800): `ath12k` + `hci_qca`, прошивки из
`linux-firmware-atheros` / `linux-firmware-qcom`. В конфиге ядра
`CONFIG_ATH12K=m`, `CONFIG_QCOM_Q6V5_WCSS=m` (WCN7850 не использует
remoteproc, но модули нужны).

## 6. Сон

На EL1-ядрах (включая 7.2.9) работает только s2idle: `cxsd`/`ddr`
остаются на 0, потребление в простое ~1.9–2.2 Вт. Крышка (lid switch)
на 7.2.9 работает.

Глубокий сон (~1.2–1.3 Вт, 92 % residency) из
[issue #102](https://github.com/jglathe/linux_ms_dev_kit/issues/102)
требует всей цепочки EL2 и в этот образ **не входит**:

* загрузка через `slbounce` + `qebspil` (ADSP/CDSP стартуют до
  `ExitBootServices`), EL2-вариант DTB
  (`x1p42100-lenovo-ideapad-slim5x-oled-el2.dtb`), `cma=128M`,
  `pcie_port_pm=force`;
* в DT кластерные состояния CL5 помечены `system-sleep-only` и добавлены
  в `domain-idle-states` PSCI (иначе прошивка отвечает `PSCI_DENIED`);
* `CONFIG_HOTPLUG_PCI_PCIE=y` (уже включено в нашем фрагменте), иначе
  root port Wi-Fi не уходит в D3 и `ath12k` не переживает сон;
* модули `el1tmr` и `aoss_cxsd_only`, отключение лишних wake-источников
  (USB-контроллеры, gpio-keys крышки, тачпад).

Готовый набор: вложение `slim5x-el2-sleep.zip` в issue #102.

## 7. Мелочи, о которых предупреждал Jens

* **не отвязывать** `dwc3`-контроллеры (`unbind`) — ломает USB/загрузку;
* RTC alarm недоступен: IRQ будильника принадлежит прошивке ADSP, это
  нормально для всех X1;
* Secure Boot должен быть выключен — UKI не подписан;
* после смены ядра проверяйте `dmesg | grep -i firmware`, если что-то
  перестало находиться: список путей прошивок в DT — самый частый
  источник «тихих» отказов.
