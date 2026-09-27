# VirtualAP Fix & Web Control Panel (Samsung Galaxy M32 5G / Dimensity 720)

[![Magisk](https://img.shields.io/badge/Magisk-v24.0+-brightgreen.svg)](https://github.com/topjohnwu/Magisk)
[![SoC](https://img.shields.io/badge/MediaTek-MT6853%20Dimensity%20720-blue.svg)](https://www.mediatek.com)
[![WebUI](https://img.shields.io/badge/Control%20Panel-Web%20CGI%20Portal-red.svg)](#web-control-panel)

A complete systemless Magisk module providing concurrent **Virtual AP (Dual Wi-Fi hotspot)** and Wi-Fi STA+AP repeater capabilities with an integrated Web Management Control Panel for Samsung Galaxy M32 5G (`SM-M326B`, MediaTek Dimensity 720 / MT6853).

---

## 🌟 Features

- **Concurrent Dual AP / Wi-Fi Repeater**: Creates secondary virtual Wi-Fi interfaces (`ap0`, `ap1`) simultaneously alongside an active client Wi-Fi connection (`wlan0`).
- **Patched `hostapd`**: Custom binary patched specifically for MT6853 driver capability checks, preventing `NL80211_CMD_START_AP` permission denials.
- **464XLAT Mobile Data Route Fix**: Automatically detects and handles IPv4/IPv6 CLAT (`v4-rmnet_data*` / `v4-ccmni*`) interfaces, ensuring clients connected to the virtual AP have full Internet access even on pure IPv6 mobile networks.
- **Built-in Web Control Panel**:
  - Web UI accessible at `http://127.0.0.1:8080` (or phone IP).
  - One-click Start/Stop of Virtual AP.
  - Uplink interface selector (`wlan0`, `rmnet_data0`, `ccmni0`, `eth0`).
  - Real-time client list, bandwidth counters, and logs.
- **Action Button Support**: Trigger or open the control panel directly from Magisk's module manager.

---

## 📁 Repository Structure
```text
├── files/
│   ├── hostapd_patched     # Patched hostapd binary for MT6853
│   ├── start-ap            # Core AP lifecycle management daemon
│   ├── test_5g.conf        # 5GHz 20/40MHz hostapd configuration
│   ├── test_5g_80m.conf    # 5GHz 80MHz VHT configuration
│   └── test_ap0.conf       # 2.4GHz standard configuration
├── webroot/
│   ├── index.html          # Clean mobile-responsive web dashboard
│   └── cgi-bin/api.sh      # Shell-based CGI API handler
├── service.sh              # Boot daemon & persistent background service
├── customize.sh            # Magisk installer script
└── module.prop             # Module metadata
```

---

## 📦 Installation

1. Download `virtualap_m326b_fix.zip` from Releases.
2. Flash via **Magisk Manager** or **KernelSU**.
3. Reboot your device.
4. Tap the **Action** button on the module or browse to `http://localhost:8080` in Chrome/Samsung Internet.

---

## 📜 License
MIT License.
