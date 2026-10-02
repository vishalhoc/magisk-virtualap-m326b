#!/system/bin/sh
# VirtualAP M326B - Downstream Network ADB & Root Controller Helper
# Manages persistent TCP/IP ADB, static interface IPs, and iptables firewall rules

CONF_FILE="/data/local/virtualap/adb_debug.conf"
LOG_FILE="/data/local/virtualap/logs/adb_debug.log"
BUSYBOX="/data/adb/magisk/busybox"
[ -x "$BUSYBOX" ] || BUSYBOX="busybox"

load_config() {
    CFG_ADB_ENABLED="1"
    CFG_ADB_PORT="5555"
    CFG_ADB_STATIC_IPS="1"
    CFG_ADB_AUTO_AUTH="1"
    CFG_AP0_STATIC_IP="192.168.42.1"
    CFG_USB_STATIC_IP="192.168.44.1"
    CFG_ETH_STATIC_IP="192.168.45.1"
    CFG_HOTSPOT_STATIC_IP="192.168.43.1"
    [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null
}

save_config() {
    mkdir -p /data/local/virtualap
    cat <<EOF > "$CONF_FILE"
CFG_ADB_ENABLED="${CFG_ADB_ENABLED:-1}"
CFG_ADB_PORT="${CFG_ADB_PORT:-5555}"
CFG_ADB_STATIC_IPS="${CFG_ADB_STATIC_IPS:-1}"
CFG_ADB_AUTO_AUTH="${CFG_ADB_AUTO_AUTH:-1}"
CFG_AP0_STATIC_IP="${CFG_AP0_STATIC_IP:-192.168.42.1}"
CFG_USB_STATIC_IP="${CFG_USB_STATIC_IP:-192.168.44.1}"
CFG_ETH_STATIC_IP="${CFG_ETH_STATIC_IP:-192.168.45.1}"
CFG_HOTSPOT_STATIC_IP="${CFG_HOTSPOT_STATIC_IP:-192.168.43.1}"
EOF
}

apply_firewall() {
    PORT="${1:-5555}"
    # Unblock INPUT chains for ADB TCP port across all interfaces
    iptables -w 2 -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -w 2 -C tetherctrl_INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I tetherctrl_INPUT 1 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    ip6tables -w 2 -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        ip6tables -w 2 -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

remove_firewall() {
    PORT="${1:-5555}"
    iptables -w 2 -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -w 2 -D tetherctrl_INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    ip6tables -w 2 -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

apply_auto_auth() {
    # Ensure permissive network ADB debugging without RSA pairing roadblocks
    CUR_SEC=$(getprop ro.adb.secure)
    CUR_DBG=$(getprop ro.debuggable)
    if [ "$CUR_SEC" != "0" ] || [ "$CUR_DBG" != "1" ]; then
        if command -v resetprop >/dev/null 2>&1; then
            resetprop ro.adb.secure 0 2>/dev/null || true
            resetprop ro.debuggable 1 2>/dev/null || true
        elif [ -x /data/adb/magisk/magisk ]; then
            /data/adb/magisk/magisk resetprop ro.adb.secure 0 2>/dev/null || true
            /data/adb/magisk/magisk resetprop ro.debuggable 1 2>/dev/null || true
        fi
    fi
    setprop persist.adb.nonblocking_ffs 0 2>/dev/null || true
    # NOTE: Never enable 'adb_wifi_enabled'. AOSP Wireless Debugging requires Wi-Fi client
    # mode and causes Wi-Fi/AP disassociation loops on MT6853 when flipped in AP mode.

    # Backup and ensure /data/misc/adb/adb_keys permissions
    if [ -f /data/misc/adb/adb_keys ]; then
        mkdir -p /data/local/virtualap
        cp -f /data/misc/adb/adb_keys /data/local/virtualap/adb_keys 2>/dev/null || true
        chmod 0640 /data/misc/adb/adb_keys 2>/dev/null || true
        chown system:shell /data/misc/adb/adb_keys 2>/dev/null || true
    elif [ -f /data/local/virtualap/adb_keys ]; then
        mkdir -p /data/misc/adb
        cp -f /data/local/virtualap/adb_keys /data/misc/adb/adb_keys 2>/dev/null || true
        chmod 0640 /data/misc/adb/adb_keys 2>/dev/null || true
        chown system:shell /data/misc/adb/adb_keys 2>/dev/null || true
    fi
}

maintain_downstream_ips() {
    load_config
    [ "$CFG_ADB_STATIC_IPS" = "1" ] || return 0

    # 1. VirtualAP hardware ap0 (managed by start-ap; only assign if ap0 is up and completely unassigned)
    if [ -d "/sys/class/net/ap0" ] && ! pgrep -f "hostapd" >/dev/null 2>&1; then
        AP_IP="${CFG_AP0_STATIC_IP:-192.168.42.1}"
        if ! /system/bin/ip -4 addr show dev ap0 2>/dev/null | grep -q "$AP_IP"; then
            /system/bin/ip addr add "$AP_IP/24" dev ap0 2>/dev/null || true
        fi
    fi

    # 2. USB Tethering (rndis0, usb0, ncm0)
    for udev in rndis0 usb0 ncm0; do
        if [ -d "/sys/class/net/$udev" ]; then
            if /system/bin/ip link show "$udev" 2>/dev/null | grep -q "UP"; then
                USB_IP="${CFG_USB_STATIC_IP:-192.168.44.1}"
                if ! /system/bin/ip -4 addr show dev "$udev" 2>/dev/null | grep -q "$USB_IP"; then
                    /system/bin/ip addr add "$USB_IP/24" dev "$udev" 2>/dev/null || true
                fi
            fi
        fi
    done

    # 3. Ethernet Tethering (eth0, eth1, etc.)
    for edev in /sys/class/net/eth* /sys/class/net/usb*; do
        [ ! -d "$edev" ] && continue
        ename="${edev##*/}"
        if /system/bin/ip link show "$ename" 2>/dev/null | grep -q "UP"; then
            ETH_IP="${CFG_ETH_STATIC_IP:-192.168.45.1}"
            if ! /system/bin/ip -4 addr show dev "$ename" 2>/dev/null | grep -q "$ETH_IP"; then
                /system/bin/ip addr add "$ETH_IP/24" dev "$ename" 2>/dev/null || true
            fi
        fi
    done
}

start_adb() {
    load_config
    PORT="${1:-${CFG_ADB_PORT:-5555}}"
    CFG_ADB_ENABLED="1"
    CFG_ADB_PORT="$PORT"
    save_config

    settings put global adb_enabled 1 2>/dev/null || true
    setprop service.adb.tcp.port "$PORT"

    if [ "$CFG_ADB_AUTO_AUTH" = "1" ]; then
        apply_auto_auth
    fi

    apply_firewall "$PORT"
    maintain_downstream_ips

    # Restart adbd if not currently listening on this port
    if ! $BUSYBOX netstat -tlpn 2>/dev/null | grep -qE "(:|:::)$PORT.*adbd"; then
        setprop ctl.restart adbd 2>/dev/null || true
    fi
}

stop_adb() {
    load_config
    CFG_ADB_ENABLED="0"
    save_config

    remove_firewall "${CFG_ADB_PORT:-5555}"
    setprop service.adb.tcp.port ""
    setprop ctl.restart adbd 2>/dev/null || true
}

maintain() {
    load_config
    [ "$CFG_ADB_ENABLED" = "1" ] || return 0
    PORT="${CFG_ADB_PORT:-5555}"

    # Only touch properties or restart adbd if it is NOT currently configured or listening
    CUR_PORT=$(getprop service.adb.tcp.port)
    if [ "$CUR_PORT" != "$PORT" ]; then
        setprop service.adb.tcp.port "$PORT"
        setprop ctl.restart adbd 2>/dev/null || true
    fi

    # Verify listener is active; only trigger restart if adbd dropped the port
    if ! $BUSYBOX netstat -tlpn 2>/dev/null | grep -qE "(:|:::)$PORT.*adbd"; then
        setprop service.adb.tcp.port "$PORT"
        setprop ctl.restart adbd 2>/dev/null || true
    fi

    # Ensure firewall rule is present (lightweight check)
    apply_firewall "$PORT"
}

get_status_json() {
    load_config
    PORT="${CFG_ADB_PORT:-5555}"
    ENABLED=$([ "$CFG_ADB_ENABLED" = "1" ] && echo "true" || echo "false")
    STATIC_IPS=$([ "$CFG_ADB_STATIC_IPS" = "1" ] && echo "true" || echo "false")
    AUTO_AUTH=$([ "$CFG_ADB_AUTO_AUTH" = "1" ] && echo "true" || echo "false")

    LISTENING="false"
    ADBD_PID=""
    NLINES=$($BUSYBOX netstat -tlpn 2>/dev/null | grep -E "(:|:::)$PORT.*adbd" | head -n1)
    if [ -n "$NLINES" ]; then
        LISTENING="true"
        ADBD_PID=$(echo "$NLINES" | awk '{print $NF}' | cut -d/ -f1)
    fi

    SECURE_VAL=$(getprop ro.adb.secure)
    SECURE=$([ "$SECURE_VAL" = "0" ] && echo "false" || echo "true")
    DEBUGGABLE_VAL=$(getprop ro.debuggable)
    DEBUGGABLE=$([ "$DEBUGGABLE_VAL" = "1" ] && echo "true" || echo "false")

    # Inspect downstream interface states and live IPs
    # 1. Virtual AP (ap0)
    AP0_STATE="DOWN"
    AP0_IP="${CFG_AP0_STATIC_IP:-192.168.42.1}"
    if [ -d "/sys/class/net/ap0" ]; then
        /system/bin/ip link show ap0 2>/dev/null | grep -q "UP" && AP0_STATE="UP"
        CUR_IP=$(/system/bin/ip -4 -o addr show dev ap0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
        [ -n "$CUR_IP" ] && AP0_IP="$CUR_IP"
    fi

    # 2. USB Tethering
    USB_DEV="rndis0"
    USB_STATE="DOWN"
    USB_IP="${CFG_USB_STATIC_IP:-192.168.44.1}"
    for u in rndis0 usb0 ncm0; do
        if [ -d "/sys/class/net/$u" ]; then
            USB_DEV="$u"
            /system/bin/ip link show "$u" 2>/dev/null | grep -q "UP" && USB_STATE="UP"
            CUR_IP=$(/system/bin/ip -4 -o addr show dev "$u" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            [ -n "$CUR_IP" ] && USB_IP="$CUR_IP"
            break
        fi
    done

    # 3. Ethernet Tethering
    ETH_DEV="eth0"
    ETH_STATE="DOWN"
    ETH_IP="${CFG_ETH_STATIC_IP:-192.168.45.1}"
    for e in /sys/class/net/eth* /sys/class/net/usb*; do
        [ ! -d "$e" ] && continue
        ETH_DEV="${e##*/}"
        /system/bin/ip link show "$ETH_DEV" 2>/dev/null | grep -q "UP" && ETH_STATE="UP"
        CUR_IP=$(/system/bin/ip -4 -o addr show dev "$ETH_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
        [ -n "$CUR_IP" ] && ETH_IP="$CUR_IP"
        break
    done

    # 4. Standard Hotspot / Wi-Fi
    HS_DEV="wlan0"
    HS_STATE="DOWN"
    HS_IP="${CFG_HOTSPOT_STATIC_IP:-192.168.43.1}"
    for w in swlan0 wlan0; do
        if [ -d "/sys/class/net/$w" ]; then
            HS_DEV="$w"
            /system/bin/ip link show "$w" 2>/dev/null | grep -q "UP" && HS_STATE="UP"
            CUR_IP=$(/system/bin/ip -4 -o addr show dev "$w" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            [ -n "$CUR_IP" ] && HS_IP="$CUR_IP"
            break
        fi
    done

    cat <<EOF
{
    "success": true,
    "enabled": $ENABLED,
    "port": $PORT,
    "listening": $LISTENING,
    "adbd_pid": "${ADBD_PID:-dead}",
    "secure": $SECURE,
    "debuggable": $DEBUGGABLE,
    "static_ips": $STATIC_IPS,
    "auto_auth": $AUTO_AUTH,
    "endpoints": [
        {
            "name": "Virtual AP (ap0)",
            "iface": "ap0",
            "ip": "$AP0_IP",
            "port": $PORT,
            "state": "$AP0_STATE",
            "connect_cmd": "adb connect $AP0_IP:$PORT"
        },
        {
            "name": "USB Tethering ($USB_DEV)",
            "iface": "$USB_DEV",
            "ip": "$USB_IP",
            "port": $PORT,
            "state": "$USB_STATE",
            "connect_cmd": "adb connect $USB_IP:$PORT"
        },
        {
            "name": "USB Ethernet ($ETH_DEV)",
            "iface": "$ETH_DEV",
            "ip": "$ETH_IP",
            "port": $PORT,
            "state": "$ETH_STATE",
            "connect_cmd": "adb connect $ETH_IP:$PORT"
        },
        {
            "name": "Wi-Fi Hotspot ($HS_DEV)",
            "iface": "$HS_DEV",
            "ip": "$HS_IP",
            "port": $PORT,
            "state": "$HS_STATE",
            "connect_cmd": "adb connect $HS_IP:$PORT"
        }
    ]
}
EOF
}

case "$1" in
    start) start_adb "$2" ;;
    stop) stop_adb ;;
    restart)
        load_config
        setprop ctl.restart adbd 2>/dev/null || true
        apply_firewall "${CFG_ADB_PORT:-5555}"
        echo '{"success": true, "message": "ADB daemon restarted"}'
        ;;
    maintain) maintain ;;
    status) get_status_json ;;
    test)
        load_config
        PORT="${CFG_ADB_PORT:-5555}"
        if $BUSYBOX nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
            echo "{\"success\": true, \"reachable\": true, \"port\": $PORT, \"message\": \"Port $PORT is reachable locally\"}"
        else
            echo "{\"success\": false, \"reachable\": false, \"port\": $PORT, \"message\": \"Port $PORT refused connection\"}"
        fi
        ;;
    *) maintain ;;
esac
