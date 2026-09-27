#!/system/bin/sh
# Late-start service daemon to ensure VirtualAP backend stays patched and WebUI runs across reboots

MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/virtualap_m326b_fix"

# Launch persistent background watcher daemon
(
    # Wait for Android framework to report boot completion
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 2
    done

    # Setup WebUI directory and permissions
    mkdir -p /data/local/virtualap/web/cgi-bin
    if [ -d "$MODDIR/web" ]; then
        cp -rf "$MODDIR/web/"* /data/local/virtualap/web/ 2>/dev/null
    fi
    chmod 755 /data/local/virtualap/web/cgi-bin/* 2>/dev/null

    # Start WebUI HTTP daemon on port 8088 if not already running
    if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
        /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web
    fi

    # Function to apply patched binaries
    apply_fixes() {
        # 1. Ensure hostapd is patched in /data/local/virtualap/bin
        if [ -f "$MODDIR/files/hostapd_patched" ]; then
            mkdir -p /data/local/virtualap/bin /data/local/virtualap/logs /data/local/virtualap/run
            cp -f "$MODDIR/files/hostapd_patched" /data/local/virtualap/bin/hostapd 2>/dev/null
            chmod 755 /data/local/virtualap/bin/hostapd 2>/dev/null
            chown 0:0 /data/local/virtualap/bin/hostapd 2>/dev/null
        fi

        # 2. Ensure start-ap is patched in VirtualAP app backend directory
        if [ -d "/data/data/com.virtualap.app/files/backend" ] && [ -f "$MODDIR/files/start-ap" ]; then
            cp -f "$MODDIR/files/start-ap" /data/data/com.virtualap.app/files/backend/start-ap 2>/dev/null
            APP_UID=$(stat -c %u /data/data/com.virtualap.app/files/backend 2>/dev/null || echo "10301")
            chown "$APP_UID:$APP_UID" /data/data/com.virtualap.app/files/backend/start-ap 2>/dev/null
            chmod 700 /data/data/com.virtualap.app/files/backend/start-ap 2>/dev/null
        fi

        # 3. Maintain redundant copies in /data/local/virtualap and /data/local/tmp
        if [ -f "$MODDIR/files/start-ap" ]; then
            cp -f "$MODDIR/files/start-ap" /data/local/virtualap/start-ap 2>/dev/null
            chmod 755 /data/local/virtualap/start-ap 2>/dev/null
            cp -f "$MODDIR/files/start-ap" /data/local/tmp/start-ap 2>/dev/null
            chmod 755 /data/local/tmp/start-ap 2>/dev/null
        fi

        # 4. Ensure WebUI HTTP daemon remains active
        if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
            /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web
        fi

        # 5. Pre-create ap0 virtual AP interface if Wi-Fi is active and ap0 does not exist
        if [ ! -d "/sys/class/net/ap0" ] && [ -f "/data/local/virtualap/bin/iw" ]; then
            if cmd wifi status 2>/dev/null | grep -qi "enabled"; then
                /data/local/virtualap/bin/iw dev wlan0 interface add ap0 type __ap 2>/dev/null || \
                /data/local/virtualap/bin/iw phy phy0 interface add ap0 type __ap 2>/dev/null || true
            fi
        fi
    }

    # Autostart AP function
    check_autostart() {
        if [ -f "/data/local/virtualap/autostart.conf" ] && grep -q '^AUTOSTART_ENABLED=1' "/data/local/virtualap/autostart.conf"; then
            if ! pgrep -f "hostapd.*ap0" >/dev/null 2>&1 && ! pgrep -f "hostapd.*swlan0" >/dev/null 2>&1; then
                sleep 4
                /data/local/virtualap/start-ap start >/data/local/virtualap/logs/autostart.log 2>&1
            fi
        fi
    }

    # First pass: wait up to 120s for user to unlock device (FBE credential encrypted storage)
    for i in $(seq 1 60); do
        if [ -d "/data/data/com.virtualap.app/files" ] || [ "$(getprop sys.user.0.ce_available)" = "true" ]; then
            apply_fixes
            check_autostart
            break
        fi
        sleep 2
    done

    # Continuous light background watcher (every 15s) so app updates/restarts never revert the fixes
    while true; do
        sleep 15
        apply_fixes
    done
) >/dev/null 2>&1 &
