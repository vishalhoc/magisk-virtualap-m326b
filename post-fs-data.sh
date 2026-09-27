#!/system/bin/sh
# Early post-fs-data initialization for VirtualAP
MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/virtualap_m326b_fix"

mkdir -p /data/local/virtualap/bin /data/local/virtualap/logs /data/local/virtualap/run
if [ -f "$MODDIR/files/hostapd_patched" ]; then
    cp -f "$MODDIR/files/hostapd_patched" /data/local/virtualap/bin/hostapd 2>/dev/null
    chmod 755 /data/local/virtualap/bin/hostapd 2>/dev/null
    chown 0:0 /data/local/virtualap/bin/hostapd 2>/dev/null
fi

if [ -f "$MODDIR/files/start-ap" ]; then
    cp -f "$MODDIR/files/start-ap" /data/local/virtualap/start-ap 2>/dev/null
    chmod 755 /data/local/virtualap/start-ap 2>/dev/null
    cp -f "$MODDIR/files/start-ap" /data/local/tmp/start-ap 2>/dev/null
    chmod 755 /data/local/tmp/start-ap 2>/dev/null
fi
