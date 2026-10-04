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

    # 5. Install ADB Helper
    if [ -f "$MODDIR/files/adb_helper.sh" ]; then
        cp -f "$MODDIR/files/adb_helper.sh" /data/local/virtualap/bin/adb_helper.sh 2>/dev/null
        chmod 755 /data/local/virtualap/bin/adb_helper.sh 2>/dev/null
        chown 0:0 /data/local/virtualap/bin/adb_helper.sh 2>/dev/null
    fi

    # Start WebUI HTTP daemon on port 8088 if not running
    if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
        /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null
    fi

    # 6. Apply saved carrier bypass and kernel settings on boot
    if [ -f "/data/local/virtualap/settings.conf" ]; then
        . "/data/local/virtualap/settings.conf" 2>/dev/null
        if [ "$CFG_DUN_BYPASS" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            settings put global tether_dun_required 0 2>/dev/null
            settings put global tether_dun_apn "" 2>/dev/null
            settings put global tether_entitlement_check_state 0 2>/dev/null
        fi
        if [ "$CFG_TTL_BYPASS" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            TTL_VAL="${CFG_TARGET_TTL:-64}"
            sysctl -w net.ipv4.ip_default_ttl="$TTL_VAL" 2>/dev/null || true
            sysctl -w net.ipv6.conf.all.hop_limit="$TTL_VAL" 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -D POSTROUTING -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -I POSTROUTING 1 -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
        fi
        if [ "$CFG_MSS_CLAMP" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            /system/bin/iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi
        if [ "$CFG_DNS_PROTECT" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
        fi
        if [ "$CFG_IPV6_PROTECT" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            /system/bin/ip6tables -w 5 -D FORWARD -j DROP 2>/dev/null || true
            /system/bin/ip6tables -w 5 -I FORWARD 1 -j DROP 2>/dev/null || true
        fi
        if [ "$CFG_BPF_OFFLOAD_DISABLED" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            settings put global tether_offload_disabled 1 2>/dev/null
        fi
        if [ "$CFG_PROVISIONING_SHIELD" = "1" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            setprop net.tethering.noprovisioning true 2>/dev/null
            setprop persist.sys.tether.noprovisioning true 2>/dev/null
        fi
        if [ "$CFG_PURE_PASSTHROUGH" = "1" ]; then
            /system/bin/iptables -w 5 -N PURE_FORWARD 2>/dev/null || /system/bin/iptables -w 5 -F PURE_FORWARD
            /system/bin/iptables -w 5 -A PURE_FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i ap0 -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i rndis+ -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i usb+ -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i eth+ -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i swlan+ -j ACCEPT
            /system/bin/iptables -w 5 -A PURE_FORWARD -i wlan+ -j ACCEPT
            /system/bin/iptables -w 5 -D FORWARD -j PURE_FORWARD 2>/dev/null || true
            /system/bin/iptables -w 5 -I FORWARD 1 -j PURE_FORWARD 2>/dev/null || true

            /system/bin/iptables -w 5 -t nat -N PURE_NAT 2>/dev/null || /system/bin/iptables -w 5 -t nat -F PURE_NAT
            /system/bin/iptables -w 5 -t nat -A PURE_NAT -o rmnet+ -j MASQUERADE
            /system/bin/iptables -w 5 -t nat -A PURE_NAT -o v4-rmnet+ -j MASQUERADE
            /system/bin/iptables -w 5 -t nat -A PURE_NAT -o ccmni+ -j MASQUERADE
            /system/bin/iptables -w 5 -t nat -A PURE_NAT -o pdp+ -j MASQUERADE
            /system/bin/iptables -w 5 -t nat -D POSTROUTING -j PURE_NAT 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -I POSTROUTING 1 -j PURE_NAT 2>/dev/null || true

            /system/bin/ip6tables -w 5 -N PURE_FORWARD_V6 2>/dev/null || /system/bin/ip6tables -w 5 -F PURE_FORWARD_V6
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -m state --state ESTABLISHED,RELATED -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i ap0 -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i rndis+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i usb+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i eth+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i swlan+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A PURE_FORWARD_V6 -i wlan+ -j ACCEPT
            /system/bin/ip6tables -w 5 -D FORWARD -j PURE_FORWARD_V6 2>/dev/null || true
            /system/bin/ip6tables -w 5 -I FORWARD 1 -j PURE_FORWARD_V6 2>/dev/null || true

            /system/bin/iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
            sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
            sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
            sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
            sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
            sysctl -w net.core.netdev_max_backlog=10000 2>/dev/null || true
            sysctl -w net.core.somaxconn=4096 2>/dev/null || true
        fi
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

        # If hostapd is running, ap0 is active and transmitting.
        # DO NOT write to /dev/wmtWifi or touch interface names while hostapd is active,
        # as poking the MTK driver causes radio glitches and client disassociations.
        if ! pgrep -f "hostapd" >/dev/null 2>&1; then
            # Keep MTK Wi-Fi driver powered on without enabling Android Wi-Fi / Hotspot
            if [ -e /dev/wmtWifi ]; then
                echo 1 > /dev/wmtWifi 2>/dev/null
            fi

            # Pre-create / rename ap0 if missing
            if [ ! -d "/sys/class/net/ap0" ]; then
                if [ -d "/sys/class/net/swlan0" ]; then
                    ip link set swlan0 down 2>/dev/null
                    ip link set swlan0 name ap0 2>/dev/null
                elif [ -x "/data/local/virtualap/bin/iw.real" ]; then
                    /data/local/virtualap/bin/iw.real dev wlan0 interface add ap0 type __ap 2>/dev/null || true
                    if [ -d "/sys/class/net/swlan0" ]; then
                        ip link set swlan0 down 2>/dev/null
                        ip link set swlan0 name ap0 2>/dev/null
                    fi
                fi
            fi
        fi

        # Ensure binaries exist and are updated in /data/local/virtualap/bin
        if [ -f "$MODDIR/files/iw" ]; then
            cp -f "$MODDIR/files/iw" /data/local/virtualap/bin/iw 2>/dev/null
            chmod 755 /data/local/virtualap/bin/iw 2>/dev/null
        fi
        if [ ! -f "/data/local/virtualap/bin/iw.real" ] && [ -f "$MODDIR/files/iw.real" ]; then
            cp -f "$MODDIR/files/iw.real" /data/local/virtualap/bin/iw.real 2>/dev/null
            chmod 755 /data/local/virtualap/bin/iw.real 2>/dev/null
        fi
        if [ -f "$MODDIR/files/hostapd_patched" ]; then
            if [ ! -f "/data/local/virtualap/bin/hostapd" ] || ! cmp -s "$MODDIR/files/hostapd_patched" "/data/local/virtualap/bin/hostapd"; then
                cp -f "$MODDIR/files/hostapd_patched" /data/local/virtualap/bin/hostapd 2>/dev/null
                chmod 755 /data/local/virtualap/bin/hostapd 2>/dev/null
            fi
        fi

        # Ensure WebUI is alive
        if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
            /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web 2>/dev/null
        fi
        # Maintain Dedicated Router Mode (prevent cellular WAN drops without breaking user toggles)
        if [ -f "/data/local/virtualap/dedicated_router.flag" ]; then
            settings put global mobile_data_always_on 1 2>/dev/null || true

            # Periodic 60s cellular WAN keepalive (only if WAN interface is alive)
            KEEPALIVE_CNT=${KEEPALIVE_CNT:-0}
            KEEPALIVE_CNT=$((KEEPALIVE_CNT + 1))
            if [ $KEEPALIVE_CNT -ge 4 ]; then
                KEEPALIVE_CNT=0
                WAN_IF=$(ip -4 -o addr show 2>/dev/null | grep -E "v4-rmnet|rmnet" | awk '{print $2}' | head -n1)
                if [ -n "$WAN_IF" ]; then
                    ping -c 1 -W 2 -I "$WAN_IF" 1.1.1.1 >/dev/null 2>&1 || true
                fi
            fi
        fi

        # Maintain Dynamic Upstream Routing for Virtual AP (ap0) and Samsung SoftAP (swlan0)
        # Prevents internet from dying on connected devices when cellular re-indexes (e.g. v4-rmnet0 <-> v4-rmnet10)
        ACTIVE_WAN_TBL=$(ip route show table all 2>/dev/null | grep -E '^default.*dev v4-rmnet' | sed -n 's/.*table \([^ ]*\).*/\1/p' | head -n1)
        [ -z "$ACTIVE_WAN_TBL" ] && ACTIVE_WAN_TBL=$(ip route show table all 2>/dev/null | grep -E '^default.*dev rmnet' | sed -n 's/.*table \([^ ]*\).*/\1/p' | head -n1)
        [ -z "$ACTIVE_WAN_TBL" ] && ACTIVE_WAN_TBL=$(ip route show table all 2>/dev/null | grep -E '^default.*dev wlan' | sed -n 's/.*table \([^ ]*\).*/\1/p' | head -n1)

        if [ -n "$ACTIVE_WAN_TBL" ]; then
            # 1. Virtual AP (ap0) Steering
            if [ -d "/sys/class/net/ap0" ] && pgrep -f "hostapd" >/dev/null 2>&1; then
                CUR_AP_TBL=$(ip rule show 2>/dev/null | grep -E "7010:.*iif ap0" | awk '{print $NF}' | head -n1)
                if [ "$CUR_AP_TBL" != "$ACTIVE_WAN_TBL" ]; then
                    ip rule del pref 7010 2>/dev/null || true
                    ip rule add from all iif ap0 lookup "$ACTIVE_WAN_TBL" pref 7010 2>/dev/null || true
                fi

                # Guarantee NAT MASQUERADE and forwarding rules survive network transitions
                iptables -t nat -C POSTROUTING -s 192.168.42.0/24 ! -d 192.168.42.0/24 -j MASQUERADE 2>/dev/null || \
                    iptables -t nat -I POSTROUTING 1 -s 192.168.42.0/24 ! -d 192.168.42.0/24 -j MASQUERADE 2>/dev/null || true
                iptables -C FORWARD -i ap0 -j ACCEPT 2>/dev/null || \
                    iptables -I FORWARD 1 -i ap0 -j ACCEPT 2>/dev/null || true
                iptables -C FORWARD -o ap0 -j ACCEPT 2>/dev/null || \
                    iptables -I FORWARD 1 -o ap0 -j ACCEPT 2>/dev/null || true
            fi

            # 2. Samsung Mobile Hotspot (swlan0) Steering
            if [ -d "/sys/class/net/swlan0" ] && ip link show swlan0 2>/dev/null | grep -q "state UP"; then
                CUR_SWLAN_TBL=$(ip rule show 2>/dev/null | grep -E "7011:.*iif swlan0" | awk '{print $NF}' | head -n1)
                if [ "$CUR_SWLAN_TBL" != "$ACTIVE_WAN_TBL" ]; then
                    ip rule del pref 7011 2>/dev/null || true
                    ip rule add from all iif swlan0 lookup "$ACTIVE_WAN_TBL" pref 7011 2>/dev/null || true
                fi

                SW_SUBNET=$(ip -4 -o addr show dev swlan0 2>/dev/null | awk '{print $4}')
                if [ -n "$SW_SUBNET" ]; then
                    ip route add "$SW_SUBNET" dev swlan0 scope link table main 2>/dev/null || true
                    ip route add "$SW_SUBNET" dev swlan0 scope link table 97 2>/dev/null || true
                    iptables -t nat -C POSTROUTING -s "$SW_SUBNET" ! -d "$SW_SUBNET" -j MASQUERADE 2>/dev/null || \
                        iptables -t nat -I POSTROUTING 1 -s "$SW_SUBNET" ! -d "$SW_SUBNET" -j MASQUERADE 2>/dev/null || true
                    ip rule show 2>/dev/null | grep -q "7000:.*to $SW_SUBNET" || \
                        ip rule add from all to "$SW_SUBNET" lookup main pref 7000 2>/dev/null || true
                fi
                iptables -C FORWARD -i swlan0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i swlan0 -j ACCEPT 2>/dev/null || true
                iptables -C FORWARD -o swlan0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o swlan0 -j ACCEPT 2>/dev/null || true
            fi
        fi

        # Maintain Pure Direct Modem Passthrough (guarantee top position in FORWARD and POSTROUTING)
        if [ -f "/data/local/virtualap/settings.conf" ]; then
            if grep -q 'CFG_PURE_PASSTHROUGH="1"' /data/local/virtualap/settings.conf 2>/dev/null; then
                if ! iptables -C FORWARD -j PURE_FORWARD 2>/dev/null; then
                    iptables -w 2 -I FORWARD 1 -j PURE_FORWARD 2>/dev/null || true
                fi
                if ! iptables -t nat -C POSTROUTING -j PURE_NAT 2>/dev/null; then
                    iptables -w 2 -t nat -I POSTROUTING 1 -j PURE_NAT 2>/dev/null || true
                fi
            fi
        fi

        # Maintain Downstream Network ADB Debugging (all tethering modes)
        if [ -x "/data/local/virtualap/bin/adb_helper.sh" ]; then
            /data/local/virtualap/bin/adb_helper.sh maintain >/dev/null 2>&1 || true
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
