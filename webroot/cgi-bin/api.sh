#!/system/bin/sh
# VirtualAP WebUI CGI Backend API - 4 Tabs: Virtual AP | Hotspot | USB Tethering | Ethernet
printf "Content-Type: application/json\r\n"
printf "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
printf "Pragma: no-cache\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
printf "Access-Control-Allow-Headers: Content-Type\r\n\r\n"

START_AP="/data/local/virtualap/start-ap"
[ ! -f "$START_AP" ] && START_AP="/data/data/com.virtualap.app/files/backend/start-ap"
[ ! -f "$START_AP" ] && START_AP="/data/local/tmp/start-ap"

CONF_FILE="/data/local/virtualap/ap.conf"
APP_PREFS="/data/data/com.virtualap.app/shared_prefs/virtualap_prefs.xml"
AUTOSTART_FILE="/data/local/virtualap/autostart.conf"
STATE_FILE="/data/local/virtualap/run.state"
RUN_DIR="/data/local/virtualap/run"
LOG_DIR="/data/local/virtualap/logs"
SOFTAP_XML="/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml"
[ ! -f "$SOFTAP_XML" ] && SOFTAP_XML="/data/misc/wifi/WifiConfigStoreSoftAp.xml"

# Android SharedPreferences XML helper functions
get_app_pref_str() {
    local key="$1"
    [ -f "$APP_PREFS" ] || return 1
    sed -n 's/.*<string name="'"$key"'">\([^<]*\)<\/string>.*/\1/p' "$APP_PREFS" 2>/dev/null
}

get_app_pref_bool() {
    local key="$1"
    [ -f "$APP_PREFS" ] || return 1
    local v
    v=$(sed -n 's/.*<boolean name="'"$key"'" value="\([^"]*\)".*/\1/p' "$APP_PREFS" 2>/dev/null)
    [ "$v" = "true" ] && echo "1" || echo "0"
}

set_app_pref_str() {
    local key="$1"
    local val="$2"
    [ -f "$APP_PREFS" ] || return 0
    if grep -q "<string name=\"$key\"" "$APP_PREFS" 2>/dev/null; then
        sed -i 's|<string name="'"$key"'">[^<]*</string>|<string name="'"$key"'">'"$val"'</string>|g' "$APP_PREFS" 2>/dev/null
        sed -i 's|<string name="'"$key"'" />|<string name="'"$key"'">'"$val"'</string>|g' "$APP_PREFS" 2>/dev/null
    else
        sed -i 's|</map>|    <string name="'"$key"'">'"$val"'</string>\n</map>|g' "$APP_PREFS" 2>/dev/null
    fi
}

set_app_pref_bool() {
    local key="$1"
    local val="$2"
    [ -f "$APP_PREFS" ] || return 0
    local bval="false"
    [ "$val" = "1" ] || [ "$val" = "true" ] && bval="true"
    if grep -q "<boolean name=\"$key\"" "$APP_PREFS" 2>/dev/null; then
        sed -i 's|<boolean name="'"$key"'" value="[^"]*" />|<boolean name="'"$key"'" value="'"$bval"'" />|g' "$APP_PREFS" 2>/dev/null
    else
        sed -i 's|</map>|    <boolean name="'"$key"'" value="'"$bval"'" />\n</map>|g' "$APP_PREFS" 2>/dev/null
    fi
}

sync_app_prefs_perms() {
    if [ -f "$APP_PREFS" ]; then
        local app_uid
        app_uid=$(stat -c %u "$APP_PREFS" 2>/dev/null || echo "10301")
        chown "$app_uid:$app_uid" "$APP_PREFS" 2>/dev/null
        chmod 660 "$APP_PREFS" 2>/dev/null
    fi
}

# URL decoder
urldecode() {
    printf '%b' "${1//%/\\x}"
}

# Parse query string
ACTION=""
if [ -n "$QUERY_STRING" ]; then
    for param in $(echo "$QUERY_STRING" | tr '&' ' '); do
        key="${param%%=*}"
        val="${param#*=}"
        if [ "$key" = "action" ]; then
            ACTION="$val"
        fi
    done
fi

# Parse POST body if present
POST_DATA=""
if [ "$REQUEST_METHOD" = "POST" ]; then
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
        read -n "$CONTENT_LENGTH" POST_DATA
    fi
fi

# Combine params for action parsing
DATA="${POST_DATA:-$QUERY_STRING}"
get_param() {
    local target="$1"
    local default_val="$2"
    for p in $(echo "$DATA" | tr '&' ' '); do
        local pk="${p%%=*}"
        local pv="${p#*=}"
        if [ "$pk" = "$target" ]; then
            urldecode "$pv"
            return 0
        fi
    done
    echo "$default_val"
}

case "$ACTION" in
    # =========================================================================
    # TAB 1: VIRTUAL AP ENDPOINTS
    # =========================================================================
    status)
        running=0
        hostapd="dead"
        dnsmasq="dead"
        clients=0
        started=""
        upstream_table=""
        upstream_iface=""

        # 1. Read Android App preferences (highest priority for user settings)
        PREF_SSID=$(get_app_pref_str "ap_ssid")
        PREF_PASS=$(get_app_pref_str "ap_password")
        PREF_BAND=$(get_app_pref_str "ap_band")
        PREF_CHAN=$(get_app_pref_str "ap_channel")
        PREF_WIDTH=$(get_app_pref_str "ap_width")
        PREF_GW=$(get_app_pref_str "ap_gateway")
        PREF_DNS=$(get_app_pref_str "ap_dns")
        PREF_UPSTREAM=$(get_app_pref_str "ap_upstream")
        PREF_SEC=$(get_app_pref_str "ap_security")
        PREF_HIDDEN=$(get_app_pref_bool "ap_hidden")
        PREF_PMF=$(get_app_pref_bool "ap_pmf")

        # 2. Next, load saved ap.conf
        if [ -f "$CONF_FILE" ]; then
            . "$CONF_FILE" 2>/dev/null
        fi

        # Sync/reconcile: prefer app preferences if present
        SSID="${PREF_SSID:-${SSID:-hoc}}"
        PASSWORD="${PREF_PASS:-${PASSWORD:-1234567890}}"
        BAND="${PREF_BAND:-${BAND:-5}}"
        CHANNEL="${PREF_CHAN:-${CHANNEL:-}}"
        WIDTH="${PREF_WIDTH:-${WIDTH:-20}}"
        IP_GW="${PREF_GW:-${IP_GW:-192.168.42.1}}"
        DNS_SERVERS="${PREF_DNS:-${DNS_SERVERS:-1.1.1.1}}"
        UPSTREAM="${PREF_UPSTREAM:-${UPSTREAM:-auto}}"
        SECURITY="${PREF_SEC:-${SECURITY:-wpa2}}"
        HIDDEN="${PREF_HIDDEN:-${HIDDEN:-0}}"
        PMF="${PREF_PMF:-${PMF:-0}}"
        PHY_IFACE="${PHY_IFACE:-wlan0}"
        AP_IFACE="${AP_IFACE:-ap0}"

        # 3. Query live status from start-ap engine
        if [ -f "$START_AP" ]; then
            while IFS='=' read -r sk sv; do
                case "$sk" in
                    running|mode|hostapd|dnsmasq|clients|width|security|ssid|band|channel|upstream|upstream_table|upstream_iface|gateway|dns_servers|container|started)
                        sv="${sv%\"}"
                        sv="${sv#\"}"
                        eval "$sk=\"\$sv\""
                        ;;
                esac
            done <<EOF
$("$START_AP" status 2>/dev/null)
EOF
        fi

        # 4. Process check
        IS_RUNNING="false"
        if [ "$running" = "1" ] || ([ -f "$RUN_DIR/hostapd.pid" ] && kill -0 "$(cat "$RUN_DIR/hostapd.pid" 2>/dev/null)" 2>/dev/null); then
            IS_RUNNING="true"
            running=1
        elif pgrep -f "hostapd.*ap0" >/dev/null 2>&1; then
            IS_RUNNING="true"
            running=1
        fi

        # 5. Count active clients
        active_arp=$(awk -v dev="${AP_IFACE:-ap0}" '($6==dev || $6=="ap0") && $3=="0x2"{c++} END{print c+0}' /proc/net/arp 2>/dev/null)
        if [ "$active_arp" -gt 0 ] 2>/dev/null; then
            clients=$active_arp
        elif [ -f "$RUN_DIR/dnsmasq.leases" ]; then
            lease_cnt=$(wc -l < "$RUN_DIR/dnsmasq.leases" 2>/dev/null || echo 0)
            [ "$lease_cnt" -gt 0 ] && clients=$lease_cnt
        fi

        # 6. Autostart check
        AUTOSTART_VAL="false"
        if [ -f "$AUTOSTART_FILE" ] && grep -q '^AUTOSTART_ENABLED=1' "$AUTOSTART_FILE"; then
            AUTOSTART_VAL="true"
        fi

        cat <<EOF
{
    "running": $IS_RUNNING,
    "ssid": "$SSID",
    "password": "$PASSWORD",
    "band": "$BAND",
    "channel": "$CHANNEL",
    "width": "$WIDTH",
    "gateway": "${gateway:-$IP_GW}",
    "dns": "$DNS_SERVERS",
    "upstream": "$UPSTREAM",
    "upstream_table": "${upstream_table:-}",
    "upstream_iface": "${upstream_iface:-}",
    "phy_iface": "$PHY_IFACE",
    "ap_iface": "$AP_IFACE",
    "security": "$SECURITY",
    "hidden": $([ "$HIDDEN" = "1" ] && echo "true" || echo "false"),
    "pmf": $([ "$PMF" = "1" ] && echo "true" || echo "false"),
    "clients": $clients,
    "started": "${started:-}",
    "hostapd": "${hostapd:-dead}",
    "dnsmasq": "${dnsmasq:-dead}",
    "autostart": $AUTOSTART_VAL,
    "native_mode": $([ -f "/data/local/virtualap/native_mode.flag" ] && echo "true" || echo "false")
}
EOF
        ;;

    interfaces)
        # Scan physical Wi-Fi radios
        PHY_LIST=""
        for d in /sys/class/net/*; do
            name="${d##*/}"
            case "$name" in
                wlan0|wlan1|wlan2)
                    [ -n "$PHY_LIST" ] && PHY_LIST="$PHY_LIST,"
                    PHY_LIST="$PHY_LIST\"$name\""
                    ;;
                *)
                    if [ -d "$d/phy80211" ] && [ "$name" != "ap0" ] && [ "$name" != "p2p0" ]; then
                        [ -n "$PHY_LIST" ] && PHY_LIST="$PHY_LIST,"
                        PHY_LIST="$PHY_LIST\"$name\""
                    fi
                    ;;
            esac
        done
        [ -z "$PHY_LIST" ] && PHY_LIST="\"wlan0\""

        # Upstream candidates with clear human descriptions
        UP_LIST="{\"name\":\"auto\",\"label\":\"auto (Default Route / 464XLAT / Mobile Data)\",\"type\":\"Auto-Steering\",\"desc\":\"Automatically detects and forwards client traffic via your phone's primary active internet gateway (Mobile Data 5G/4G or Wi-Fi). Recommended for general use.\"}"
        
        # Cellular CLAT IPv4
        if [ -d "/sys/class/net/v4-rmnet0" ]; then
            ip_v4=$(/system/bin/ip -4 -o addr show dev v4-rmnet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"v4-rmnet0\",\"label\":\"v4-rmnet0 (Cellular IPv4: ${ip_v4:-active})\",\"type\":\"5G/4G Cellular CLAT\",\"desc\":\"Primary cellular IPv4 tunnel on MTK Dimensity 720. Forwards high-speed 5G mobile data connectivity directly to tethered clients.\"}"
        fi

        # Direct Cellular
        if [ -d "/sys/class/net/rmnet0" ]; then
            UP_LIST="$UP_LIST,{\"name\":\"rmnet0\",\"label\":\"rmnet0 (Cellular Direct Modem)\",\"type\":\"5G/4G Hardware WAN\",\"desc\":\"Direct hardware cellular packet data interface from the MediaTek modem DSP. Used for dual-stack IPv4v6 mobile data.\"}"
        fi

        # Wi-Fi STA
        if [ -d "/sys/class/net/wlan0" ]; then
            ip_wlan=$(/system/bin/ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"wlan0\",\"label\":\"wlan0 (Wi-Fi STA: ${ip_wlan:-disconnected})\",\"type\":\"Wi-Fi Repeater WAN\",\"desc\":\"Shares your phone's active Wi-Fi connection through Virtual AP, USB, or Ethernet tethering (Wi-Fi Range Extender mode).\"}"
        fi

        # USB Ethernet adapters & Tethering
        for eth in /sys/class/net/eth* /sys/class/net/usb* /sys/class/net/rndis*; do
            [ ! -d "$eth" ] && continue
            ename="${eth##*/}"
            [ "$ename" = "ap0" ] || [ "$ename" = "swlan0" ] && continue
            eip=$(/system/bin/ip -4 -o addr show dev "$ename" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"$ename\",\"label\":\"$ename (Ethernet/USB: ${eip:-connected})\",\"type\":\"Ethernet / USB WAN\",\"desc\":\"Routes tether client traffic through your plugged-in USB Ethernet adapter or USB network interface.\"}"
        done

        TMP_ADDR_DIR=/data/local/virtualap/run/addr_cache
        rm -rf "$TMP_ADDR_DIR" 2>/dev/null
        mkdir -p "$TMP_ADDR_DIR"
        /system/bin/ip -o addr show 2>/dev/null | while read -r _idx _ifname _proto _ip _rest; do
            if [ "$_proto" = "inet" ]; then
                echo "$_ip" > "$TMP_ADDR_DIR/ip4_$_ifname"
            elif [ "$_proto" = "inet6" ]; then
                if [ ! -f "$TMP_ADDR_DIR/ip6_$_ifname" ]; then
                    echo "$_ip" > "$TMP_ADDR_DIR/ip6_$_ifname"
                elif echo "$_ip" | grep -qv "^fe80"; then
                    echo "$_ip" > "$TMP_ADDR_DIR/ip6_$_ifname"
                fi
            fi
        done
        
        ALL_IFACES=""
        for p in /sys/class/net/*; do
            [ ! -e "$p" ] && continue
            name="${p##*/}"
            
            operstate=""
            mtu=0
            flags=""
            mac=""
            rx_bytes=0
            tx_bytes=0
            rx_pkts=0
            tx_pkts=0
            
            read -r operstate < "$p/operstate" 2>/dev/null
            read -r mtu < "$p/mtu" 2>/dev/null
            read -r flags < "$p/flags" 2>/dev/null
            read -r mac < "$p/address" 2>/dev/null
            read -r rx_bytes < "$p/statistics/rx_bytes" 2>/dev/null
            read -r tx_bytes < "$p/statistics/tx_bytes" 2>/dev/null
            read -r rx_pkts < "$p/statistics/rx_packets" 2>/dev/null
            read -r tx_pkts < "$p/statistics/tx_packets" 2>/dev/null
            [ -z "$rx_bytes" ] && rx_bytes=0
            [ -z "$tx_bytes" ] && tx_bytes=0
            [ -z "$rx_pkts" ] && rx_pkts=0
            [ -z "$tx_pkts" ] && tx_pkts=0
            
            ip4=""
            ip4_cidr=""
            if [ -f "$TMP_ADDR_DIR/ip4_$name" ]; then
                read -r ip4_cidr < "$TMP_ADDR_DIR/ip4_$name" 2>/dev/null
                ip4="${ip4_cidr%%/*}"
            fi
            ip6=""
            if [ -f "$TMP_ADDR_DIR/ip6_$name" ]; then
                read -r ip6 < "$TMP_ADDR_DIR/ip6_$name" 2>/dev/null
            fi
            
            category="system"
            role="Internal System"
            desc="Linux kernel virtual system network interface."
            status="down"
            
            is_up=0
            if [ "$operstate" = "up" ]; then
                is_up=1
            elif [ -n "$flags" ]; then
                flag_dec=$(printf "%d" "$flags" 2>/dev/null)
                [ $((flag_dec & 1)) -ne 0 ] && is_up=1
            fi
            
            has_def=0
            case "$name" in
                v4-rmnet0) [ -n "$ip4" ] && has_def=1 ;;
                rmnet0) [ -n "$ip6" ] && has_def=1 ;;
                wlan0|eth*) [ -n "$ip4" ] && has_def=1 ;;
            esac
            
            if [ $has_def -eq 1 ]; then
                status="internet"
            elif [ "$name" = "ap0" ] || [ "$name" = "swlan0" ] || [ "$name" = "rndis0" ] || [ "$name" = "usb0" ]; then
                if [ $is_up -eq 1 ]; then status="tether"; else status="down"; fi
            elif [ $is_up -eq 1 ]; then
                status="active"
            else
                status="down"
            fi
            
            case "$name" in
                rmnet0)
                    category="upstream"
                    role="Upstream (WAN)"
                    desc="Primary 5G/4G Cellular Mobile Data WAN. Hardware packet radio modem connection to carrier network (Dual-Stack IPv4v6 or pure IPv6)."
                    ;;
                v4-rmnet0)
                    category="upstream"
                    role="Upstream (WAN)"
                    desc="Cellular CLAT (464XLAT) IPv4 Tunnel. Translates IPv4 internet packets over IPv6 cellular carrier networks (Jio / Airtel 5G). Primary IPv4 internet gateway for Android and tethered clients."
                    ;;
                rmnet[1-9]|rmnet1[0-9]|rmnet20)
                    category="cellular"
                    role="Cellular Sub-Channel"
                    desc="Auxiliary cellular multi-PDN channel used by Samsung RIL / MTK modem for IMS VoLTE, VoNR, Emergency SOS, MMS, and carrier telemetry."
                    ;;
                wlan0)
                    category="upstream"
                    role="Upstream / Radio"
                    desc="Physical Wi-Fi Radio (MediaTek MT6853). In Station mode, connects to external Wi-Fi networks as Upstream WAN. Also serves as the base radio for concurrent Virtual AP."
                    ;;
                ap0)
                    category="downstream"
                    role="Downstream (Tether LAN)"
                    desc="Virtual Access Point (VAP) Interface. Broadcasts concurrent Wi-Fi hotspot on 2.4GHz or 5GHz independent of native Android SoftAP. Gateway IP: 192.168.42.1."
                    ;;
                swlan0)
                    category="downstream"
                    role="Downstream (Tether LAN)"
                    desc="Samsung Native SoftAP Interface. Hardware AP virtual interface pre-allocated by MTK Wi-Fi driver, used by Android native Mobile Hotspot."
                    ;;
                p2p0)
                    category="system"
                    role="Wi-Fi Direct / P2P"
                    desc="Wi-Fi Direct peer-to-peer interface. Used for Samsung Quick Share, Miracast screen casting, and direct device-to-device wireless links."
                    ;;
                rndis*|usb*)
                    category="downstream"
                    role="Downstream (Tether LAN)"
                    desc="USB Tethering Gadget Interface. Emulates high-speed virtual Ethernet over USB-C cable to provide internet to PC, Mac, Linux, or router."
                    ;;
                eth*)
                    category="upstream"
                    role="Upstream / Downstream"
                    desc="USB Ethernet Adapter (Gigabit LAN). Can serve as high-speed Upstream WAN (connected to home router/modem) or Downstream LAN (sharing 5G mobile data over Ethernet cable)."
                    ;;
                ccmni-lan)
                    category="cellular"
                    role="Modem IPC"
                    desc="MediaTek CCCI Modem LAN Interface. Internal high-speed inter-processor communication channel between Android Application Processor (AP) and Cellular Baseband (MD)."
                    ;;
                dummy0)
                    category="system"
                    role="Loopback Dummy"
                    desc="Android Dummy Network Device. Virtual loopback device used by Android framework routing engine and local networking subroutines."
                    ;;
                epdg[0-7])
                    category="ims"
                    role="IMS / VoWiFi Tunnel"
                    desc="Enhanced Packet Data Gateway (ePDG) IPsec Tunnel. Secures voice calls and SMS over Wi-Fi (VoWiFi) by tunneling into carrier IMS core network."
                    ;;
                ip_vti*|ip6_vti*)
                    category="ims"
                    role="IPsec VTI Tunnel"
                    desc="Virtual Tunnel Interface (VTI) used for kernel IPsec encapsulation, secure VPNs, and VoWiFi encryption."
                    ;;
                ifb[0-9]*)
                    category="system"
                    role="Traffic Control (IFB)"
                    desc="Intermediate Functional Block. Used by Android Netd / Linux tc for ingress traffic shaping, QoS bandwidth throttling, and packet queueing."
                    ;;
                sit*|ip6tnl*)
                    category="system"
                    role="IPv6 Tunneling"
                    desc="Kernel transition tunnel interface for IPv6-in-IPv4 encapsulation (6to4 / SIT)."
                    ;;
                lo)
                    category="system"
                    role="Loopback"
                    desc="Local Host Loopback (127.0.0.1). Internal inter-process communication, local socket binding, and Web Control Panel HTTP daemon."
                    ;;
                *)
                    category="system"
                    role="Network Interface"
                    desc="General network adapter device on MediaTek MT6853 platform."
                    ;;
            esac
            
            [ -n "$ALL_IFACES" ] && ALL_IFACES="$ALL_IFACES,"
            ALL_IFACES="$ALL_IFACES{\"name\":\"$name\",\"category\":\"$category\",\"role\":\"$role\",\"status\":\"$status\",\"state\":\"$operstate\",\"is_up\":$is_up,\"ip4\":\"$ip4\",\"ip4_cidr\":\"$ip4_cidr\",\"ip6\":\"$ip6\",\"mac\":\"$mac\",\"mtu\":${mtu:-0},\"rx_bytes\":$rx_bytes,\"tx_bytes\":$tx_bytes,\"rx_pkts\":$rx_pkts,\"tx_pkts\":$tx_pkts,\"description\":\"$desc\"}"
        done
        rm -rf "$TMP_ADDR_DIR" 2>/dev/null

        cat <<EOF
{
    "phy_interfaces": [$PHY_LIST],
    "ap_modes": ["ap0"],
    "upstream_interfaces": [$UP_LIST],
    "all_interfaces": [$ALL_IFACES]
}
EOF
        ;;

    clients)
        AP_DEV="ap0"
        [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null

        CLIENT_JSON=""
        while read -r ip hw_type flags mac mask dev; do
            [ "$dev" != "$AP_DEV" ] && [ "$dev" != "ap0" ] && continue
            [ "$flags" != "0x2" ] && continue
            
            hname="Device"
            if [ -f "$RUN_DIR/dnsmasq.leases" ]; then
                found=$(grep -i "$mac" "$RUN_DIR/dnsmasq.leases" 2>/dev/null | awk '{print $4}' | head -n1)
                [ -n "$found" ] && [ "$found" != "*" ] && hname="$found"
            fi

            [ -n "$CLIENT_JSON" ] && CLIENT_JSON="$CLIENT_JSON,"
            CLIENT_JSON="$CLIENT_JSON{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hname\",\"active\":true}"
        done < /proc/net/arp

        if [ -z "$CLIENT_JSON" ] && [ -f "$RUN_DIR/dnsmasq.leases" ]; then
            while read -r exp mac ip hname cid; do
                [ -z "$mac" ] && continue
                [ -n "$CLIENT_JSON" ] && CLIENT_JSON="$CLIENT_JSON,"
                CLIENT_JSON="$CLIENT_JSON{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"${hname:-Device}\",\"active\":false}"
            done < "$RUN_DIR/dnsmasq.leases"
        fi

        echo "{\"clients\": [$CLIENT_JSON]}"
        ;;

    start)
        P_SSID=$(get_param "ssid" "hoc")
        P_PASS=$(get_param "password" "1234567890")
        P_PHY=$(get_param "phy_iface" "wlan0")
        P_AP=$(get_param "ap_iface" "ap0")
        P_UPSTREAM=$(get_param "upstream" "auto")
        P_BAND=$(get_param "band" "5")
        P_CHAN=$(get_param "channel" "")
        P_WIDTH=$(get_param "width" "")
        if [ -z "$P_WIDTH" ]; then
            [ "$P_BAND" = "5" ] && P_WIDTH="80" || P_WIDTH="20"
        fi
        P_GW=$(get_param "gateway" "192.168.42.1")
        P_DNS=$(get_param "dns" "1.1.1.1")
        P_SEC=$(get_param "security" "wpa2")
        P_HIDDEN=$(get_param "hidden" "0")

        # Sanitize defaults
        [ -z "$P_SSID" ] && P_SSID="hoc"
        [ -z "$P_PASS" ] && P_PASS="1234567890"

        # Stop existing
        sh "$START_AP" stop >/dev/null 2>&1
        sleep 1

        # 1. Save config to ap.conf
        mkdir -p /data/local/virtualap
        cat > "$CONF_FILE" <<EOF
PHY_IFACE='$P_PHY'
AP_IFACE='$P_AP'
UPSTREAM='$P_UPSTREAM'
SSID='$P_SSID'
PASSWORD='$P_PASS'
BAND='$P_BAND'
CHANNEL='$P_CHAN'
WIDTH='$P_WIDTH'
IP_GW='$P_GW'
DNS_SERVERS='$P_DNS'
HIDDEN='$P_HIDDEN'
SECURITY='$P_SEC'
PMF='0'
CONTAINER=''
EOF

        # 2. Sync directly to Android App's SharedPreferences
        set_app_pref_str "ap_ssid" "$P_SSID"
        set_app_pref_str "ap_password" "$P_PASS"
        set_app_pref_str "ap_band" "$P_BAND"
        set_app_pref_str "ap_channel" "$P_CHAN"
        set_app_pref_str "ap_width" "$P_WIDTH"
        set_app_pref_str "ap_gateway" "$P_GW"
        set_app_pref_str "ap_dns" "$P_DNS"
        set_app_pref_str "ap_upstream" "$P_UPSTREAM"
        set_app_pref_str "ap_security" "$P_SEC"
        set_app_pref_bool "ap_hidden" "$P_HIDDEN"
        sync_app_prefs_perms

        # 3. Assemble CLI launch command
        ARGS="-w '$P_PHY' -o '$P_UPSTREAM' -b '$P_BAND' -g '$P_GW' -d '$P_DNS' -s '$P_SSID' -p '$P_PASS' -W '$P_WIDTH' -A '$P_SEC' -H '$P_HIDDEN'"
        [ -n "$P_CHAN" ] && ARGS="$ARGS -c '$P_CHAN'"

        # Make sure binaries are executable
        chmod 755 /data/local/virtualap/bin/* 2>/dev/null
        chmod 755 "$START_AP" 2>/dev/null

        # Trigger background start
        eval "sh \"$START_AP\" start $ARGS" > /data/local/virtualap/logs/web_start.log 2>&1 &
        sleep 2

        # Post Android notification
        cmd notification post -S bigtext -t "VirtualAP Active" "virtualap_active" "SSID: $P_SSID | ${P_BAND}GHz (Ch ${P_CHAN:-auto}, ${P_WIDTH}MHz) | IP: $P_GW" 2>/dev/null

        IS_RUNNING="false"
        if [ -f "$RUN_DIR/hostapd.pid" ] && kill -0 "$(cat "$RUN_DIR/hostapd.pid" 2>/dev/null)" 2>/dev/null; then
            IS_RUNNING="true"
        elif pgrep -f "hostapd.*ap0" >/dev/null 2>&1; then
            IS_RUNNING="true"
        fi

        echo "{\"success\": true, \"running\": $IS_RUNNING, \"message\": \"VirtualAP started successfully\"}"
        ;;

    stop)
        sh "$START_AP" stop > /data/local/virtualap/logs/web_stop.log 2>&1
        cmd notification cancel "virtualap_active" 0 2>/dev/null
        sleep 1
        echo "{\"success\": true, \"running\": false, \"message\": \"VirtualAP stopped\"}"
        ;;

    autostart_get)
        STATE=false
        [ -f "$AUTOSTART_FILE" ] && grep -q '^AUTOSTART_ENABLED=1' "$AUTOSTART_FILE" && STATE=true
        echo "{\"autostart\": $STATE}"
        ;;

    autostart_set)
        VAL=$(get_param "enabled" "0")
        mkdir -p /data/local/virtualap
        if [ "$VAL" = "1" ] || [ "$VAL" = "true" ]; then
            echo "AUTOSTART_ENABLED=1" > "$AUTOSTART_FILE"
            echo "{\"success\": true, \"autostart\": true, \"message\": \"Autostart enabled on boot & unlock\"}"
        else
            echo "AUTOSTART_ENABLED=0" > "$AUTOSTART_FILE"
            echo "{\"success\": true, \"autostart\": false, \"message\": \"Autostart disabled\"}"
        fi
        ;;

    logs)
        LOG_HOSTAPD=$(tail -n 30 "$LOG_DIR/hostapd.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        LOG_DNSMASQ=$(tail -n 30 "$LOG_DIR/dnsmasq.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        LOG_START=$(tail -n 30 "$LOG_DIR/web_start.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        LOG_AP=$(tail -n 30 "$LOG_DIR/ap.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        cat <<EOF
{
    "hostapd": "$LOG_HOSTAPD",
    "dnsmasq": "$LOG_DNSMASQ",
    "system": "$LOG_START",
    "ap": "$LOG_AP"
}
EOF
        ;;

    # =========================================================================
    # TAB 2: NATIVE & KERNEL HOTSPOT ENDPOINTS
    # =========================================================================
    hotspot_status)
        # Multi-Vector Advanced Hotspot Detection
        VEC_IFACE="swlan0: DOWN"
        VEC_IFACE_ACTIVE="false"
        for _if in swlan0 wlan1 ap0 wlan0; do
            if [ -d "/sys/class/net/$_if" ]; then
                _st=$(cat "/sys/class/net/$_if/operstate" 2>/dev/null || echo "unknown")
                if ip link show "$_if" 2>/dev/null | grep -qE "state UP|<UP"; then
                    VEC_IFACE="$_if (UP)"
                    VEC_IFACE_ACTIVE="true"
                    break
                else
                    VEC_IFACE="$_if ($_st)"
                fi
            fi
        done

        VEC_WIFI_ROLE="Disabled"
        VEC_WIFI_ACTIVE="false"
        DUMP_WIFI=$(dumpsys wifi 2>/dev/null)
        if echo "$DUMP_WIFI" | grep -qE "ROLE_SOFTAP_TETHERED|curState=TetheredState"; then
            VEC_WIFI_ROLE="ROLE_SOFTAP_TETHERED"
            VEC_WIFI_ACTIVE="true"
        elif echo "$DUMP_WIFI" | grep -q "SoftApState{state=13"; then
            VEC_WIFI_ROLE="WIFI_AP_STATE_ENABLED (13)"
            VEC_WIFI_ACTIVE="true"
        fi

        VEC_TETHER_ACTIVE="false"
        VEC_TETHER_IFACE="None"
        DUMP_TETHER=$(dumpsys tethering 2>/dev/null)
        TETHER_LIST=$(echo "$DUMP_TETHER" | grep -A 5 "Tethered:" | grep -E "swlan0|wlan1|ap0|wlan0" | awk '{print $1}' | head -n1)
        if [ -n "$TETHER_LIST" ]; then
            VEC_TETHER_ACTIVE="true"
            VEC_TETHER_IFACE="$TETHER_LIST"
        fi

        VEC_HOSTAPD_ACTIVE="false"
        VEC_HOSTAPD_PID=$(pgrep -f "hostapd" | head -n1)
        [ -n "$VEC_HOSTAPD_PID" ] && VEC_HOSTAPD_ACTIVE="true"

        # Comprehensive Multi-Vector Evaluation
        HS_ACTIVE="false"
        if [ "$VEC_IFACE_ACTIVE" = "true" ] || [ "$VEC_WIFI_ACTIVE" = "true" ] || [ "$VEC_TETHER_ACTIVE" = "true" ] || [ "$VEC_HOSTAPD_ACTIVE" = "true" ]; then
            HS_ACTIVE="true"
        fi

        # Read SoftAp configuration from XML
        SSID_VAL="Galaxy M32 5G"
        PASS_VAL="1234567890"
        SEC_VAL="1"
        BAND_VAL="2"
        CHAN_VAL="0"
        HIDDEN_VAL="false"
        MAX_CLIENTS="10"
        AX_VAL="true"

        if [ -f "$SOFTAP_XML" ]; then
            SSID_RAW=$(grep -o '<string name="WifiSsid">[^<]*' "$SOFTAP_XML" 2>/dev/null | sed -e 's/<string name="WifiSsid">//' -e 's/&quot;//g')
            [ -n "$SSID_RAW" ] && SSID_VAL="$SSID_RAW"

            PASS_RAW=$(grep -o '<string name="Passphrase">[^<]*' "$SOFTAP_XML" 2>/dev/null | sed 's/<string name="Passphrase">//')
            [ -n "$PASS_RAW" ] && PASS_VAL="$PASS_RAW"

            SEC_RAW=$(grep -o '<int name="SecurityType" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | sed 's/.*value="//;s/"//')
            [ -n "$SEC_RAW" ] && SEC_VAL="$SEC_RAW"

            BAND_RAW=$(grep -o '<int name="Band" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | head -n1 | sed 's/.*value="//;s/"//')
            [ -n "$BAND_RAW" ] && BAND_VAL="$BAND_RAW"

            CHAN_RAW=$(grep -o '<int name="Channel" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | head -n1 | sed 's/.*value="//;s/"//')
            [ -n "$CHAN_RAW" ] && CHAN_VAL="$CHAN_RAW"

            HIDDEN_RAW=$(grep -o '<boolean name="HiddenSSID" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | sed 's/.*value="//;s/"//')
            [ -n "$HIDDEN_RAW" ] && HIDDEN_VAL="$HIDDEN_RAW"

            MAX_RAW=$(grep -o '<int name="MaxNumberOfClients" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | sed 's/.*value="//;s/"//')
            [ -n "$MAX_RAW" ] && [ "$MAX_RAW" != "0" ] && MAX_CLIENTS="$MAX_RAW"

            AX_RAW=$(grep -o '<boolean name="80211axEnabled" value="[^"]*"' "$SOFTAP_XML" 2>/dev/null | sed 's/.*value="//;s/"//')
            [ -n "$AX_RAW" ] && AX_VAL="$AX_RAW"
        fi

        # Kernel & Tethering properties
        DUN_REQ=$(settings get global tether_dun_required 2>/dev/null || echo "0")
        ENT_CHECK=$(settings get global tether_entitlement_check_state 2>/dev/null || echo "0")
        IP_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "1")
        OFFLOAD_DIS=$(settings get global tether_offload_disabled 2>/dev/null || echo "0")

        DUN_BYPASS="true"
        [ "$DUN_REQ" != "0" ] || [ "$ENT_CHECK" != "0" ] && DUN_BYPASS="false"

        IP_FWD_BOOL="true"
        [ "$IP_FWD" != "1" ] && IP_FWD_BOOL="false"

        BPF_OFFLOAD_BOOL="true"
        [ "$OFFLOAD_DIS" = "1" ] && BPF_OFFLOAD_BOOL="false"

        # Hotspot client devices (multi-interface ARP & Neigh)
        HS_CLIENTS=""
        while read -r ip hw_type flags mac mask dev; do
            case "$dev" in
                swlan0|ap0|wlan1) ;;
                *) continue ;;
            esac
            [ "$flags" != "0x2" ] && continue
            [ -n "$HS_CLIENTS" ] && HS_CLIENTS="$HS_CLIENTS,"
            HS_CLIENTS="$HS_CLIENTS{\"ip\":\"$ip\",\"mac\":\"$mac\",\"iface\":\"$dev\"}"
        done < /proc/net/arp

        cat <<EOF
{
    "active": $HS_ACTIVE,
    "ssid": "$SSID_VAL",
    "password": "$PASS_VAL",
    "security": "$SEC_VAL",
    "band": "$BAND_VAL",
    "channel": "$CHAN_VAL",
    "hidden": $HIDDEN_VAL,
    "max_clients": $MAX_CLIENTS,
    "ax_enabled": $AX_VAL,
    "dun_bypass": $DUN_BYPASS,
    "ip_forward": $IP_FWD_BOOL,
    "bpf_offload": $BPF_OFFLOAD_BOOL,
    "detection_vectors": {
        "kernel_iface": {"active": $VEC_IFACE_ACTIVE, "desc": "$VEC_IFACE"},
        "wifi_framework": {"active": $VEC_WIFI_ACTIVE, "desc": "$VEC_WIFI_ROLE"},
        "tethering_service": {"active": $VEC_TETHER_ACTIVE, "desc": "$VEC_TETHER_IFACE"},
        "hostapd_daemon": {"active": $VEC_HOSTAPD_ACTIVE, "desc": "$([ -n "$VEC_HOSTAPD_PID" ] && echo "PID $VEC_HOSTAPD_PID" || echo "Stopped")"}
    },
    "clients": [$HS_CLIENTS]
}
EOF
        ;;

    hotspot_toggle)
        ENABLE=$(get_param "enable" "1")
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            # Turn on Hotspot via native cmd or intent
            cmd wifi start-softap "$(get_param "ssid" "Galaxy-M32")" wpa2 "$(get_param "pass" "1234567890")" -b 5 2>/dev/null || true
            # Also post notification
            cmd notification post -S bigtext -t "Mobile Hotspot Active" "hotspot_active" "Mobile Hotspot is sharing connection" 2>/dev/null
            echo "{\"success\": true, \"message\": \"Hotspot start command dispatched\"}"
        else
            cmd wifi stop-softap 2>/dev/null || true
            cmd notification cancel "hotspot_active" 0 2>/dev/null
            echo "{\"success\": true, \"message\": \"Hotspot stopped\"}"
        fi
        ;;

    hotspot_set_dun)
        STATE=$(get_param "enable" "1")
        if [ "$STATE" = "1" ] || [ "$STATE" = "true" ]; then
            settings put global tether_dun_required 0
            settings put global tether_entitlement_check_state 0
            echo "{\"success\": true, \"dun_bypass\": true, \"message\": \"Carrier DUN & Entitlement checks BYPASSED\"}"
        else
            settings put global tether_dun_required 1
            settings put global tether_entitlement_check_state 1
            echo "{\"success\": true, \"dun_bypass\": false, \"message\": \"Carrier DUN restrictions restored\"}"
        fi
        ;;

    hotspot_set_ip_forward)
        STATE=$(get_param "enable" "1")
        if [ "$STATE" = "1" ] || [ "$STATE" = "true" ]; then
            echo 1 > /proc/sys/net/ipv4/ip_forward
            echo "{\"success\": true, \"ip_forward\": true}"
        else
            echo 0 > /proc/sys/net/ipv4/ip_forward
            echo "{\"success\": true, \"ip_forward\": false}"
        fi
        ;;

    hotspot_set_offload)
        STATE=$(get_param "enable" "1")
        if [ "$STATE" = "1" ] || [ "$STATE" = "true" ]; then
            settings put global tether_offload_disabled 0
            echo "{\"success\": true, \"bpf_offload\": true, \"message\": \"BPF hardware tethering offload ENABLED\"}"
        else
            settings put global tether_offload_disabled 1
            echo "{\"success\": true, \"bpf_offload\": false, \"message\": \"BPF hardware tethering offload DISABLED\"}"
        fi
        ;;

    hotspot_save_config)
        NEW_SSID=$(get_param "ssid" "Galaxy M32 5G")
        NEW_PASS=$(get_param "password" "1234567890")
        NEW_BAND=$(get_param "band" "2")
        NEW_CHAN=$(get_param "channel" "149")
        NEW_MAX=$(get_param "max_clients" "10")
        NEW_HIDDEN=$(get_param "hidden" "false")

        if [ -f "$SOFTAP_XML" ]; then
            sed -i "s|<string name=\"WifiSsid\">.*</string>|<string name=\"WifiSsid\">\&quot;$NEW_SSID\&quot;</string>|" "$SOFTAP_XML"
            sed -i "s|<string name=\"Passphrase\">.*</string>|<string name=\"Passphrase\">$NEW_PASS</string>|" "$SOFTAP_XML"
            sed -i "s|<int name=\"Band\" value=\".*\" />|<int name=\"Band\" value=\"$NEW_BAND\" />|" "$SOFTAP_XML"
            sed -i "s|<int name=\"Channel\" value=\".*\" />|<int name=\"Channel\" value=\"$NEW_CHAN\" />|" "$SOFTAP_XML"
            sed -i "s|<int name=\"MaxNumberOfClients\" value=\".*\" />|<int name=\"MaxNumberOfClients\" value=\"$NEW_MAX\" />|" "$SOFTAP_XML"
            sed -i "s|<boolean name=\"HiddenSSID\" value=\".*\" />|<boolean name=\"HiddenSSID\" value=\"$NEW_HIDDEN\" />|" "$SOFTAP_XML"
        fi
        echo "{\"success\": true, \"message\": \"Hotspot settings saved to Android Wi-Fi config store\"}"
        ;;

    # =========================================================================
    # TAB 3: USB TETHERING ENDPOINTS
    # =========================================================================
    usb_status)
        USB_CONNECTED="false"
        USB_TETHER_ACTIVE="false"
        USB_IFACE="rndis0"
        USB_IP="Not Assigned"
        USB_SPEED="High Speed (480 Mbps)"
        USB_MTU="1500"
        RX_BYTES=0
        TX_BYTES=0
        RX_PKTS=0
        TX_PKTS=0

        # Check USB functions & connection
        USB_FUNCS=$(svc usb getFunctions 2>/dev/null || getprop sys.usb.config 2>/dev/null || echo "")
        [ -d "/sys/class/android_usb" ] && USB_CONNECTED="true"
        [ -n "$USB_FUNCS" ] && USB_CONNECTED="true"

        # Check if rndis0 or usb0 is active
        for udev in rndis0 usb0 ncm0; do
            if [ -d "/sys/class/net/$udev" ]; then
                USB_IFACE="$udev"
                if /system/bin/ip link show "$udev" 2>/dev/null | grep -q "UP"; then
                    USB_TETHER_ACTIVE="true"
                fi
                USB_MTU=$(cat "/sys/class/net/$udev/mtu" 2>/dev/null || echo "1500")
                USB_IP=$(/system/bin/ip -4 -o addr show dev "$udev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
                [ -z "$USB_IP" ] && USB_IP="Configured (Tethered)"
                
                RX_BYTES=$(cat "/sys/class/net/$udev/statistics/rx_bytes" 2>/dev/null || echo 0)
                TX_BYTES=$(cat "/sys/class/net/$udev/statistics/tx_bytes" 2>/dev/null || echo 0)
                RX_PKTS=$(cat "/sys/class/net/$udev/statistics/rx_packets" 2>/dev/null || echo 0)
                TX_PKTS=$(cat "/sys/class/net/$udev/statistics/tx_packets" 2>/dev/null || echo 0)
                break
            fi
        done

        SPEED_RAW=$(svc usb getUsbSpeed 2>/dev/null || cat /sys/class/udc/*/current_speed 2>/dev/null || echo "")
        [ -n "$SPEED_RAW" ] && USB_SPEED="$SPEED_RAW"

        cat <<EOF
{
    "connected": $USB_CONNECTED,
    "active": $USB_TETHER_ACTIVE,
    "interface": "$USB_IFACE",
    "ip": "${USB_IP:-Not Assigned}",
    "functions": "${USB_FUNCS:-rndis,adb}",
    "speed": "$USB_SPEED",
    "mtu": $USB_MTU,
    "rx_bytes": $RX_BYTES,
    "tx_bytes": $TX_BYTES,
    "rx_packets": $RX_PKTS,
    "tx_packets": $TX_PKTS
}
EOF
        ;;

    usb_toggle)
        ENABLE=$(get_param "enable" "1")
        MODE=$(get_param "mode" "rndis")
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            svc usb setFunctions "$MODE" 2>/dev/null || setprop sys.usb.config "${MODE},adb"
            cmd notification post -S bigtext -t "USB Tethering Active" "usb_tether" "USB Tethering ($MODE) is active" 2>/dev/null
            echo "{\"success\": true, \"message\": \"USB Tethering ($MODE) activated\"}"
        else
            svc usb setFunctions mtp 2>/dev/null || setprop sys.usb.config "mtp,adb"
            cmd notification cancel "usb_tether" 0 2>/dev/null
            echo "{\"success\": true, \"message\": \"USB Tethering stopped\"}"
        fi
        ;;

    usb_set_mtu)
        NEW_MTU=$(get_param "mtu" "1500")
        IFACE=$(get_param "iface" "rndis0")
        /system/bin/ip link set "$IFACE" mtu "$NEW_MTU" 2>/dev/null
        echo "{\"success\": true, \"mtu\": $NEW_MTU, \"message\": \"MTU set to $NEW_MTU on $IFACE\"}"
        ;;

    # =========================================================================
    # TAB 4: ETHERNET ENDPOINTS
    # =========================================================================
    ethernet_status)
        ETH_PRESENT="false"
        ETH_DEV=""
        ETH_CARRIER="false"
        ETH_SPEED="0"
        ETH_DUPLEX="unknown"
        ETH_MAC="00:00:00:00:00:00"
        ETH_IP="Not Assigned"
        ETH_TETHER_ACTIVE="false"
        ETH_DRIVER="USB Ethernet"
        RX_BYTES=0
        TX_BYTES=0

        for edev in /sys/class/net/eth* /sys/class/net/usb*; do
            [ ! -d "$edev" ] && continue
            name="${edev##*/}"
            ETH_PRESENT="true"
            ETH_DEV="$name"

            cval=$(cat "$edev/carrier" 2>/dev/null || echo "0")
            [ "$cval" = "1" ] && ETH_CARRIER="true"

            sval=$(cat "$edev/speed" 2>/dev/null || echo "0")
            [ -n "$sval" ] && [ "$sval" != "-1" ] && ETH_SPEED="$sval"

            dval=$(cat "$edev/duplex" 2>/dev/null || echo "unknown")
            [ -n "$dval" ] && ETH_DUPLEX="$dval"

            mval=$(cat "$edev/address" 2>/dev/null || echo "")
            [ -n "$mval" ] && ETH_MAC="$mval"

            eip=$(/system/bin/ip -4 -o addr show dev "$name" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            [ -n "$eip" ] && ETH_IP="$eip"

            # Check driver/chipset
            if [ -e "$edev/device/driver" ]; then
                dname=$(readlink "$edev/device/driver" 2>/dev/null)
                [ -n "$dname" ] && ETH_DRIVER="${dname##*/}"
            fi

            # Check if tethering / dnsmasq is serving eth
            if pgrep -f "dnsmasq.*$name" >/dev/null 2>&1; then
                ETH_TETHER_ACTIVE="true"
            fi

            RX_BYTES=$(cat "$edev/statistics/rx_bytes" 2>/dev/null || echo 0)
            TX_BYTES=$(cat "$edev/statistics/tx_bytes" 2>/dev/null || echo 0)
            break
        done

        cat <<EOF
{
    "present": $ETH_PRESENT,
    "interface": "$ETH_DEV",
    "carrier": $ETH_CARRIER,
    "speed": "$ETH_SPEED",
    "duplex": "$ETH_DUPLEX",
    "mac": "$ETH_MAC",
    "ip": "$ETH_IP",
    "driver": "$ETH_DRIVER",
    "tether_active": $ETH_TETHER_ACTIVE,
    "rx_bytes": $RX_BYTES,
    "tx_bytes": $TX_BYTES
}
EOF
        ;;

    ethernet_toggle_tether)
        ENABLE=$(get_param "enable" "1")
        IFACE=$(get_param "iface" "eth0")
        [ -z "$IFACE" ] && IFACE="eth0"

        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            # Setup Ethernet Tethering: assign gateway IP + DHCP + NAT
            /system/bin/ip link set "$IFACE" up 2>/dev/null
            /system/bin/ip addr flush dev "$IFACE" 2>/dev/null
            /system/bin/ip addr add 192.168.100.1/24 dev "$IFACE" 2>/dev/null

            # Kill old instance
            pkill -f "dnsmasq.*$IFACE" 2>/dev/null

            # Run dnsmasq for LAN clients
            /data/local/virtualap/bin/dnsmasq \
                --interface="$IFACE" \
                --bind-interfaces \
                --dhcp-range=192.168.100.10,192.168.100.100,255.255.255.0,12h \
                --dhcp-option=3,192.168.100.1 \
                --dhcp-option=6,1.1.1.1,8.8.8.8 \
                --leasefile-ro \
                >/dev/null 2>&1 &

            # Enable NAT
            echo 1 > /proc/sys/net/ipv4/ip_forward
            /system/bin/iptables -t nat -A POSTROUTING -o v4-rmnet0 -j MASQUERADE 2>/dev/null || true
            /system/bin/iptables -t nat -A POSTROUTING -o rmnet0 -j MASQUERADE 2>/dev/null || true
            /system/bin/iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE 2>/dev/null || true
            /system/bin/iptables -I FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
            /system/bin/iptables -I FORWARD -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

            cmd notification post -S bigtext -t "Ethernet Tethering Active" "eth_tether" "Ethernet LAN sharing is active on $IFACE" 2>/dev/null
            echo "{\"success\": true, \"message\": \"Ethernet Tethering active on $IFACE (192.168.100.1)\"}"
        else
            pkill -f "dnsmasq.*$IFACE" 2>/dev/null
            /system/bin/ip addr flush dev "$IFACE" 2>/dev/null
            cmd notification cancel "eth_tether" 0 2>/dev/null
            echo "{\"success\": true, \"message\": \"Ethernet Tethering stopped\"}"
        fi
        ;;

    ethernet_set_ip)
        IFACE=$(get_param "iface" "eth0")
        MODE=$(get_param "mode" "dhcp")
        IP_ADDR=$(get_param "ip" "192.168.1.150")
        GW_ADDR=$(get_param "gateway" "192.168.1.1")
        DNS_ADDR=$(get_param "dns" "1.1.1.1")

        /system/bin/ip link set "$IFACE" up 2>/dev/null
        if [ "$MODE" = "static" ]; then
            /system/bin/ip addr flush dev "$IFACE" 2>/dev/null
            /system/bin/ip addr add "$IP_ADDR/24" dev "$IFACE" 2>/dev/null
            [ -n "$GW_ADDR" ] && /system/bin/ip route add default via "$GW_ADDR" dev "$IFACE" 2>/dev/null
            echo "{\"success\": true, \"message\": \"Static IP $IP_ADDR assigned to $IFACE\"}"
        else
            # DHCP mode
            /data/adb/magisk/busybox udhcpc -i "$IFACE" -n -q -t 5 >/dev/null 2>&1 &
            echo "{\"success\": true, \"message\": \"DHCP client dispatched on $IFACE\"}"
        fi
        ;;

    # =========================================================================
    # TAB 5: CARRIER BYPASS & SYSTEM SETTINGS ENDPOINTS
    # =========================================================================
    # =========================================================================
    # TAB 5: MODULAR CARRIER BYPASS & SYSTEM SETTINGS ENDPOINTS
    # =========================================================================
    settings_status)
        SETTINGS_CONF="/data/local/virtualap/settings.conf"
        [ -f "$SETTINGS_CONF" ] && . "$SETTINGS_CONF"

        [ -z "$CFG_CARRIER_BYPASS" ] && CFG_CARRIER_BYPASS="0"
        [ -z "$CFG_TARGET_TTL" ] && CFG_TARGET_TTL="64"
        [ -z "$CFG_TTL_BYPASS" ] && CFG_TTL_BYPASS="1"
        [ -z "$CFG_DUN_BYPASS" ] && CFG_DUN_BYPASS="1"
        [ -z "$CFG_MSS_CLAMP" ] && CFG_MSS_CLAMP="1"
        [ -z "$CFG_DNS_PROTECT" ] && CFG_DNS_PROTECT="1"
        [ -z "$CFG_IPV6_PROTECT" ] && CFG_IPV6_PROTECT="1"
        [ -z "$CFG_BPF_OFFLOAD_DISABLED" ] && CFG_BPF_OFFLOAD_DISABLED="1"
        [ -z "$CFG_PROVISIONING_SHIELD" ] && CFG_PROVISIONING_SHIELD="1"
        [ -z "$CFG_DEDICATED_ROUTER" ] && CFG_DEDICATED_ROUTER="0"
        [ -z "$CFG_NATIVE_MODE" ] && CFG_NATIVE_MODE="0"
        [ -z "$CFG_PURE_PASSTHROUGH" ] && CFG_PURE_PASSTHROUGH="0"

        # Check real-time iptables and system status
        ROUTER_ACTIVE="false"
        if /system/bin/iptables -w 2 -L OUTPUT -n 2>/dev/null | grep -q "DEDICATED_ROUTER_OUT"; then
            ROUTER_ACTIVE="true"
        fi

        # Check Pure Direct Modem Passthrough status
        LIVE_PURE_PASSTHROUGH="false"
        if /system/bin/iptables -w 2 -L FORWARD -n 2>/dev/null | grep -q "PURE_FORWARD"; then
            LIVE_PURE_PASSTHROUGH="true"
        fi

        # Check real-time status of each vector
        DUN_REQ=$(settings get global tether_dun_required 2>/dev/null || echo "1")
        LIVE_DUN_BYPASS="false"
        [ "$DUN_REQ" = "0" ] && LIVE_DUN_BYPASS="true"

        LIVE_MSS_CLAMP="false"
        if /system/bin/iptables -w 2 -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS clamp to PMTU"; then
            LIVE_MSS_CLAMP="true"
        fi

        LIVE_DNS_PROTECT="false"
        if /system/bin/iptables -w 2 -t nat -L PREROUTING -n 2>/dev/null | grep -q "to:1.1.1.1:53"; then
            LIVE_DNS_PROTECT="true"
        fi

        LIVE_IPV6_PROTECT="false"
        if /system/bin/ip6tables -w 2 -L FORWARD -n 2>/dev/null | grep -q "DROP"; then
            LIVE_IPV6_PROTECT="true"
        fi

        CUR_SYS_TTL=$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null || echo "64")
        LIVE_TTL_BYPASS="false"
        [ "$CFG_TTL_BYPASS" = "1" ] && LIVE_TTL_BYPASS="true"

        OFFLOAD_DIS=$(settings get global tether_offload_disabled 2>/dev/null || echo "0")
        LIVE_BPF_OFFLOAD_DIS="false"
        [ "$OFFLOAD_DIS" = "1" ] && LIVE_BPF_OFFLOAD_DIS="true"

        NOPROV_PROP=$(getprop net.tethering.noprovisioning 2>/dev/null || echo "false")
        LIVE_PROV_SHIELD="false"
        [ "$NOPROV_PROP" = "true" ] && LIVE_PROV_SHIELD="true"

        BYPASS_ACTIVE="false"
        if [ "$LIVE_DUN_BYPASS" = "true" ] || [ "$CFG_CARRIER_BYPASS" = "1" ]; then
            BYPASS_ACTIVE="true"
        fi

        NATIVE_FLAG_ACTIVE="false"
        [ -f "/data/local/virtualap/native_mode.flag" ] && NATIVE_FLAG_ACTIVE="true"

        cat <<EOF
{
    "carrier_bypass": $BYPASS_ACTIVE,
    "pure_passthrough": $LIVE_PURE_PASSTHROUGH,
    "target_ttl": $CFG_TARGET_TTL,
    "current_sys_ttl": $CUR_SYS_TTL,
    "ttl_bypass": $LIVE_TTL_BYPASS,
    "dun_bypass": $LIVE_DUN_BYPASS,
    "mss_clamp": $LIVE_MSS_CLAMP,
    "dns_protect": $LIVE_DNS_PROTECT,
    "ipv6_protect": $LIVE_IPV6_PROTECT,
    "bpf_offload_disabled": $LIVE_BPF_OFFLOAD_DIS,
    "provisioning_shield": $LIVE_PROV_SHIELD,
    "dedicated_router": $ROUTER_ACTIVE,
    "native_mode": $NATIVE_FLAG_ACTIVE
}
EOF
        ;;

    settings_toggle_method)
        METHOD=$(get_param "method" "")
        ENABLE=$(get_param "enable" "1")
        TTL_VAL=$(get_param "ttl" "64")
        [ -z "$TTL_VAL" ] && TTL_VAL="64"
        SETTINGS_CONF="/data/local/virtualap/settings.conf"
        [ -f "$SETTINGS_CONF" ] && . "$SETTINGS_CONF"

        [ -z "$CFG_CARRIER_BYPASS" ] && CFG_CARRIER_BYPASS="1"
        [ -z "$CFG_TARGET_TTL" ] && CFG_TARGET_TTL="64"
        [ -z "$CFG_TTL_BYPASS" ] && CFG_TTL_BYPASS="1"
        [ -z "$CFG_DUN_BYPASS" ] && CFG_DUN_BYPASS="1"
        [ -z "$CFG_MSS_CLAMP" ] && CFG_MSS_CLAMP="1"
        [ -z "$CFG_DNS_PROTECT" ] && CFG_DNS_PROTECT="1"
        [ -z "$CFG_IPV6_PROTECT" ] && CFG_IPV6_PROTECT="1"
        [ -z "$CFG_BPF_OFFLOAD_DISABLED" ] && CFG_BPF_OFFLOAD_DISABLED="1"
        [ -z "$CFG_PROVISIONING_SHIELD" ] && CFG_PROVISIONING_SHIELD="1"

        IS_ON="0"
        [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ] && IS_ON="1"
        MSG=""

        case "$METHOD" in
            ttl)
                CFG_TTL_BYPASS="$IS_ON"
                CFG_TARGET_TTL="$TTL_VAL"
                if [ "$IS_ON" = "1" ]; then
                    sysctl -w net.ipv4.ip_default_ttl="$TTL_VAL" 2>/dev/null || true
                    sysctl -w net.ipv6.conf.all.hop_limit="$TTL_VAL" 2>/dev/null || true
                    sysctl -w net.ipv6.conf.default.hop_limit="$TTL_VAL" 2>/dev/null || true
                    /system/bin/iptables -w 5 -t mangle -D POSTROUTING -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
                    /system/bin/iptables -w 5 -t mangle -I POSTROUTING 1 -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
                    MSG="TTL / Hop Limit Cloak ENABLED (TTL $TTL_VAL)"
                else
                    sysctl -w net.ipv4.ip_default_ttl=64 2>/dev/null || true
                    /system/bin/iptables -w 5 -t mangle -D POSTROUTING -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
                    MSG="TTL / Hop Limit Cloak disabled"
                fi
                ;;
            dun)
                CFG_DUN_BYPASS="$IS_ON"
                if [ "$IS_ON" = "1" ]; then
                    settings put global tether_dun_required 0 2>/dev/null
                    settings put global tether_dun_apn "" 2>/dev/null
                    settings put global tether_entitlement_check_state 0 2>/dev/null
                    MSG="Carrier DUN APN & Entitlement Bypass ENABLED"
                else
                    settings put global tether_dun_required 1 2>/dev/null
                    settings put global tether_entitlement_check_state 1 2>/dev/null
                    MSG="Carrier DUN APN & Entitlement Bypass disabled"
                fi
                ;;
            mss)
                CFG_MSS_CLAMP="$IS_ON"
                /system/bin/iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
                if [ "$IS_ON" = "1" ]; then
                    /system/bin/iptables -w 5 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
                    MSG="TCP MSS Clamping (PMTU) ENABLED"
                else
                    MSG="TCP MSS Clamping disabled"
                fi
                ;;
            dns)
                CFG_DNS_PROTECT="$IS_ON"
                /system/bin/iptables -w 5 -t nat -D PREROUTING -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
                /system/bin/iptables -w 5 -t nat -D PREROUTING -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
                if [ "$IS_ON" = "1" ]; then
                    /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
                    /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
                    MSG="DNS Leak & DPI Cloaking (1.1.1.1) ENABLED"
                else
                    MSG="DNS Leak & DPI Cloaking disabled"
                fi
                ;;
            ipv6)
                CFG_IPV6_PROTECT="$IS_ON"
                /system/bin/ip6tables -w 5 -D FORWARD -j DROP 2>/dev/null || true
                if [ "$IS_ON" = "1" ]; then
                    /system/bin/ip6tables -w 5 -I FORWARD 1 -j DROP 2>/dev/null || true
                    MSG="IPv6 EUI-64 & Leak Shield ENABLED"
                else
                    MSG="IPv6 EUI-64 & Leak Shield disabled"
                fi
                ;;
            bpf)
                CFG_BPF_OFFLOAD_DISABLED="$IS_ON"
                if [ "$IS_ON" = "1" ]; then
                    settings put global tether_offload_disabled 1 2>/dev/null
                    MSG="BPF Hardware Tether Offload Disabled (Forced Netfilter Inspection ENABLED)"
                else
                    settings put global tether_offload_disabled 0 2>/dev/null
                    MSG="BPF Hardware Tether Offload enabled (Stock)"
                fi
                ;;
            provisioning)
                CFG_PROVISIONING_SHIELD="$IS_ON"
                if [ "$IS_ON" = "1" ]; then
                    setprop net.tethering.noprovisioning true 2>/dev/null
                    setprop persist.sys.tether.noprovisioning true 2>/dev/null
                    MSG="Platform Tether Provisioning Shield ENABLED"
                else
                    setprop net.tethering.noprovisioning false 2>/dev/null
                    setprop persist.sys.tether.noprovisioning false 2>/dev/null
                    MSG="Platform Tether Provisioning Shield disabled"
                fi
                ;;
            pure|pure_passthrough)
                CFG_PURE_PASSTHROUGH="$IS_ON"
                if [ "$IS_ON" = "1" ]; then
                    # 1. Direct forwarding chain: wire-speed ACCEPT bypassing ALL Android filter & quota chains
                    /system/bin/iptables -w 2 -N PURE_FORWARD 2>/dev/null || /system/bin/iptables -w 2 -F PURE_FORWARD
                    /system/bin/iptables -w 2 -A PURE_FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i ap0 -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i rndis+ -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i usb+ -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i eth+ -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i swlan+ -j ACCEPT
                    /system/bin/iptables -w 2 -A PURE_FORWARD -i wlan+ -j ACCEPT
                    /system/bin/iptables -w 2 -D FORWARD -j PURE_FORWARD 2>/dev/null || true
                    /system/bin/iptables -w 2 -I FORWARD 1 -j PURE_FORWARD 2>/dev/null || true

                    # 2. Direct cellular modem NAT masquerade at top of POSTROUTING
                    /system/bin/iptables -w 2 -t nat -N PURE_NAT 2>/dev/null || /system/bin/iptables -w 2 -t nat -F PURE_NAT
                    /system/bin/iptables -w 2 -t nat -A PURE_NAT -o rmnet+ -j MASQUERADE
                    /system/bin/iptables -w 2 -t nat -A PURE_NAT -o v4-rmnet+ -j MASQUERADE
                    /system/bin/iptables -w 2 -t nat -A PURE_NAT -o ccmni+ -j MASQUERADE
                    /system/bin/iptables -w 2 -t nat -A PURE_NAT -o pdp+ -j MASQUERADE
                    /system/bin/iptables -w 2 -t nat -D POSTROUTING -j PURE_NAT 2>/dev/null || true
                    /system/bin/iptables -w 2 -t nat -I POSTROUTING 1 -j PURE_NAT 2>/dev/null || true

                    # 3. IPv6 Forwarding passthrough
                    /system/bin/ip6tables -w 2 -N PURE_FORWARD_V6 2>/dev/null || /system/bin/ip6tables -w 2 -F PURE_FORWARD_V6
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -m state --state ESTABLISHED,RELATED -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i ap0 -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i rndis+ -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i usb+ -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i eth+ -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i swlan+ -j ACCEPT
                    /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i wlan+ -j ACCEPT
                    /system/bin/ip6tables -w 2 -D FORWARD -j PURE_FORWARD_V6 2>/dev/null || true
                    /system/bin/ip6tables -w 2 -I FORWARD 1 -j PURE_FORWARD_V6 2>/dev/null || true

                    # 4. TCP MSS PMTU clamping
                    /system/bin/iptables -w 2 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
                    /system/bin/iptables -w 2 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

                    # 5. Kernel wire-speed forwarding optimizations
                    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
                    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
                    sysctl -w net.core.netdev_max_backlog=10000 >/dev/null 2>&1 || true
                    sysctl -w net.core.somaxconn=4096 >/dev/null 2>&1 || true

                    # 6. Ensure carrier DUN checks and entitlement queries don't throttle
                    settings put global tether_dun_required 0 2>/dev/null || true
                    settings put global tether_entitlement_check_state 0 2>/dev/null || true

                    MSG="Pure Direct Passthrough ENABLED: Cellular WAN routed directly to downstream clients without filters or inspection"
                else
                    /system/bin/iptables -w 2 -D FORWARD -j PURE_FORWARD 2>/dev/null || true
                    /system/bin/iptables -w 2 -F PURE_FORWARD 2>/dev/null || true
                    /system/bin/iptables -w 2 -X PURE_FORWARD 2>/dev/null || true

                    /system/bin/iptables -w 2 -t nat -D POSTROUTING -j PURE_NAT 2>/dev/null || true
                    /system/bin/iptables -w 2 -t nat -F PURE_NAT 2>/dev/null || true
                    /system/bin/iptables -w 2 -t nat -X PURE_NAT 2>/dev/null || true

                    /system/bin/ip6tables -w 2 -D FORWARD -j PURE_FORWARD_V6 2>/dev/null || true
                    /system/bin/ip6tables -w 2 -F PURE_FORWARD_V6 2>/dev/null || true
                    /system/bin/ip6tables -w 2 -X PURE_FORWARD_V6 2>/dev/null || true

                    MSG="Pure Direct Passthrough disabled: Android netfilter chains restored"
                fi
                ;;
            *)
                echo "{\"success\": false, \"error\": \"Unknown method: $METHOD\"}"
                exit 0
                ;;
        esac

        # Save state to SETTINGS_CONF
        cat <<EOF > "$SETTINGS_CONF"
CFG_CARRIER_BYPASS="$CFG_CARRIER_BYPASS"
CFG_TARGET_TTL="$CFG_TARGET_TTL"
CFG_TTL_BYPASS="$CFG_TTL_BYPASS"
CFG_DUN_BYPASS="$CFG_DUN_BYPASS"
CFG_MSS_CLAMP="$CFG_MSS_CLAMP"
CFG_DNS_PROTECT="$CFG_DNS_PROTECT"
CFG_IPV6_PROTECT="$CFG_IPV6_PROTECT"
CFG_BPF_OFFLOAD_DISABLED="$CFG_BPF_OFFLOAD_DISABLED"
CFG_PROVISIONING_SHIELD="$CFG_PROVISIONING_SHIELD"
CFG_PURE_PASSTHROUGH="$CFG_PURE_PASSTHROUGH"
EOF
        echo "{\"success\": true, \"method\": \"$METHOD\", \"enabled\": $([ "$IS_ON" = "1" ] && echo "true" || echo "false"), \"message\": \"$MSG\"}"
        ;;

    settings_toggle_bypass)
        ENABLE=$(get_param "enable" "1")
        TTL_VAL=$(get_param "ttl" "64")
        [ -z "$TTL_VAL" ] && TTL_VAL="64"
        SETTINGS_CONF="/data/local/virtualap/settings.conf"

        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            # 1. Disable DUN APN requirement and entitlement verification
            settings put global tether_dun_required 0 2>/dev/null
            settings put global tether_dun_apn "" 2>/dev/null
            settings put global tether_entitlement_check_state 0 2>/dev/null
            setprop net.tethering.noprovisioning true 2>/dev/null
            setprop persist.sys.tether.noprovisioning true 2>/dev/null

            # 2. Sysctl default hop limit & TTL
            sysctl -w net.ipv4.ip_default_ttl="$TTL_VAL" 2>/dev/null || true
            sysctl -w net.ipv6.conf.all.hop_limit="$TTL_VAL" 2>/dev/null || true
            sysctl -w net.ipv6.conf.default.hop_limit="$TTL_VAL" 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -D POSTROUTING -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -I POSTROUTING 1 -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true

            # 3. TCP MSS Clamping to PMTU across all forwarded interfaces
            /system/bin/iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            # 4. DNS Leak Protection: redirect client DNS lookups to 1.1.1.1
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -I PREROUTING 1 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true

            # 5. IPv6 Leak Protection: block global IPv6 tether leaks to carrier
            /system/bin/ip6tables -w 5 -D FORWARD -j DROP 2>/dev/null || true
            /system/bin/ip6tables -w 5 -I FORWARD 1 -j DROP 2>/dev/null || true

            # 6. Disable BPF hardware offload
            settings put global tether_offload_disabled 1 2>/dev/null

            # Save state
            cat <<EOF > "$SETTINGS_CONF"
CFG_CARRIER_BYPASS="1"
CFG_TARGET_TTL="$TTL_VAL"
CFG_TTL_BYPASS="1"
CFG_DUN_BYPASS="1"
CFG_MSS_CLAMP="1"
CFG_DNS_PROTECT="1"
CFG_IPV6_PROTECT="1"
CFG_BPF_OFFLOAD_DISABLED="1"
CFG_PROVISIONING_SHIELD="1"
EOF
            echo "{\"success\": true, \"carrier_bypass\": true, \"message\": \"Carrier Hotspot Bypass ACTIVE for all tethering modes\"}"
        else
            # Revert bypass
            settings put global tether_dun_required 1 2>/dev/null
            settings put global tether_entitlement_check_state 1 2>/dev/null
            setprop net.tethering.noprovisioning false 2>/dev/null
            setprop persist.sys.tether.noprovisioning false 2>/dev/null
            settings put global tether_offload_disabled 0 2>/dev/null

            sysctl -w net.ipv4.ip_default_ttl=64 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -D POSTROUTING -j TTL --ttl-set "$TTL_VAL" 2>/dev/null || true
            /system/bin/iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/iptables -w 5 -t nat -D PREROUTING -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
            /system/bin/ip6tables -w 5 -D FORWARD -j DROP 2>/dev/null || true

            cat <<EOF > "$SETTINGS_CONF"
CFG_CARRIER_BYPASS="0"
CFG_TARGET_TTL="64"
CFG_TTL_BYPASS="0"
CFG_DUN_BYPASS="0"
CFG_MSS_CLAMP="0"
CFG_DNS_PROTECT="0"
CFG_IPV6_PROTECT="0"
CFG_BPF_OFFLOAD_DISABLED="0"
CFG_PROVISIONING_SHIELD="0"
EOF
            echo "{\"success\": true, \"carrier_bypass\": false, \"message\": \"Carrier Hotspot Bypass disabled\"}"
        fi
        ;;
    settings_toggle_dedicated_router)
        ENABLE=$(get_param "enable" "1")
        FLAG="/data/local/virtualap/dedicated_router.flag"
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            touch "$FLAG"

            # 1. Create or flush dedicated router output filter
            /system/bin/iptables -w 5 -N DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/iptables -w 5 -F DEDICATED_ROUTER_OUT 2>/dev/null || true
            
            # Allow loopback (localhost services, WebUI 8088/8093)
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o lo -j ACCEPT
            
            # Allow LAN / Tether subnets so connected clients can reach phone / gateway
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o ap0 -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o swlan+ -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o wlan+ -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o rndis+ -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o usb+ -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -o eth+ -j ACCEPT
            
            # Allow DHCP and DNS resolution for tethered clients
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -p udp --dport 53 -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -p tcp --dport 53 -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -p udp --sport 67:68 -j ACCEPT
            
            # Allow ICMP & established traffic for cellular network health
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -p icmp -j ACCEPT
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m state --state ESTABLISHED,RELATED -j ACCEPT

            # Allow Android System, Radio/RIL, Telecom, Carrier & Mainline Apex packages (UID 0-10299)
            # Preserves carrier provisioning, network activation & connectivity probes so data can be toggled on/off freely
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 0-10299 -j ACCEPT

            # BLOCK ONLY third-party user apps (UID 10300-99999) from Mobile Data WAN!
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o ccmni+ -j DROP
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o rmnet+ -j DROP
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o v4-rmnet+ -j DROP
            /system/bin/iptables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o pdp+ -j DROP
            
            /system/bin/iptables -w 5 -D OUTPUT -j DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/iptables -w 5 -I OUTPUT 1 -j DEDICATED_ROUTER_OUT 2>/dev/null || true

            # IPv6 filter
            /system/bin/ip6tables -w 5 -N DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/ip6tables -w 5 -F DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o lo -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o ap0 -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o swlan+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o wlan+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o rndis+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o usb+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -o eth+ -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -p udp --dport 53 -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -p tcp --dport 53 -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -p icmpv6 -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 0-10299 -j ACCEPT
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o ccmni+ -j DROP
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o rmnet+ -j DROP
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o v4-rmnet+ -j DROP
            /system/bin/ip6tables -w 5 -A DEDICATED_ROUTER_OUT -m owner --uid-owner 10300-99999 -o pdp+ -j DROP
            /system/bin/ip6tables -w 5 -D OUTPUT -j DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/ip6tables -w 5 -I OUTPUT 1 -j DEDICATED_ROUTER_OUT 2>/dev/null || true

            # Android system power/mobile data persistence
            settings put global mobile_data_always_on 1 2>/dev/null || true

            echo "{\"success\": true, \"dedicated_router\": true, \"message\": \"Dedicated Router Active: Phone apps isolated from internet, 100% data routed to tethering (Network validation preserved)\"}"
        else
            rm -f "$FLAG"
            /system/bin/iptables -w 5 -D OUTPUT -j DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/iptables -w 5 -F DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/iptables -w 5 -X DEDICATED_ROUTER_OUT 2>/dev/null || true

            /system/bin/ip6tables -w 5 -D OUTPUT -j DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/ip6tables -w 5 -F DEDICATED_ROUTER_OUT 2>/dev/null || true
            /system/bin/ip6tables -w 5 -X DEDICATED_ROUTER_OUT 2>/dev/null || true

            echo "{\"success\": true, \"dedicated_router\": false, \"message\": \"Dedicated Router Mode disabled: Phone apps have normal internet access\"}"
        fi
        ;;

    settings_toggle_native_mode)
        ENABLE=$(get_param "enable" "1")
        FLAG="/data/local/virtualap/native_mode.flag"
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            touch "$FLAG"
            /data/local/virtualap/start-ap stop 2>/dev/null || true
            echo "{\"success\": true, \"native_mode\": true, \"message\": \"Module overrides disabled: VirtualAP App can operate 100% independently\"}"
        else
            rm -f "$FLAG"
            echo "{\"success\": true, \"native_mode\": false, \"message\": \"Module enhancements and Web Control Panel re-enabled\"}"
        fi
        ;;

    settings_toggle_pure_passthrough|toggle_pure_passthrough)
        ENABLE=$(get_param "enable" "1")
        SETTINGS_CONF="/data/local/virtualap/settings.conf"
        [ -f "$SETTINGS_CONF" ] && . "$SETTINGS_CONF"
        
        IS_ON="0"
        [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ] && IS_ON="1"
        CFG_PURE_PASSTHROUGH="$IS_ON"
        
        if [ "$IS_ON" = "1" ]; then
            # 1. Forward chain: Direct wire-speed acceptance bypassing ALL Android filter & quota chains
            /system/bin/iptables -w 2 -N PURE_FORWARD 2>/dev/null || /system/bin/iptables -w 2 -F PURE_FORWARD
            /system/bin/iptables -w 2 -A PURE_FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i ap0 -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i rndis+ -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i usb+ -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i eth+ -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i swlan+ -j ACCEPT
            /system/bin/iptables -w 2 -A PURE_FORWARD -i wlan+ -j ACCEPT
            /system/bin/iptables -w 2 -D FORWARD -j PURE_FORWARD 2>/dev/null || true
            /system/bin/iptables -w 2 -I FORWARD 1 -j PURE_FORWARD 2>/dev/null || true

            # 2. Direct cellular modem NAT masquerade at top of POSTROUTING
            /system/bin/iptables -w 2 -t nat -N PURE_NAT 2>/dev/null || /system/bin/iptables -w 2 -t nat -F PURE_NAT
            /system/bin/iptables -w 2 -t nat -A PURE_NAT -o rmnet+ -j MASQUERADE
            /system/bin/iptables -w 2 -t nat -A PURE_NAT -o v4-rmnet+ -j MASQUERADE
            /system/bin/iptables -w 2 -t nat -A PURE_NAT -o ccmni+ -j MASQUERADE
            /system/bin/iptables -w 2 -t nat -A PURE_NAT -o pdp+ -j MASQUERADE
            /system/bin/iptables -w 2 -t nat -D POSTROUTING -j PURE_NAT 2>/dev/null || true
            /system/bin/iptables -w 2 -t nat -I POSTROUTING 1 -j PURE_NAT 2>/dev/null || true

            # 3. IPv6 Forwarding passthrough
            /system/bin/ip6tables -w 2 -N PURE_FORWARD_V6 2>/dev/null || /system/bin/ip6tables -w 2 -F PURE_FORWARD_V6
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -m state --state ESTABLISHED,RELATED -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i ap0 -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i rndis+ -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i usb+ -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i eth+ -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i swlan+ -j ACCEPT
            /system/bin/ip6tables -w 2 -A PURE_FORWARD_V6 -i wlan+ -j ACCEPT
            /system/bin/ip6tables -w 2 -D FORWARD -j PURE_FORWARD_V6 2>/dev/null || true
            /system/bin/ip6tables -w 2 -I FORWARD 1 -j PURE_FORWARD_V6 2>/dev/null || true

            # 4. TCP MSS PMTU clamping
            /system/bin/iptables -w 2 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            /system/bin/iptables -w 2 -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            # 5. Kernel wire-speed forwarding optimizations
            sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
            sysctl -w net.core.netdev_max_backlog=10000 >/dev/null 2>&1 || true
            sysctl -w net.core.somaxconn=4096 >/dev/null 2>&1 || true

            # 6. Ensure carrier DUN checks and entitlement queries don't throttle
            settings put global tether_dun_required 0 2>/dev/null || true
            settings put global tether_entitlement_check_state 0 2>/dev/null || true

            MSG="Pure Direct Passthrough ENABLED: Cellular WAN routed directly to downstream clients without filters or inspection"
        else
            /system/bin/iptables -w 2 -D FORWARD -j PURE_FORWARD 2>/dev/null || true
            /system/bin/iptables -w 2 -F PURE_FORWARD 2>/dev/null || true
            /system/bin/iptables -w 2 -X PURE_FORWARD 2>/dev/null || true

            /system/bin/iptables -w 2 -t nat -D POSTROUTING -j PURE_NAT 2>/dev/null || true
            /system/bin/iptables -w 2 -t nat -F PURE_NAT 2>/dev/null || true
            /system/bin/iptables -w 2 -t nat -X PURE_NAT 2>/dev/null || true

            /system/bin/ip6tables -w 2 -D FORWARD -j PURE_FORWARD_V6 2>/dev/null || true
            /system/bin/ip6tables -w 2 -F PURE_FORWARD_V6 2>/dev/null || true
            /system/bin/ip6tables -w 2 -X PURE_FORWARD_V6 2>/dev/null || true

            MSG="Pure Direct Passthrough disabled: Android netfilter chains restored"
        fi

        # Save to settings.conf
        cat <<EOF > "$SETTINGS_CONF"
CFG_CARRIER_BYPASS="${CFG_CARRIER_BYPASS:-0}"
CFG_TARGET_TTL="${CFG_TARGET_TTL:-64}"
CFG_TTL_BYPASS="${CFG_TTL_BYPASS:-1}"
CFG_DUN_BYPASS="${CFG_DUN_BYPASS:-1}"
CFG_MSS_CLAMP="${CFG_MSS_CLAMP:-1}"
CFG_DNS_PROTECT="${CFG_DNS_PROTECT:-1}"
CFG_IPV6_PROTECT="${CFG_IPV6_PROTECT:-1}"
CFG_BPF_OFFLOAD_DISABLED="${CFG_BPF_OFFLOAD_DISABLED:-1}"
CFG_PROVISIONING_SHIELD="${CFG_PROVISIONING_SHIELD:-1}"
CFG_PURE_PASSTHROUGH="$CFG_PURE_PASSTHROUGH"
EOF
        echo "{\"success\": true, \"pure_passthrough\": $([ "$IS_ON" = "1" ] && echo "true" || echo "false"), \"message\": \"$MSG\"}"
        ;;

    set_upstream)
        MODE=$(get_param "mode" "vap")
        UPSTREAM=$(get_param "upstream" "auto")
        
        # Save to settings.conf
        SETTINGS_CONF="/data/local/virtualap/settings.conf"
        case "$MODE" in
            vap)
                # Update ap.conf for VirtualAP
                if [ -f "$CONF_FILE" ]; then
                    sed -i "s/^UPSTREAM=.*/UPSTREAM='$UPSTREAM'/" "$CONF_FILE" 2>/dev/null
                fi
                echo "{\"success\": true, \"mode\": \"vap\", \"upstream\": \"$UPSTREAM\", \"message\": \"Virtual AP upstream set to $UPSTREAM\"}"
                ;;
            hotspot)
                echo "{\"success\": true, \"mode\": \"hotspot\", \"upstream\": \"$UPSTREAM\", \"message\": \"Mobile Hotspot upstream set to $UPSTREAM\"}"
                ;;
            usb)
                echo "{\"success\": true, \"mode\": \"usb\", \"upstream\": \"$UPSTREAM\", \"message\": \"USB Tethering upstream set to $UPSTREAM\"}"
                ;;
            eth|ethernet)
                echo "{\"success\": true, \"mode\": \"ethernet\", \"upstream\": \"$UPSTREAM\", \"message\": \"Ethernet tethering upstream set to $UPSTREAM\"}"
                ;;
            *)
                echo "{\"success\": true, \"mode\": \"$MODE\", \"upstream\": \"$UPSTREAM\"}"
                ;;
        esac
        ;;

    # =========================================================================
    # TAB 6: DOWNSTREAM NETWORK ADB & ROOT CONTROLLER ENDPOINTS
    # =========================================================================
    adb_status)
        ADB_HELPER="/data/local/virtualap/bin/adb_helper.sh"
        if [ -x "$ADB_HELPER" ]; then
            $ADB_HELPER status
        else
            echo "{\"success\": false, \"error\": \"ADB helper not installed\"}"
        fi
        ;;

    adb_toggle)
        ENABLE=$(get_param "enable" "1")
        PORT=$(get_param "port" "5555")
        ADB_HELPER="/data/local/virtualap/bin/adb_helper.sh"
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            $ADB_HELPER start "$PORT"
            echo "{\"success\": true, \"enabled\": true, \"message\": \"Downstream Network ADB activated on port $PORT\"}"
        else
            $ADB_HELPER stop
            echo "{\"success\": true, \"enabled\": false, \"message\": \"Downstream Network ADB disabled\"}"
        fi
        ;;

    adb_set_port)
        PORT=$(get_param "port" "5555")
        case "$PORT" in
            ''|*[!0-9]*) PORT=5555 ;;
        esac
        [ "$PORT" -lt 1024 ] && PORT=5555
        [ "$PORT" -gt 65535 ] && PORT=5555
        ADB_HELPER="/data/local/virtualap/bin/adb_helper.sh"
        $ADB_HELPER start "$PORT"
        echo "{\"success\": true, \"port\": $PORT, \"message\": \"ADB TCP port updated to $PORT\"}"
        ;;

    adb_toggle_auth)
        ENABLE=$(get_param "enable" "1")
        CONF_FILE="/data/local/virtualap/adb_debug.conf"
        [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            CFG_ADB_AUTO_AUTH="1"
            resetprop ro.adb.secure 0 2>/dev/null || true
            resetprop ro.debuggable 1 2>/dev/null || true
            echo "{\"success\": true, \"auto_auth\": true, \"message\": \"Permissive ADB (ro.adb.secure=0) enabled\"}"
        else
            CFG_ADB_AUTO_AUTH="0"
            resetprop ro.adb.secure 1 2>/dev/null || true
            echo "{\"success\": true, \"auto_auth\": false, \"message\": \"Permissive ADB disabled (standard auth)\"}"
        fi
        sed -i "s/^CFG_ADB_AUTO_AUTH=.*/CFG_ADB_AUTO_AUTH=\"$CFG_ADB_AUTO_AUTH\"/" "$CONF_FILE" 2>/dev/null || \
            echo "CFG_ADB_AUTO_AUTH=\"$CFG_ADB_AUTO_AUTH\"" >> "$CONF_FILE"
        ;;

    adb_toggle_static_ips)
        ENABLE=$(get_param "enable" "1")
        CONF_FILE="/data/local/virtualap/adb_debug.conf"
        [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null
        if [ "$ENABLE" = "1" ] || [ "$ENABLE" = "true" ]; then
            CFG_ADB_STATIC_IPS="1"
            /data/local/virtualap/bin/adb_helper.sh maintain >/dev/null 2>&1 || true
            echo "{\"success\": true, \"static_ips\": true, \"message\": \"Downstream static IP aliases enabled\"}"
        else
            CFG_ADB_STATIC_IPS="0"
            echo "{\"success\": true, \"static_ips\": false, \"message\": \"Downstream static IP aliases disabled\"}"
        fi
        sed -i "s/^CFG_ADB_STATIC_IPS=.*/CFG_ADB_STATIC_IPS=\"$CFG_ADB_STATIC_IPS\"/" "$CONF_FILE" 2>/dev/null || \
            echo "CFG_ADB_STATIC_IPS=\"$CFG_ADB_STATIC_IPS\"" >> "$CONF_FILE"
        ;;

    adb_restart)
        ADB_HELPER="/data/local/virtualap/bin/adb_helper.sh"
        $ADB_HELPER restart
        ;;

    adb_test)
        ADB_HELPER="/data/local/virtualap/bin/adb_helper.sh"
        $ADB_HELPER test
        ;;

    module_check_update)
        CURRENT_VER="v3.2"
        [ -f "/data/adb/modules/virtualap_m326b_fix/module.prop" ] && \
            CURRENT_VER=$(grep "^version=" /data/adb/modules/virtualap_m326b_fix/module.prop | cut -d= -f2 | tr -d '\r\n')
        
        # Query GitHub API via wget/curl
        GH_JSON=""
        if [ -x "/data/adb/magisk/busybox" ]; then
            GH_JSON=$(/data/adb/magisk/busybox wget -q --no-check-certificate -O - "https://api.github.com/repos/vishalhoc/magisk-virtualap-m326b/releases/latest" 2>/dev/null)
        elif which curl >/dev/null 2>&1; then
            GH_JSON=$(curl -s -k --connect-timeout 5 -m 10 "https://api.github.com/repos/vishalhoc/magisk-virtualap-m326b/releases/latest" 2>/dev/null)
        fi
        
        if [ -n "$GH_JSON" ] && echo "$GH_JSON" | grep -q '"tag_name"'; then
            REMOTE_TAG=$(echo "$GH_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n1 | sed -e 's/"tag_name": *"//' -e 's/"//')
            REMOTE_NAME=$(echo "$GH_JSON" | grep -o '"name": *"[^"]*"' | head -n1 | sed -e 's/"name": *"//' -e 's/"//')
            ZIP_URL=$(echo "$GH_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n1 | sed -e 's/"browser_download_url": *"//' -e 's/"//')
            PUB_DATE=$(echo "$GH_JSON" | grep -o '"published_at": *"[^"]*"' | head -n1 | sed -e 's/"published_at": *"//' -e 's/"//')
            
            HAS_UPDATE="false"
            if [ -n "$REMOTE_TAG" ] && [ "$REMOTE_TAG" != "$CURRENT_VER" ]; then
                HAS_UPDATE="true"
            fi
            
            cat <<EOF
{
    "success": true,
    "current_version": "$CURRENT_VER",
    "latest_version": "$REMOTE_TAG",
    "has_update": $HAS_UPDATE,
    "release_title": "$REMOTE_NAME",
    "published_at": "$PUB_DATE",
    "download_url": "$ZIP_URL"
}
EOF
        else
            cat <<EOF
{
    "success": false,
    "current_version": "$CURRENT_VER",
    "error": "Could not fetch GitHub releases. Please verify internet access."
}
EOF
        fi
        ;;

    module_install_update)
        URL=$(get_param "url" "")
        TARGET_ZIP="/data/local/tmp/virtualap_update.zip"
        
        if [ -z "$URL" ]; then
            GH_JSON=""
            if [ -x "/data/adb/magisk/busybox" ]; then
                GH_JSON=$(/data/adb/magisk/busybox wget -q --no-check-certificate -O - "https://api.github.com/repos/vishalhoc/magisk-virtualap-m326b/releases/latest" 2>/dev/null)
            elif which curl >/dev/null 2>&1; then
                GH_JSON=$(curl -s -k --connect-timeout 5 -m 10 "https://api.github.com/repos/vishalhoc/magisk-virtualap-m326b/releases/latest" 2>/dev/null)
            fi
            URL=$(echo "$GH_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n1 | sed -e 's/"browser_download_url": *"//' -e 's/"//')
        fi
        
        if [ -z "$URL" ]; then
            echo "{\"success\": false, \"error\": \"No download URL found for latest release\"}"
            exit 0
        fi
        
        rm -f "$TARGET_ZIP"
        if [ -x "/data/adb/magisk/busybox" ]; then
            /data/adb/magisk/busybox wget -q --no-check-certificate -O "$TARGET_ZIP" "$URL" 2>/dev/null
        else
            curl -L -k --connect-timeout 10 -m 60 -o "$TARGET_ZIP" "$URL" >/dev/null 2>&1
        fi
        
        if [ ! -f "$TARGET_ZIP" ] || [ $(stat -c %s "$TARGET_ZIP" 2>/dev/null || echo 0) -lt 30000 ]; then
            echo "{\"success\": false, \"error\": \"Downloaded file is corrupt or missing (size < 30KB)\"}"
            exit 0
        fi
        
        # Install with magisk
        INSTALL_OUT=$(/data/adb/magisk/magisk --install-module "$TARGET_ZIP" 2>&1)
        INST_EXIT=$?
        
        if [ $INST_EXIT -eq 0 ]; then
            # Sync web directory so UI reflects updates immediately
            if [ -d "/data/adb/modules/virtualap_m326b_fix/web" ]; then
                cp -rf /data/adb/modules/virtualap_m326b_fix/web/* /data/local/virtualap/web/ 2>/dev/null
                chmod 755 /data/local/virtualap/web/cgi-bin/* 2>/dev/null
            fi
            ESCAPED_LOG=$(echo "$INSTALL_OUT" | tr '\n' ' ' | sed 's/"/\\"/g')
            echo "{\"success\": true, \"message\": \"Magisk module updated successfully!\", \"log\": \"$ESCAPED_LOG\"}"
        else
            ESCAPED_LOG=$(echo "$INSTALL_OUT" | tr '\n' ' ' | sed 's/"/\\"/g')
            echo "{\"success\": false, \"error\": \"Magisk installation returned error code $INST_EXIT\", \"log\": \"$ESCAPED_LOG\"}"
        fi
        ;;

    *)
        echo "{\"error\": \"Unknown action: $ACTION\"}"
        ;;
esac
