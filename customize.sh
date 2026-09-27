ui_print "***********************************************"
ui_print "*   VirtualAP Fix for Samsung Galaxy M32 5G   *"
ui_print "*       Device: SM-M326B (MT6853 / Dimensity) *"
ui_print "***********************************************"

ui_print "- Creating VirtualAP runtime directories..."
mkdir -p /data/local/virtualap/bin
mkdir -p /data/local/virtualap/logs
mkdir -p /data/local/virtualap/run
mkdir -p /data/local/virtualap/web/cgi-bin

ui_print "- Installing patched hostapd (AF_INET + SME bypass)..."
cp -f "$MODPATH/files/hostapd_patched" /data/local/virtualap/bin/hostapd
chmod 755 /data/local/virtualap/bin/hostapd
chown 0:0 /data/local/virtualap/bin/hostapd

ui_print "- Installing updated start-ap script..."
cp -f "$MODPATH/files/start-ap" /data/local/virtualap/start-ap
chmod 755 /data/local/virtualap/start-ap
cp -f "$MODPATH/files/start-ap" /data/local/tmp/start-ap
chmod 755 /data/local/tmp/start-ap

if [ -d "/data/data/com.virtualap.app/files/backend" ]; then
    ui_print "- Updating com.virtualap.app backend..."
    cp -f "$MODPATH/files/start-ap" /data/data/com.virtualap.app/files/backend/start-ap
    APP_UID=$(stat -c %u /data/data/com.virtualap.app/files/backend 2>/dev/null || echo "10301")
    chown "$APP_UID:$APP_UID" /data/data/com.virtualap.app/files/backend/start-ap
    chmod 700 /data/data/com.virtualap.app/files/backend/start-ap
fi

ui_print "- Installing VirtualAP WebUI Control Panel..."
if [ -d "$MODPATH/web" ]; then
    cp -rf "$MODPATH/web/"* /data/local/virtualap/web/
    chmod 755 /data/local/virtualap/web/cgi-bin/*
fi

# Start WebUI immediately
killall -9 httpd 2>/dev/null
/data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web

# Install secondary fallback service into service.d
mkdir -p /data/adb/service.d
cp -f "$MODPATH/service.sh" /data/adb/service.d/virtualap_boot_fix.sh
chmod 755 /data/adb/service.d/virtualap_boot_fix.sh
chown 0:0 /data/adb/service.d/virtualap_boot_fix.sh

ui_print "- Setting file permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/files/hostapd_patched" 0 0 0755
set_perm "$MODPATH/files/start-ap" 0 0 0755
set_perm_recursive "$MODPATH/web" 0 0 0755 0644
set_perm "$MODPATH/web/cgi-bin/api.sh" 0 0 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/webroot/cgi-bin/api.sh" 0 0 0755
[ -f "$MODPATH/sepolicy.rule" ] && set_perm "$MODPATH/sepolicy.rule" 0 0 0644

ui_print "- Web Control Panel active at http://localhost:8088"
ui_print "- Done! VirtualAP is ready to use."
