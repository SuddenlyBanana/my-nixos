firmwareBoot="$firmware/share/raspberrypi/boot"
bootDir="$out/share/raspberrypi/boot"

mkdir -p "$bootDir/overlays"
cp "$firmwareBoot"/bootcode.bin "$firmwareBoot"/start*.elf "$firmwareBoot"/fixup*.dat \
  "$firmwareBoot"/LICENCE.broadcom "$bootDir/"
cp "$kernel"/dtbs/broadcom/bcm2712*.dtb "$bootDir/"
cp "$kernel"/dtbs/overlays/*.dtb "$kernel"/dtbs/overlays/*.dtbo "$bootDir/overlays/"
