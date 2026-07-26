#!/system/bin/sh
# Dolby Codec Port - Magisk installer
# Runs inside Magisk's install environment. $MODPATH points at the staged module.
#
# Two install modes, chosen by pressing volume keys during flash:
#   DIRECT  (Vol Up)  : remount /vendor rw and write blobs + init.rc +
#                       hwservice_contexts directly into the partition. Survives
#                       reboot; the ONLY mode where the DMS HAL and the c2 service
#                       actually get launched by init early enough. Requires
#                       dm-verity/AVB OFF (unlocked bootloader, patched vbmeta).
#   OVERLAY (Vol Down): classic Magisk magic-mount. Files appear under /vendor at
#                       post-fs-data, which is TOO LATE for init to parse the .rc
#                       or for hwservicemanager to read hwservice_contexts. This
#                       mode falls back to service.sh launching the daemons by
#                       hand and is best-effort only. Use DIRECT for real use.

SKIPUNZIP=0

ui_print ""
ui_print "  Dolby Codec Port (E-AC3 / AC4 decoders)"
ui_print "  ---------------------------------------"

# ---- Hard precondition checks -------------------------------------------------
ABILONG="$(getprop ro.product.cpu.abi)"
API="$(getprop ro.build.version.sdk)"

ui_print "- Device: $(getprop ro.product.device)  ABI: $ABILONG  API: $API"

case "$ABILONG" in
  arm64-v8a) ;;
  *) abort "! These blobs are arm64-v8a only. Aborting." ;;
esac

if [ "$API" -lt 33 ]; then
  ui_print "! WARNING: blobs target API 33 (Android 13)."
  ui_print "! Host is API $API — libstagefright_foundation-v33 and the"
  ui_print "! codec2 1.2 HIDL ABI will very likely be missing/mismatched."
  ui_print "! Continuing, but the c2 service will probably fail to dlopen."
fi

# ---- Dependency presence check (class C/D libs from README) --------------------
ui_print "- Checking host vendor for required shared libs..."
MISS=0
for L in libstagefright_foundation-v33.so libcodec2_soft_common.so \
         libsfplugin_ccodec_utils.so libavservices_minijail.so \
         libcodec2_hidl@1.2.so android.hardware.media.c2@1.2.so \
         libcodec2_vndk.so; do
  if [ ! -f "/vendor/lib64/$L" ] && [ ! -f "/system/lib64/$L" ] \
     && [ ! -f "/apex/com.android.media.swcodec/lib64/$L" ]; then
    ui_print "  MISSING: $L"
    MISS=$((MISS+1))
  fi
done
if [ "$MISS" -gt 0 ]; then
  ui_print "! $MISS required lib(s) not found on host."
  ui_print "! The decoders will not load until these are provided."
  ui_print "! You must add matching-version copies to system/vendor/lib64/"
  ui_print "! before this module can work. See README section 'Missing deps'."
fi

# ---- Choose install mode ------------------------------------------------------
ui_print "- Select install mode:"
ui_print "    Vol UP   = DIRECT  (write into /vendor, needs verity OFF)"
ui_print "    Vol DOWN = OVERLAY (magic-mount, best-effort)"
MODE="overlay"
key_click() {
  # returns via global $MODE
  while true; do
    timeout 8 /system/bin/getevent -lqc 1 2>/dev/null | grep -q KEY_VOLUMEUP && { MODE="direct"; return; }
    timeout 8 /system/bin/getevent -lqc 1 2>/dev/null | grep -q KEY_VOLUMEDOWN && { MODE="overlay"; return; }
  done
}
key_click
ui_print "- Mode: $MODE"

set_perm_recursive "$MODPATH/system" 0 0 0755 0644
# executables and .so need exec/read; Magisk sets contexts on magic-mount, but
# for DIRECT mode we set them ourselves below.
[ -d "$MODPATH/system/vendor/bin/hw" ] && set_perm_recursive "$MODPATH/system/vendor/bin/hw" 0 0 0755 0755
[ -d "$MODPATH/system/vendor/lib64" ]  && set_perm_recursive "$MODPATH/system/vendor/lib64" 0 0 0755 0644

# ---- media_codecs include injection ------------------------------------------
# The decoder <MediaCodec> entries live in media_codecs_dolby_audio.xml, pulled
# in via an <Include> from the primary media_codecs xml. We must MERGE, never
# replace the OEM file. Locate the active primary file via the ro property.
PRIMARY_REL="$(getprop ro.media.xml_variant.codecs)"
[ -z "$PRIMARY_REL" ] && PRIMARY_REL="/vendor/etc/media_codecs.xml"
ui_print "- Primary media_codecs: $PRIMARY_REL"

merge_media_codecs() {
  # $1 = source primary path, $2 = destination primary path to write
  local SRC="$1" DST="$2"
  if grep -q 'media_codecs_dolby_audio.xml' "$SRC" 2>/dev/null; then
    cp -f "$SRC" "$DST"
    ui_print "  (include already present)"
    return
  fi
  # insert the include just before the closing </MediaCodecs> or </Included>
  awk '
    /<\/(Included|MediaCodecs)>/ && !done {
      print "    <Include href=\"media_codecs_dolby_audio.xml\" />"; done=1
    }
    { print }
  ' "$SRC" > "$DST"
  ui_print "  (dolby include injected)"
}

if [ "$MODE" = "direct" ]; then
  ui_print "- DIRECT mode: remounting /vendor read-write..."
  BLK="$(mount | awk '$3=="/vendor"{print $1; exit}')"
  [ -z "$BLK" ] && BLK="/vendor"
  mount -o rw,remount /vendor 2>/dev/null || mount -o rw,remount "$BLK" /vendor 2>/dev/null \
    || abort "! Could not remount /vendor rw. Is verity/AVB really off?"

  ui_print "- Copying blobs into /vendor ..."
  cp -rf "$MODPATH/system/vendor/." /vendor/ || abort "! copy to /vendor failed"

  ui_print "- Merging media_codecs include ..."
  merge_media_codecs "$PRIMARY_REL" "$PRIMARY_REL"

  ui_print "- Installing SELinux labels into /vendor ..."
  # (a) hwservice label for IDms — read by hwservicemanager early next boot.
  HWC=/vendor/etc/selinux/vendor_hwservice_contexts
  if [ -f "$HWC" ] && ! grep -q 'vendor.dolby.hardware.dms::IDms' "$HWC"; then
    printf 'vendor.dolby.hardware.dms::IDms u:object_r:hal_dms_hwservice:s0\n' >> "$HWC"
    ui_print "  + IDms hwservice label"
  fi
  # (b) exec labels in file_contexts so init's domain transition survives the
  #     restorecon that runs on every boot. Without this the daemon binary would
  #     revert to vendor_file and — with the strict (non-permissive) policy — the
  #     DMS service would fail to start.
  VFC=/vendor/etc/selinux/vendor_file_contexts
  if [ -f "$VFC" ]; then
    grep -q 'vendor\.dolby\.hardware\.dms@2\.0-service' "$VFC" || \
      printf '/vendor/bin/hw/vendor\\.dolby\\.hardware\\.dms@2\\.0-service u:object_r:hal_dms_default_exec:s0\n' >> "$VFC"
    grep -q 'vendor\.dolby\.media\.c2@1\.0-service' "$VFC" || \
      printf '/vendor/bin/hw/vendor\\.dolby\\.media\\.c2@1\\.0-service u:object_r:mediacodec_exec:s0\n' >> "$VFC"
    ui_print "  + exec file_contexts entries"
  else
    ui_print "! /vendor/etc/selinux/vendor_file_contexts not found — exec labels"
    ui_print "! rely on chcon xattr only (may not survive a /vendor restorecon)."
  fi
  # (c) apply the exec labels now too; the xattr persists across reboot.
  chcon u:object_r:hal_dms_default_exec:s0 /vendor/bin/hw/vendor.dolby.hardware.dms@2.0-service 2>/dev/null
  chcon u:object_r:mediacodec_exec:s0      /vendor/bin/hw/vendor.dolby.media.c2@1.0-service 2>/dev/null

  mount -o ro,remount /vendor 2>/dev/null

  # In direct mode we do not want Magisk to also magic-mount these files.
  ui_print "- Neutralising module overlay (files are now in /vendor) ..."
  rm -rf "$MODPATH/system"
  # keep sepolicy.rule + system.prop + service.sh so policy/props still apply.
  touch "$MODPATH/disable_overlay"
else
  ui_print "- OVERLAY mode: files will magic-mount at boot."
  ui_print "- Staging merged media_codecs for overlay ..."
  mkdir -p "$MODPATH/system/vendor/etc"
  DSTPRIM="$MODPATH/system/vendor/etc/$(basename "$PRIMARY_REL")"
  merge_media_codecs "$PRIMARY_REL" "$DSTPRIM"
  ui_print "! NOTE: init will not parse the module .rc and hwservicemanager will"
  ui_print "! not see the new hwservice label at overlay time. service.sh will try"
  ui_print "! to launch the daemons by hand — expect this to be flaky."
fi

ui_print "- Done. Reboot to apply."
ui_print ""
