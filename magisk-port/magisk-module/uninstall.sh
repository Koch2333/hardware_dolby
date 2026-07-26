#!/system/bin/sh
# Best-effort cleanup. For OVERLAY installs Magisk removes the magic-mounts by
# itself; nothing to do. For DIRECT installs the blobs were written into /vendor
# and are NOT tracked by Magisk — they persist. We cannot reliably know the
# original media_codecs/hwservice_contexts content, so we only remove the files
# we added and leave the (idempotent) config edits in place.
#
# If you need a clean /vendor, reflash the stock vendor image.

if mount -o rw,remount /vendor 2>/dev/null; then
  rm -f /vendor/bin/hw/vendor.dolby.hardware.dms@2.0-service
  rm -f /vendor/bin/hw/vendor.dolby.media.c2@1.0-service
  rm -f /vendor/lib64/libcodec2_soft_ddpdec.so
  rm -f /vendor/lib64/libcodec2_soft_ac4dec.so
  rm -f /vendor/lib64/libcodec2_soft_dolby.so
  rm -f /vendor/lib64/libcodec2_store_dolby.so
  rm -f /vendor/lib64/libdeccfg.so
  rm -f /vendor/lib64/libdapparamstorage.so
  rm -f /vendor/lib64/libdlbdsservice.so
  rm -f /vendor/lib64/vendor.dolby.hardware.dms@2.0.so
  rm -f /vendor/lib64/vendor.dolby.hardware.dms@2.0-impl.so
  rm -f /vendor/etc/media_codecs_dolby_audio.xml
  rm -f /vendor/etc/vintf/manifest/vendor.dolby.media.c2@1.0-service.xml
  rm -f /vendor/etc/vintf/manifest/vendor.dolby.hardware.dms@2.0-service.xml
  rm -f /vendor/etc/init/vendor.dolby.media.c2@1.0-service.rc
  rm -f /vendor/etc/init/vendor.dolby.hardware.dms@2.0-service.rc
  rm -rf /vendor/etc/dolby
  mount -o ro,remount /vendor 2>/dev/null
fi
