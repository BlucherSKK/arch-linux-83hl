# 83HL — что известно из дампа Windows

Источник: `../83` (собрано `tools/collect-83hl-windows.ps1` на заводской Windows).

## Система

| поле | значение |
|---|---|
| Machine Type | **83HL** |
| Product | IdeaPad Slim 5 14Q8X9 |
| CPU | Snapdragon X Plus **X1P42100** (ARMv8, 8×Oryon) |
| RAM | 32 ГБ (33897037824 байт) |
| BIOS | PUCN52WW, INSYDE, 30.09.2025, SMBIOS 3.6 |
| Secure Boot | выключен на момент сбора (`system/secureboot.txt`) |
| Диск | Samsung MZAL81T0HDLB (NVMe, PCI `144D:A80D`) |

## Ключевые устройства

| устройство | ID | драйвер Linux (план) |
|---|---|---|
| GPU Adreno X1-45 | ACPI/PCI | `msm` + `adreno` |
| Wi-Fi FastConnect 7800 | PCI `17cb:1107` | `ath12k` (+ `qrtr`, `mhi`) |
| Bluetooth | PCI `17cb:0111` / `QCOM0C6B` | `hci_qca`, `btqca` |
| NVMe | PCI `144D:A80D` | `nvme` |
| Card reader | PCI `1217:8621` (BayHub) | `sdhci_pci` |
| USB | Synopsys xHCI + dwc3 | `xhci_pci`, `dwc3-qcom` |
| Аудио | Aqstic (WCD938x + Q6) | `snd-soc-x1e80100`, SoundWire; нужны прошивки ADSP/CDSP |
| Тачпад | I2C HID | `i2c-hid-of`, `hid-multitouch` |
| Камера | USB (`Integrated Camera`) | `uvcvideo` |
| TPM | `MSFT0101` / TrEE | `tpm_crb` (если заработает) |

## ACPI

`acpi/` содержит MCFG, FACP, APIC, CSRT, PPTT, GTDT, FPDT, UEFI, DBG2,
IORT, SDEV, SPCR, TPM2, MSDM, BGRT и один SSDT. Полный **DSDT** (335 КБ)
и XSDT/FACS лежат в `acpi/registry/` (вытащены из `HKLM\HARDWARE\ACPI`).

Разбор:

```bash
iasl -d acpi/registry/DSDT_00000003_00000000.bin
```

Важные таблицы для порта:

* `IORT` — SMMU/ITS, соответствие устройств стримам (нужно для DMA в DT);
* `PPTT` — топология кластеров/ядер (для `cpu-map` в DTS);
* `GTDT` — таймеры;
* `MCFG` — ECAM PCIe;
* `SPCR` — serial console;
* `DSDT` — вся периферия, GPIO, регуляторы, `_DSD`-свойства.

## Что ещё посмотреть

* `devices/acpi-devices.csv` — список `ACPI\QCOMxxxx` с привязкой к сервисам;
* `devices/enum-acpi.reg` — ресурсы (MMIO/IRQ/GPIO) каждого ACPI-устройства;
* `drivers/` — OEM-INF (Qualcomm/Lenovo), имена подсказывают блоки;
* `system/msinfo32.txt`, `system/bcdedit.txt` — окружение загрузки.

Как это заводится в Linux (ядро, прошивки, звук, GPU, сон) —
[docs/83hl-linux.md](83hl-linux.md).
