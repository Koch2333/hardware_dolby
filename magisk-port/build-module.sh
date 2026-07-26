#!/usr/bin/env bash
# Assembles the flashable Magisk module zip for the Dolby CODEC port from the
# blobs already present in this repo (proprietary/ and configs/). Run from the
# repo root or anywhere — paths are resolved relative to this script.
#
#   ./magisk-port/build-module.sh
#
# Output: magisk-port/out/dolby_codec_port.zip
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MOD="$HERE/magisk-module"
STAGE="$HERE/out/stage"
OUT="$HERE/out/dolby_codec_port.zip"

echo ">> repo root: $REPO"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"

# 1) module scaffolding (scripts, props, sepolicy, installer stub)
cp -a "$MOD/module.prop"       "$STAGE/"
cp -a "$MOD/customize.sh"      "$STAGE/"
cp -a "$MOD/post-fs-data.sh"   "$STAGE/"
cp -a "$MOD/service.sh"        "$STAGE/"
cp -a "$MOD/uninstall.sh"      "$STAGE/"
cp -a "$MOD/sepolicy.rule"     "$STAGE/"
cp -a "$MOD/system.prop"       "$STAGE/"
mkdir -p "$STAGE/META-INF/com/google/android"
cp -a "$MOD/META-INF/com/google/android/update-binary"  "$STAGE/META-INF/com/google/android/"
cp -a "$MOD/META-INF/com/google/android/updater-script" "$STAGE/META-INF/com/google/android/"

# 2) codec-only blob subset -> system/vendor/...
VBIN="$STAGE/system/vendor/bin/hw"
VLIB="$STAGE/system/vendor/lib64"
VETC="$STAGE/system/vendor/etc"
mkdir -p "$VBIN" "$VLIB" "$VETC/vintf/manifest" "$VETC/init" "$VETC/dolby"

echo ">> copying decoder + DMS binaries"
cp -a "$REPO/proprietary/vendor/bin/hw/vendor.dolby.media.c2@1.0-service"        "$VBIN/"
cp -a "$REPO/proprietary/vendor/bin/hw/vendor.dolby.hardware.dms@2.0-service"    "$VBIN/"

echo ">> copying decoder + DMS shared libs (codec closure only, no soundfx)"
for so in \
  libcodec2_soft_ddpdec.so \
  libcodec2_soft_ac4dec.so \
  libcodec2_soft_dolby.so \
  libcodec2_store_dolby.so \
  libdeccfg.so \
  libdapparamstorage.so \
  libdlbdsservice.so \
  vendor.dolby.hardware.dms@2.0.so \
  vendor.dolby.hardware.dms@2.0-impl.so \
; do
  cp -a "$REPO/proprietary/vendor/lib64/$so" "$VLIB/"
done

echo ">> copying configs"
cp -a "$REPO/configs/media/media_codecs_dolby_audio.xml"                     "$VETC/"
cp -a "$REPO/configs/vintf/vendor.dolby.media.c2@1.0-service.xml"            "$VETC/vintf/manifest/"
cp -a "$REPO/configs/vintf/vendor.dolby.hardware.dms@2.0-service.xml"        "$VETC/vintf/manifest/"
cp -a "$REPO/configs/dax/dax-default.xml"                                    "$VETC/dolby/"
cp -a "$REPO/proprietary/vendor/etc/init/vendor.dolby.media.c2@1.0-service.rc"      "$VETC/init/"
cp -a "$REPO/proprietary/vendor/etc/init/vendor.dolby.hardware.dms@2.0-service.rc"  "$VETC/init/"

# 3) zip it
echo ">> zipping -> $OUT"
( cd "$STAGE" && zip -r9 "$OUT" . -x '.*' >/dev/null )
echo ">> done: $OUT"
echo ">> AC4 note: media_codecs_dolby_audio.xml declares only AC3/E-AC3/E-AC3-JOC."
echo ">> To also expose c2.dolby.ac4.decoder you must add an AC4 <MediaCodec> block (see README)."
