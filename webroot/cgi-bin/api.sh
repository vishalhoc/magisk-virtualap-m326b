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
        IP_GW="${PREF_GW:-${IP_GW:-192.168.233.218}}"
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
    "autostart": $AUTOSTART_VAL
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

        # Upstream candidates
        UP_LIST="{\"name\":\"auto\",\"label\":\"auto (Default Route / 464XLAT / Mobile Data)\"}"
        
        # Cellular CLAT IPv4
        if [ -d "/sys/class/net/v4-rmnet0" ]; then
            ip_v4=$(/system/bin/ip -4 -o addr show dev v4-rmnet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"v4-rmnet0\",\"label\":\"v4-rmnet0 (Mobile Data IPv4: ${ip_v4:-active})\"}"
        fi

        # Direct Cellular
        if [ -d "/sys/class/net/rmnet0" ]; then
            UP_LIST="$UP_LIST,{\"name\":\"rmnet0\",\"label\":\"rmnet0 (Cellular direct)\"}"
        fi

        # Wi-Fi STA
        if [ -d "/sys/class/net/wlan0" ]; then
            ip_wlan=$(/system/bin/ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"wlan0\",\"label\":\"wlan0 (Wi-Fi STA: ${ip_wlan:-active})\"}"
        fi

        # USB Ethernet adapters & Tethering
        for eth in /sys/class/net/eth* /sys/class/net/usb* /sys/class/net/rndis*; do
            [ ! -d "$eth" ] && continue
            ename="${eth##*/}"
            eip=$(/system/bin/ip -4 -o addr show dev "$ename" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            UP_LIST="$UP_LIST,{\"name\":\"$ename\",\"label\":\"$ename (Ethernet/USB: ${eip:-connected})\"}"
        done

        cat <<EOF
{
    "phy_interfaces": [$PHY_LIST],
    "ap_modes": ["ap0"],
    "upstream_interfaces": [$UP_LIST]
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
        P_WIDTH=$(get_param "width" "20")
        P_GW=$(get_param "gateway" "192.168.233.218")
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
        # Check active status
        HS_ACTIVE="false"
        if ip link show swlan0 2>/dev/null | grep -q "UP"; then
            HS_ACTIVE="true"
        elif dumpsys wifi 2>/dev/null | grep -q "mRole: ROLE_SOFTAP_TETHERED"; then
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

        # Hotspot client devices
        HS_CLIENTS=""
        while read -r ip hw_type flags mac mask dev; do
            [ "$dev" != "swlan0" ] && continue
            [ "$flags" != "0x2" ] && continue
            [ -n "$HS_CLIENTS" ] && HS_CLIENTS="$HS_CLIENTS,"
            HS_CLIENTS="$HS_CLIENTS{\"ip\":\"$ip\",\"mac\":\"$mac\"}"
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

    *)
        echo "{\"error\": \"Unknown action: $ACTION\"}"
        ;;
esac
