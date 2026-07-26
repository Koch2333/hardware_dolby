#!/system/bin/sh
# Runs late-ish (after `class_start core`, roughly at boot-completed).
#
# DIRECT mode: the daemons are already defined by the .rc files we wrote into
#   /vendor/etc/init and init has launched them normally — this script only
#   verifies and, if needed, kicks them.
# OVERLAY mode: init never saw the .rc, so we launch the daemons here by hand.
#   This is best-effort: domain transition and hwservice labelling may be wrong,
#   which is exactly why DIRECT mode exists.

MODDIR=${0%/*}
LOG=/data/local/tmp/dolby_codec_port.log
exec 3>>"$LOG"; echo "=== service.sh $(date 2>/dev/null) ===" >&3

wait_for() { # $1 = getprop key, $2 = expected, $3 = tries
  local i=0
  while [ "$(getprop "$1")" != "$2" ]; do
    i=$((i+1)); [ "$i" -ge "${3:-60}" ] && return 1; sleep 1
  done
}

# Wait until hwservicemanager and the property service are up.
wait_for hwservicemanager.ready true 60 || wait_for init.svc.hwservicemanager running 60

is_running() { pgrep -f "$1" >/dev/null 2>&1; }

DMS_BIN=/vendor/bin/hw/vendor.dolby.hardware.dms@2.0-service
C2_BIN=/vendor/bin/hw/vendor.dolby.media.c2@1.0-service

if [ -f "$MODDIR/disable_overlay" ]; then
  # DIRECT mode. init owns the services; just report.
  sleep 5
  is_running "$DMS_BIN" && echo "DMS running" >&3 || echo "DMS NOT running (check init.svc)" >&3
  is_running "$C2_BIN"  && echo "c2 running"  >&3 || echo "c2 NOT running (check init.svc)"  >&3
  exit 0
fi

# OVERLAY mode: hand-launch. Give the overlay time to be mounted.
sleep 8
mkdir -p /data/vendor/dolby
chown media:media /data/vendor/dolby 2>/dev/null
chmod 0770 /data/vendor/dolby 2>/dev/null

# The DMS daemon needs its own SELinux domain; magiskpolicy created hal_dms_default
# (permissive). Launch it in that context. c2 service goes in mediacodec.
if ! is_running "$DMS_BIN"; then
  echo "launching DMS in hal_dms_default" >&3
  /system/bin/runcon u:r:hal_dms_default:s0 "$DMS_BIN" >>"$LOG" 2>&1 &
fi
sleep 2
if ! is_running "$C2_BIN"; then
  echo "launching c2 in mediacodec" >&3
  /system/bin/runcon u:r:mediacodec:s0 "$C2_BIN" >>"$LOG" 2>&1 &
fi

sleep 3
is_running "$DMS_BIN" && echo "DMS up" >&3 || echo "DMS failed — see log" >&3
is_running "$C2_BIN"  && echo "c2 up"  >&3 || echo "c2 failed — see log"  >&3
