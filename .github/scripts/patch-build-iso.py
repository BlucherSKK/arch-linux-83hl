#!/usr/bin/env python3
"""Adapt mich-de's build-iso.sh to a headless CI environment.

Changes (idempotent enough for a fresh clone):
  1. Firmware: only extract from a real Windows DriverStore when /mnt/c exists;
     in CI the files are staged from the FULL_FIRMWARE secret.
  2. 83HL DKMS modules are optional: if out/modules is missing/empty the ISO is
     still built (boot/display/audio/WiFi do not need iris/videocc/EC).
  3. The early-boot firmware cpio only includes files that actually exist.
"""
import sys

p = sys.argv[1] if len(sys.argv) > 1 else 'scripts/build-iso.sh'
s = open(p).read()

# 0. don't hard-code the stubble package version (resolute currently has 9-1)
old = '[ -f debs/stubble_9-1_arm64.deb ] || { echo "manca debs/ (apt-get download ...)"; exit 1; }\n'
new = ('STUBBLE_DEB=$(ls debs/stubble_*.deb 2>/dev/null | head -1)\n'
       '[ -n "$STUBBLE_DEB" ] || { echo "manca debs/stubble_*.deb (apt-get download stubble)"; exit 1; }\n')
assert old in s, 'stubble check not found'
s = s.replace(old, new, 1)

old = 'mkdir -p "$W/stubble"; dpkg-deb -x debs/stubble_9-1_arm64.deb "$W/stubble"\n'
new = 'mkdir -p "$W/stubble"; dpkg-deb -x "$STUBBLE_DEB" "$W/stubble"\n'
assert old in s, 'stubble extract not found'
s = s.replace(old, new, 1)

# 1. firmware: only extract from a real Windows DriverStore if present
old = 'tools/extract-firmware.sh >/dev/null\n'
new = ('if [ -d /mnt/c/Windows/System32/DriverStore ]; then\n'
       '  tools/extract-firmware.sh >/dev/null\n'
       'else\n'
       '  echo "firmware: using pre-staged files from FULL_FIRMWARE"\n'
       'fi\n')
assert old in s, 'firmware line not found'
s = s.replace(old, new, 1)

# 2. first modules block -> conditional
old = '''# moduli 83HL (scripts/build-video.sh) e sign-file nell'overlay
[ -d out/modules ] || { echo "manca out/modules: lancia scripts/build-video.sh"; exit 1; }
mkdir -p overlay/usr/lib/83hl/modules overlay/usr/local/lib/83hl
cp -r out/modules/* overlay/usr/lib/83hl/modules/
rm -rf overlay/usr/src/83hl-drivers-1.0; mkdir -p overlay/usr/src; cp -r dkms/83hl-drivers-1.0 overlay/usr/src/
install -m755 /usr/src/linux-headers-$(ls out/modules | head -1)/scripts/sign-file overlay/usr/local/lib/83hl/sign-file
'''
new = '''# moduli 83HL (scripts/build-video.sh) e sign-file nell'overlay
if [ -d out/modules ] && [ -n "$(ls -A out/modules 2>/dev/null)" ]; then
  mkdir -p overlay/usr/lib/83hl/modules overlay/usr/local/lib/83hl
  cp -r out/modules/* overlay/usr/lib/83hl/modules/
  rm -rf overlay/usr/src/83hl-drivers-1.0; mkdir -p overlay/usr/src; cp -r dkms/83hl-drivers-1.0 overlay/usr/src/
  install -m755 /usr/src/linux-headers-$(ls out/modules | head -1)/scripts/sign-file overlay/usr/local/lib/83hl/sign-file
else
  echo "WARN: 83HL modules not built - ISO without iris/videocc/EC (boot unaffected)"
fi
'''
assert old in s, 'first modules block not found'
s = s.replace(old, new, 1)

# 3. second (live) modules block -> conditional
old = '''[ -d "overlay/usr/lib/83hl/modules/$KV" ] || { echo "manca out/modules/$KV: lancia scripts/build-video.sh $KV"; exit 1; }
MD="$W/kmods"; mkdir -p "$MD"; dpkg-deb -x hdr/linux-modules-${KV}_*.deb "$MD"; mkdir -p "$MD/lib"; ln -sfn ../usr/lib/modules "$MD/lib/modules"
mkdir -p "$MD/usr/lib/modules/$KV/updates/83hl"
for m in overlay/usr/lib/83hl/modules/$KV/*.ko; do
  install -m644 "$m" "$MD/usr/lib/modules/$KV/updates/83hl/"
  /usr/src/linux-headers-$KV/scripts/sign-file sha512 keys/MOK.key keys/MOK.crt "$MD/usr/lib/modules/$KV/updates/83hl/$(basename "$m")"
done
/usr/sbin/depmod -b "$MD" "$KV"
/usr/sbin/modinfo -b "$MD" -k "$KV" -F filename qcom_iris videocc_x1p42100
sudo mkdir -p "$W/live/usr/lib/modules/$KV/updates"
sudo cp -r "$MD/usr/lib/modules/$KV/updates/83hl" "$W/live/usr/lib/modules/$KV/updates/"
sudo cp "$MD"/usr/lib/modules/$KV/modules.* "$W/live/usr/lib/modules/$KV/"
rm -rf "$MD"
'''
new = '''if [ -d "overlay/usr/lib/83hl/modules/$KV" ]; then
MD="$W/kmods"; mkdir -p "$MD"; dpkg-deb -x hdr/linux-modules-${KV}_*.deb "$MD"; mkdir -p "$MD/lib"; ln -sfn ../usr/lib/modules "$MD/lib/modules"
mkdir -p "$MD/usr/lib/modules/$KV/updates/83hl"
for m in overlay/usr/lib/83hl/modules/$KV/*.ko; do
  install -m644 "$m" "$MD/usr/lib/modules/$KV/updates/83hl/"
  /usr/src/linux-headers-$KV/scripts/sign-file sha512 keys/MOK.key keys/MOK.crt "$MD/usr/lib/modules/$KV/updates/83hl/$(basename "$m")" \\
    || echo "WARN: sign-file failed for $(basename "$m") (Secure Boot off, module still loads)"
done
/usr/sbin/depmod -b "$MD" "$KV"
/usr/sbin/modinfo -b "$MD" -k "$KV" -F filename qcom_iris videocc_x1p42100 \\
  || echo "WARN: modinfo did not find all 83HL modules"
sudo mkdir -p "$W/live/usr/lib/modules/$KV/updates"
sudo cp -r "$MD/usr/lib/modules/$KV/updates/83hl" "$W/live/usr/lib/modules/$KV/updates/"
sudo cp "$MD"/usr/lib/modules/$KV/modules.* "$W/live/usr/lib/modules/$KV/"
rm -rf "$MD"
else
  echo "WARN: no 83HL modules for $KV - live ISO continues without them"
fi
'''
assert old in s, 'second modules block not found'
s = s.replace(old, new, 1)

# 4. firmware cpio: only include files that actually exist in the archive
old = '''A=(); for f in qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf qcdxkmsucpurwa.mbn; do A+=("$L/$f=overlay/$L/$f"); done
for f in gen71500_sqe.fw.zst gen71500_gmu.bin.zst; do A+=("$F/$f=$W/min/$F/$f"); done
'''
new = '''A=(); for f in qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf qcdxkmsucpurwa.mbn; do if [ -f "overlay/$L/$f" ]; then A+=("$L/$f=overlay/$L/$f"); else echo "WARN: firmware $f missing"; fi; done
for f in gen71500_sqe.fw.zst gen71500_gmu.bin.zst; do if [ -f "$W/min/$F/$f" ]; then A+=("$F/$f=$W/min/$F/$f"); else echo "WARN: firmware $f missing from ISO minimal layer"; fi; done
'''
assert old in s, 'firmware cpio block not found'
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print('patched', p)
