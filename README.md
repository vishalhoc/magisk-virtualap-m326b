# VirtualAP Fix & Web Control Panel (Samsung Galaxy M32 5G / Dimensity 720)

[![Magisk](https://img.shields.io/badge/Magisk-v24.0+-brightgreen.svg)](https://github.com/topjohnwu/Magisk)
[![SoC](https://img.shields.io/badge/MediaTek-MT6853%20Dimensity%20720-blue.svg)](https://www.mediatek.com)
[![Version](https://img.shields.io/badge/Version-v2.8-orange.svg)](#version-28-features)
[![WebUI](https://img.shields.io/badge/Control%20Panel-Web%20CGI%20Portal-red.svg)](#web-control-panel)

A complete systemless Magisk module providing concurrent **Virtual AP (`ap0`)**, **Carrier Hotspot Detection Bypass**, **Dedicated Router Mode**, and multi-interface connectivity management with an integrated Web Control Panel for Samsung Galaxy M32 5G (`SM-M326B`, MediaTek Dimensity 720 / MT6853).

---

## 🌟 What's New in v2.8

### 🔧 Hostapd & MediaTek nl80211 AP Initialization Fix
- **Driver Capability Check Patch:** Fixed the fatal `nl80211: Driver does not support authentication/association or connect commands` -> `nl80211 driver initialization failed` error by binary-patching the client-mode capability validation branch in `hostapd_patched` (`0x4623e4` / `0x4623fc`).
- **Dynamic Interface Lifecycle Management:** On Dimensity 720 / MT6853, the kernel Wi-Fi driver statically allocates the AP interface `swlan0` with a hard limit of 3 concurrent interfaces (`wlan0`, `p2p0`, `swlan0`). The enhanced `iw` wrapper dynamically links `swlan0` to `ap0` and prevents teardown deletion from destroying the netdev, ensuring 100% reliable subsequent starts.
- **Native App Integration:** Fully compatible with the unmodified stock `com.virtualap.app` on Android 13 OneUI. Tapping "Start Access Point" in the app UI boots into `RUNNING` without channel, band, or driver errors on both 2.4GHz and 5GHz.

---

## 🌟 Core Features

### 🛡️ Universal Carrier Hotspot Detection Bypass
Prevents mobile network operators from detecting that tethering/hotspot is active. Works across **all 4 tethering modes**:
- **Native Wi-Fi Hotspot** (`swlan0`)
- **Virtual AP** (`ap0`)
- **USB Tethering** (`rndis0` / `usb0`)
- **Ethernet Tethering** (`eth0`)

**Bypass Mechanism:**
1. **DUN & Entitlement Stripping:** Clears `tether_dun_required=0`, wipes DUN APN, sets `tether_entitlement_check_state=0`, and enables `net.tethering.noprovisioning=true` to route all tethering via normal unlimited cellular data.
2. **TCP MSS Clamping to PMTU:** Clamps TCP MSS on all forwarded packets (`iptables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`) to eliminate desktop TCP window/fingerprint detection.
3. **DNS Leak & DPI Cloaking:** Redirects tether client DNS lookups to encrypted/neutral `1.1.1.1:53`, preventing carrier DNS inspection of desktop domains (Windows Update, Steam, Apple telemetry).
4. **IPv6 EUI-64 Shield:** Drops IPv6 forward leaks (`ip6tables -I FORWARD -j DROP`), forcing all clients through clean IPv4 NAT to hide connected device hardware MAC addresses.
5. **Hop Limit / TTL Baseline:** Sets sysctl default hop limit/TTL to `64`.

---

### 🚀 Dedicated Router Mode (100% Cellular WAN to Tethering)
- **Blocks all on-device Android apps** from accessing cellular mobile data WAN (`ccmni+` MTK modem, `rmnet+`, `v4-rmnet+`, `pdp+`).
- Eliminates background app updates, Google Play downloads, and system telemetry on the phone from consuming data or increasing ping latency.
- Keeps loopback (`lo`), local management WebUI (`http://127.0.0.1:8088`), and the `FORWARD` chain **100% open at full 5G speed** for connected laptops, PCs, and gaming consoles.

---

### 📱 Standalone Native App Mode
- Provides an option directly on **Tab 1 (Virtual AP)** and **Tab 5 (Settings)** to completely disable module background hooks (`maintain_ap0` daemon and `iw` wrapper interception).
- Allows the standalone `com.virtualap.app` to function 100% independently without module intervention.
- Web Control Panel remains live on port `8088` so optimizations can be re-enabled at any time.

---

### 📡 5-Tab Web Control Panel
- Accessible at **`http://localhost:8088`** on phone or **`http://192.168.42.1:8088`** from connected client devices.
- **Top Header:** ⚙️ Quick Settings shortcut button and instant Refresh.
- **Tab 1 — Virtual AP (`ap0`):** Start/stop AP, configure SSID, password, band (2.4/5GHz), channel, width, security, upstream routing, and live connected clients.
- **Tab 2 — Mobile Hotspot:** Configure native Android SoftAP, DUN bypass, IP forwarding, and BPF hardware offload.
- **Tab 3 — USB Tethering:** Enable/disable RNDIS or CDC-NCM gadget protocols, tune MTU, and monitor live throughput.
- **Tab 4 — Ethernet:** Auto-detect USB-to-Ethernet adapters, configure static/DHCP client mode, or share 5G mobile data over LAN cable.
- **Tab 5 — Settings & Bypass:** Master Carrier Bypass switch, Dedicated Router Mode switch, TTL tuning, and carrier detection breakdown guide.

---

## 📁 Repository Structure
```text
├── files/
│   ├── hostapd_patched     # Patched hostapd binary for MT6853 nl80211 AP mode
│   ├── iw                  # Wrapper script with MTK driver wake, ap0 linking & native bypass
│   ├── iw.real             # Static real iw binary
│   ├── start-ap            # Core AP lifecycle management daemon
│   ├── test_5g.conf        # 5GHz 20/40MHz hostapd configuration
│   ├── test_5g_80m.conf    # 5GHz 80MHz VHT configuration
│   └── test_ap0.conf       # 2.4GHz standard configuration
├── web/
│   ├── index.html          # 5-Tab Cyber Dark Web Dashboard with Settings Portal
│   └── cgi-bin/api.sh      # Shell-based CGI API handler with settings endpoints
├── webroot/                # Mirrored web assets
├── service.sh              # Boot daemon & persistent background service
├── customize.sh            # Magisk installer script
├── action.sh               # Magisk Action button handler
└── module.prop             # Module metadata (v2.8)
```

---

## 📦 Installation

1. Download **`virtualap_m326b_fix_v2.8.zip`** from [Releases](https://github.com/vishalhoc/magisk-virtualap-m326b/releases).
2. Flash via **Magisk Manager** or **KernelSU**.
3. Reboot your device.
4. Tap the **Action** button on the module in Magisk or open `http://localhost:8088` in your browser.

---

## 📜 License
MIT License.
