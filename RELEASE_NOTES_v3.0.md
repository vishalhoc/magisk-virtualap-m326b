### 🌟 VirtualAP Fix & Connectivity Hub v3.0 (Created by hoc)

A complete systemless Magisk module created by **hoc** providing concurrent **Virtual AP (`ap0`)**, **Downstream Network ADB & Root Controller**, **Carrier Hotspot Detection Bypass**, **Dedicated Router Mode**, and multi-interface connectivity management with an integrated Web Control Panel for Samsung Galaxy M32 5G (`SM-M326B`, MediaTek Dimensity 720 / MT6853).

---

### ⚡ What's New in v3.0

- **⚡ Auto-Enable Downstream ADB Across All Interfaces**:
  - Seamlessly activates TCP/IP ADB debugging across all downstream interfaces:
    - **Virtual AP (`ap0`)**
    - **USB Tethering (`rndis0` / `usb0` / `ncm0`)**
    - **USB Ethernet (`eth0`)**
    - **Mobile Hotspot (`wlan0` / `swlan0`)**
- **🛡️ Higher-Level Debugging Just Like Physical USB**:
  - Sets permissive authentication (`ro.adb.secure=0`) and developer flags (`ro.debuggable=1`), completely eliminating RSA key authorization prompts on downstream interfaces.
  - Magisk superuser integration enables elevated root shell access (`adb shell su`) over network debugging.
- **📌 Persistent Static IP & TCP Port Stack**:
  - Downstream network gateways configured with static IP addresses (`ap0`: `192.168.42.1`, USB: `192.168.44.1`, Ethernet: `192.168.45.1`, Hotspot: `192.168.43.1`).
  - Persistent TCP port configuration (default `5555`).
- **🌐 Web Control Panel - Downstream ADB & Root Tab**:
  - Dedicated interactive tab with live endpoint status cards, link state badges, and **1-Click Copy** connection buttons (`adb connect <IP>:<PORT>`).
  - ADB service controls (Restart ADB, Toggle Permissive Auth, Static IP toggle, Custom Port setter).
  - Built-in root shell cheatsheet.
- **🔄 Watchdog Daemon**:
  - Continuous 10-second background watchdog in `service.sh` automatically restores the `adbd` listener and iptables firewall rules across Android framework restarts or network reconnects.
- **🏷️ Attribution**:
  - Created by **hoc** (`author=hoc`).
