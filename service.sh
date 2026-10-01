#!/system/bin/sh
# VirtualAP M326B Fix - Service Daemon
# Keeps MediaTek Wi-Fi chip awake and maintains ap0 interface across reboots
# NO changes to com.virtualap.app files or scripts

MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/virtualap_m326b_fix"

# Launch persistent background daemon
(
    # Wait for Android framework to report boot completion
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 2
    done

    # Setup directories
    mkdir -p /data/local/virtualap/bin /data/local/virtualap/logs /data/local/virtualap/run /data/local/virtualap/web/cgi-bin

    # 1. Install patched hostapd
    if [ -f "$MODDIR/files/hostapd_patched" ]; then
        cp -f "$MODDIR/files/hostapd_patched" /data/local/virtualap/bin/hostapd 2>/dev/null
        chmod 755 /data/local/virtualap/bin/hostapd 2>/dev/null
        chown 0:0 /data/local/virtualap/bin/hostapd 2>/dev/null
    fi

    # 2. Install iw wrapper and iw.real
    if [ -f "$MODDIR/files/iw.real" ]; then
        cp -f "$MODDIR/files/iw.real" /data/local/virtualap/bin/iw.real 2>/dev/null
        chmod 755 /data/local/virtualap/bin/iw.real 2>/dev/null
        chown 0:0 /data/local/virtualap/bin/iw.real 2>/dev/null
    fi
    if [ -f "$MODDIR/files/iw" ]; then
        cp -f "$MODDIR/files/iw" /data/local/virtualap/bin/iw 2>/dev/null
        chmod 755 /data/local/virtualap/bin/iw 2>/dev/null
        chown 0:0 /data/local/virtualap/bin/iw 2>/dev/null
    fi

    # 3. Maintain start-ap script in /data/local/virtualap
    if [ -f "$MODDIR/files/start-ap" ]; then
        cp -f "$MODDIR/files/start-ap" /data/local/virtualap/start-ap 2>/dev/null
        chmod 755 /data/local/virtualap/start-ap 2>/dev/null
        cp -f "$MODDIR/files/start-ap" /data/local/tmp/start-ap 2>/dev/null
        chmod 755 /data/local/tmp/start-ap 2>/dev/null
    fi

    # 4. Setup WebUI
    if [ -d "$MODDIR/web" ]; then
        cp -rf "$MODDIR/web/"* /data/local/virtualap/web/ 2>/dev/null
        chmod 755 /data/local/virtualap/web/cgi-bin/* 2>/dev/null
    fi

    # Start WebUI HTTP daemon on port 8088 if not running
    if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
        /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null
    fi

    # Function to maintain MTK Wi-Fi driver power and ap0 presence
    maintain_ap0() {
        # Check if Native Mode is active (module modifications completely disabled)
        if [ -f "/data/local/virtualap/native_mode.flag" ]; then
            # Keep WebUI alive so user can toggle back or configure settings
            if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
                /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null
            fi
            return 0
        fi

        # Keep MTK Wi-Fi driver powered on without enabling Android Wi-Fi / Hotspot
        if [ -e /dev/wmtWifi ]; then
            echo 1 > /dev/wmtWifi 2>/dev/null
        fi

        # Pre-create ap0 if missing
        if [ ! -d "/sys/class/net/ap0" ]; then
            sleep 0.3
            if [ -x "/data/local/virtualap/bin/iw.real" ]; then
                /data/local/virtualap/bin/iw.real dev wlan0 interface add ap0 type __ap 2>/dev/null || true
            fi
        fi

        # Ensure binaries exist in /data/local/virtualap/bin
        if [ ! -f "/data/local/virtualap/bin/iw" ] && [ -f "$MODDIR/files/iw" ]; then
            cp -f "$MODDIR/files/iw" /data/local/virtualap/bin/iw 2>/dev/null
            chmod 755 /data/local/virtualap/bin/iw 2>/dev/null
        fi
        if [ ! -f "/data/local/virtualap/bin/iw.real" ] && [ -f "$MODDIR/files/iw.real" ]; then
            cp -f "$MODDIR/files/iw.real" /data/local/virtualap/bin/iw.real 2>/dev/null
            chmod 755 /data/local/virtualap/bin/iw.real 2>/dev/null
        fi
        if [ ! -f "/data/local/virtualap/bin/hostapd" ] && [ -f "$MODDIR/files/hostapd_patched" ]; then
            cp -f "$MODDIR/files/hostapd_patched" /data/local/virtualap/bin/hostapd 2>/dev/null
            chmod 755 /data/local/virtualap/bin/hostapd 2>/dev/null
        fi

        # Ensure WebUI is alive
        if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
            /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null
        fi
    }

    # Initial wake and setup
    maintain_ap0

    # Background loop to keep chip awake and ap0 interface intact
    while true; do
        sleep 10
        maintain_ap0
    done
) >/dev/null 2>&1 &
