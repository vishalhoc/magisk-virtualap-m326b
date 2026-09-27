#!/system/bin/sh
echo "========================================="
echo "   VirtualAP Web Control Panel"
echo "========================================="

# Ensure WebUI HTTP server is running
if ! pgrep -f "httpd.*8088" >/dev/null 2>&1; then
    mkdir -p /data/local/virtualap/web/cgi-bin
    [ -d "/data/adb/modules/virtualap_m326b_fix/web" ] && cp -rf /data/adb/modules/virtualap_m326b_fix/web/* /data/local/virtualap/web/ 2>/dev/null
    chmod 755 /data/local/virtualap/web/cgi-bin/* 2>/dev/null
    /data/adb/magisk/busybox httpd -p 0.0.0.0:8088 -h /data/local/virtualap/web
    echo "[✓] Web server started on port 8088"
else
    echo "[✓] Web server already active on port 8088"
fi

echo "Launching Web Control Panel in browser..."
am start -a android.intent.action.VIEW -d "http://127.0.0.1:8088" >/dev/null 2>&1

echo ""
echo "Control Panel URL: http://localhost:8088"
echo "From other devices: http://192.168.233.218:8088"
echo "========================================="
