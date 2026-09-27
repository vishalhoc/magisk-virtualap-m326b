#!/system/bin/sh
# VirtualAP WebUI CGI Backend API - High Performance & Accurate
printf "Content-Type: application/json\r\n"
printf "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
printf "Pragma: no-cache\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
printf "Access-Control-Allow-Headers: Content-Type\r\n\r\n"

START_AP="/data/data/com.virtualap.app/files/backend/start-ap"
[ ! -f "$START_AP" ] && START_AP="/data/local/virtualap/start-ap"
[ ! -f "$START_AP" ] && START_AP="/data/local/tmp/start-ap"

CONF_FILE="/data/local/virtualap/ap.conf"
STATE_FILE="/data/local/virtualap/run.state"
RUN_DIR="/data/local/virtualap/run"
LOG_DIR="/data/local/virtualap/logs"

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

case "$ACTION" in
    status)
        # Defaults
        running=0
        hostapd="dead"
        dnsmasq="dead"
        clients=0
        width="20"
        security="wpa2"
        upstream="auto"
        upstream_table=""
        upstream_iface=""
        band="5"
        channel="44"
        ssid="hoc"
        gateway="192.168.233.218"
        dns_servers="1.1.1.1"
        started=""
        PHY_IFACE="wlan0"
        AP_IFACE="ap0"
        PASSWORD=""

        # 1. Load saved ap.conf
        if [ -f "$CONF_FILE" ]; then
            . "$CONF_FILE" 2>/dev/null
        fi

        # 2. Query live status from start-ap engine
        if [ -f "$START_AP" ]; then
            eval "$("$START_AP" status 2>/dev/null)"
        fi

        # 3. Double-check live process state
        IS_RUNNING="false"
        if [ "$running" = "1" ] || ([ -f "$RUN_DIR/hostapd.pid" ] && kill -0 "$(cat "$RUN_DIR/hostapd.pid" 2>/dev/null)" 2>/dev/null); then
            IS_RUNNING="true"
            running=1
        fi

        # 4. Count active ARP entries on AP interface
        active_arp=$(awk -v dev="${AP_IFACE:-ap0}" '$6==dev && $3=="0x2"{c++} END{print c+0}' /proc/net/arp 2>/dev/null)
        if [ "$active_arp" -gt 0 ] 2>/dev/null; then
            clients=$active_arp
        elif [ -f "$RUN_DIR/dnsmasq.leases" ]; then
            lease_cnt=$(wc -l < "$RUN_DIR/dnsmasq.leases" 2>/dev/null || echo 0)
            [ "$lease_cnt" -gt 0 ] && clients=$lease_cnt
        fi

        cat <<EOF
{
    "running": $IS_RUNNING,
    "ssid": "${ssid:-$SSID}",
    "password": "${PASSWORD:-1234567890}",
    "band": "${band:-${BAND:-5}}",
    "channel": "${channel:-${CHANNEL:-44}}",
    "width": "${width:-${WIDTH:-20}}",
    "gateway": "${gateway:-${IP_GW:-192.168.233.218}}",
    "upstream": "${upstream:-${UPSTREAM:-auto}}",
    "upstream_table": "${upstream_table:-}",
    "upstream_iface": "${upstream_iface:-}",
    "phy_iface": "${PHY_IFACE:-wlan0}",
    "ap_iface": "${AP_IFACE:-ap0}",
    "security": "${security:-${SECURITY:-wpa2}}",
    "clients": $clients,
    "started": "${started:-}",
    "hostapd": "${hostapd:-dead}",
    "dnsmasq": "${dnsmasq:-dead}"
}
EOF
        ;;

    interfaces)
        # Scan physical Wi-Fi radios (wlan0, wlan1)
        PHY_LIST=""
        for d in /sys/class/net/*; do
            name="${d##*/}"
            case "$name" in
                wlan0|wlan1|wlan2)
                    [ -n "$PHY_LIST" ] && PHY_LIST="$PHY_LIST,"
                    PHY_LIST="$PHY_LIST\"$name\""
                    ;;
                *)
                    if [ -d "$d/phy80211" ] && [ "$name" != "ap0" ] && [ "$name" != "swlan0" ] && [ "$name" != "p2p0" ]; then
                        [ -n "$PHY_LIST" ] && PHY_LIST="$PHY_LIST,"
                        PHY_LIST="$PHY_LIST\"$name\""
                    fi
                    ;;
            esac
        done
        [ -z "$PHY_LIST" ] && PHY_LIST="\"wlan0\""

        # Upstream candidates: show auto, active IP interfaces, and key network adapters
        UP_LIST="{\"name\":\"auto\",\"label\":\"auto (Recommended: 464XLAT / Wi-Fi)\"}"
        
        # Check active cellular CLAT interface
        if [ -d "/sys/class/net/v4-rmnet0" ]; then
            ip_v4=$(/system/bin/ip -4 -o addr show dev v4-rmnet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"v4-rmnet0\",\"label\":\"v4-rmnet0 (Mobile Data IPv4: ${ip_v4:-active})\"}"
        fi

        # Check raw cellular interface
        if [ -d "/sys/class/net/rmnet0" ]; then
            UP_LIST="$UP_LIST,{\"name\":\"rmnet0\",\"label\":\"rmnet0 (Cellular direct)\"}"
        fi

        # Check Wi-Fi STA
        if [ -d "/sys/class/net/wlan0" ]; then
            ip_wlan=$(/system/bin/ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"wlan0\",\"label\":\"wlan0 (Wi-Fi STA: ${ip_wlan:-disconnected})\"}"
        fi

        # Check USB Ethernet adapters
        for eth in /sys/class/net/eth* /sys/class/net/usb*; do
            [ ! -d "$eth" ] && continue
            ename="${eth##*/}"
            eip=$(/system/bin/ip -4 -o addr show dev "$ename" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"$ename\",\"label\":\"$ename (Ethernet: ${eip:-no-ip})\"}"
        done

        cat <<EOF
{
    "phy_interfaces": [$PHY_LIST],
    "ap_modes": ["ap0", "swlan0"],
    "upstream_interfaces": [$UP_LIST]
}
EOF
        ;;

    clients)
        # Query active ARP clients on the AP interface
        AP_DEV="ap0"
        [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null

        CLIENT_JSON=""
        # Read ARP table
        while read -r ip hw_type flags mac mask dev; do
            [ "$dev" != "$AP_DEV" ] && [ "$dev" != "ap0" ] && [ "$dev" != "swlan0" ] && continue
            [ "$flags" != "0x2" ] && continue
            
            # Lookup hostname in dnsmasq.leases
            hname="unknown"
            if [ -f "$RUN_DIR/dnsmasq.leases" ]; then
                found=$(grep -i "$mac" "$RUN_DIR/dnsmasq.leases" 2>/dev/null | awk '{print $4}' | head -n1)
                [ -n "$found" ] && [ "$found" != "*" ] && hname="$found"
            fi

            [ -n "$CLIENT_JSON" ] && CLIENT_JSON="$CLIENT_JSON,"
            CLIENT_JSON="$CLIENT_JSON{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hname\",\"active\":true}"
        done < /proc/net/arp

        # If ARP was empty, fall back to leases
        if [ -z "$CLIENT_JSON" ] && [ -f "$RUN_DIR/dnsmasq.leases" ]; then
            while read -r exp mac ip hname cid; do
                [ -z "$mac" ] && continue
                [ -n "$CLIENT_JSON" ] && CLIENT_JSON="$CLIENT_JSON,"
                CLIENT_JSON="$CLIENT_JSON{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"${hname:-unknown}\",\"active\":false}"
            done < "$RUN_DIR/dnsmasq.leases"
        fi

        echo "{\"clients\": [$CLIENT_JSON]}"
        ;;

    start)
        DATA="${POST_DATA:-$QUERY_STRING}"
        P_SSID=""; P_PASS=""; P_PHY="wlan0"; P_AP="ap0"; P_UPSTREAM="auto"
        P_BAND="5"; P_CHAN=""; P_WIDTH="20"; P_GW="192.168.233.218"; P_DNS="1.1.1.1"

        for param in $(echo "$DATA" | tr '&' ' '); do
            k="${param%%=*}"; v=$(urldecode "${param#*=}")
            case "$k" in
                ssid) P_SSID="$v" ;;
                password) P_PASS="$v" ;;
                phy_iface) P_PHY="$v" ;;
                ap_iface) P_AP="$v" ;;
                upstream) P_UPSTREAM="$v" ;;
                band) P_BAND="$v" ;;
                channel) P_CHAN="$v" ;;
                width) P_WIDTH="$v" ;;
                gateway) P_GW="$v" ;;
                dns) P_DNS="$v" ;;
            esac
        done

        # Stop existing instance
        sh "$START_AP" stop >/dev/null 2>&1
        sleep 1

        # Save configuration
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
HIDDEN='0'
SECURITY='wpa2'
PMF='0'
CONTAINER=''
EOF

        # Assemble CLI launch command
        ARGS="-w $P_PHY -o $P_UPSTREAM -b $P_BAND -g $P_GW -d $P_DNS"
        [ -n "$P_SSID" ] && ARGS="$ARGS -s '$P_SSID'"
        [ -n "$P_PASS" ] && ARGS="$ARGS -p '$P_PASS'"
        [ -n "$P_CHAN" ] && ARGS="$ARGS -c $P_CHAN"
        [ -n "$P_WIDTH" ] && ARGS="$ARGS -W $P_WIDTH"

        eval "sh \"$START_AP\" start $ARGS" > /data/local/virtualap/logs/web_start.log 2>&1 &
        sleep 2

        # Check if started
        IS_RUNNING="false"
        if [ -f "$RUN_DIR/hostapd.pid" ] && kill -0 "$(cat "$RUN_DIR/hostapd.pid" 2>/dev/null)" 2>/dev/null; then
            IS_RUNNING="true"
        fi

        echo "{\"success\": true, \"running\": $IS_RUNNING, \"message\": \"VirtualAP started\"}"
        ;;

    stop)
        sh "$START_AP" stop > /data/local/virtualap/logs/web_stop.log 2>&1
        sleep 1
        echo "{\"success\": true, \"running\": false, \"message\": \"VirtualAP stopped\"}"
        ;;

    logs)
        LOG_HOSTAPD=$(tail -n 25 "$LOG_DIR/hostapd.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        LOG_DNSMASQ=$(tail -n 25 "$LOG_DIR/dnsmasq.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        LOG_START=$(tail -n 25 "$LOG_DIR/web_start.log" 2>/dev/null | tr '\n' '\f' | sed 's/"/\\"/g' | tr '\f' '\n' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        cat <<EOF
{
    "hostapd": "$LOG_HOSTAPD",
    "dnsmasq": "$LOG_DNSMASQ",
    "system": "$LOG_START"
}
EOF
        ;;

    *)
        echo "{\"error\": \"Unknown action\"}"
        ;;
esac
