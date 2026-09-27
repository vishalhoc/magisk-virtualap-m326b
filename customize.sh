ui_print "***********************************************"
ui_print "*   VirtualAP Fix for Samsung Galaxy M32 5G   *"
ui_print "*       Device: SM-M326B (MT6853 / Dimensity) *"
ui_print "***********************************************"

ui_print "- Creating VirtualAP runtime directories..."
mkdir -p /data/local/virtualap/bin
mkdir -p /data/local/virtualap/logs
mkdir -p /data/local/virtualap/run
mkdir -p /data/local/virtualap/web/cgi-bin

ui_print "- Installing patched hostapd..."
cp -f "$MODPATH/files/hostapd_patched" /data/local/virtualap/bin/hostapd
chmod 755 /data/local/virtualap/bin/hostapd
chown 0:0 /data/local/virtualap/bin/hostapd

ui_print "- Installing iw compatibility layer..."
if [ -f "$MODPATH/files/iw.real" ]; then
    cp -f "$MODPATH/files/iw.real" /data/local/virtualap/bin/iw.real
    chmod 755 /data/local/virtualap/bin/iw.real
    chown 0:0 /data/local/virtualap/bin/iw.real
fi
if [ -f "$MODPATH/files/iw" ]; then
    cp -f "$MODPATH/files/iw" /data/local/virtualap/bin/iw
    chmod 755 /data/local/virtualap/bin/iw
    chown 0:0 /data/local/virtualap/bin/iw
fi

ui_print "- Installing start-ap engine..."
if [ -f "$MODPATH/files/start-ap" ]; then
    cp -f "$MODPATH/files/start-ap" /data/local/virtualap/start-ap
    chmod 755 /data/local/virtualap/start-ap
    cp -f "$MODPATH/files/start-ap" /data/local/tmp/start-ap
    chmod 755 /data/local/tmp/start-ap
fi

ui_print "- Waking MediaTek Wi-Fi chip and preparing ap0..."
if [ -e /dev/wmtWifi ]; then
    echo 1 > /dev/wmtWifi
    sleep 0.5
fi
if [ ! -d "/sys/class/net/ap0" ] && [ -x "/data/local/virtualap/bin/iw.real" ]; then
    /data/local/virtualap/bin/iw.real dev wlan0 interface add ap0 type __ap 2>/dev/null || true
fi

ui_print "- Installing VirtualAP WebUI Control Panel..."
if [ -d "$MODPATH/web" ]; then
    cp -rf "$MODPATH/web/"* /data/local/virtualap/web/
    chmod 755 /data/local/virtualap/web/cgi-bin/*
fi

# Start WebUI immediately
killall -9 httpd 2>/dev/null
/data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null

ui_print "- Setting file permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/files/hostapd_patched" 0 0 0755
set_perm "$MODPATH/files/iw" 0 0 0755
[ -f "$MODPATH/files/iw.real" ] && set_perm "$MODPATH/files/iw.real" 0 0 0755
[ -f "$MODPATH/files/start-ap" ] && set_perm "$MODPATH/files/start-ap" 0 0 0755
set_perm_recursive "$MODPATH/web" 0 0 0755 0644
set_perm "$MODPATH/web/cgi-bin/api.sh" 0 0 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/webroot/cgi-bin/api.sh" 0 0 0755
[ -f "$MODPATH/sepolicy.rule" ] && set_perm "$MODPATH/sepolicy.rule" 0 0 0644

ui_print "- Web Control Panel active at http://localhost:8088"
ui_print "- Done! ap0 fix is permanently active."
