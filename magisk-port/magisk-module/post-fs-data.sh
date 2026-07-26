#!/system/bin/sh
# post-fs-data: create the DMS parameter storage dir with the right owner/label
# before the daemons need it. Runs in both modes.
MODDIR=${0%/*}

mkdir -p /data/vendor/dolby
chown media:media /data/vendor/dolby 2>/dev/null
chmod 0770 /data/vendor/dolby 2>/dev/null
chcon u:object_r:vendor_data_file:s0 /data/vendor/dolby 2>/dev/null

# also used by some DMS builds
mkdir -p /data/vendor/multimedia
chown system:system /data/vendor/multimedia 2>/dev/null
chmod 0775 /data/vendor/multimedia 2>/dev/null
