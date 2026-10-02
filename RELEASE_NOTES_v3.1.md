### 🌟 VirtualAP Fix & Connectivity Hub v3.1 (Created by hoc)

A complete systemless Magisk module created by **hoc** providing concurrent **Virtual AP (`ap0`)**, **Multi-Vector Hotspot Detection Engine**, **Modular Carrier Hotspot Anti-Detection Suite**, **1-Click In-App GitHub Module Updater**, **Downstream Network ADB & Root Controller**, **Dedicated Router Mode**, and multi-interface connectivity management with an integrated Web Control Panel on port 8088 for Samsung Galaxy M32 5G (`SM-M326B`, MediaTek Dimensity 720 / MT6853).

---

### ⚡ What's New in v3.1

#### 1. 📡 Multi-Vector Advanced Hotspot Detection Engine
- Upgraded hotspot detection beyond single-interface checks to a 4-vector simultaneous telemetry engine:
  - **Vector 1: Kernel Link State**: Real-time interface operstate & UP flags across `swlan0`, `wlan1`, `ap0`, and `wlan0`.
  - **Vector 2: Android Wi-Fi Framework Role**: Detects `ROLE_SOFTAP_TETHERED`, `TetheredState`, and `SoftApState{state=13}` (WIFI_AP_STATE_ENABLED).
  - **Vector 3: TetheringManager Service**: Verifies active interfaces registered in Android's central tethering registry.
  - **Vector 4: Hostapd Daemon State**: Tracks live process ID of the MediaTek hostapd daemon.
- Live client scanner parsing multi-interface ARP tables and neighbor discovery.

#### 2. 🛡️ Modular Carrier Hotspot Anti-Detection Suite (Individual Toggle Controls)
Every single anti-detection method now features its **own dedicated Enable/Disable toggle switch**:
- **Vector 1: IP TTL / Hop Limit Cloak (Mangle & Sysctl)**: Masks decrementing hop count on tethered client packets with customizable TTL (default 64) and POSTROUTING mangle rules.
- **Vector 2: Dedicated DUN APN & Entitlement Bypass**: Clears `tether_dun_required` (0) and disables entitlement check queries.
- **Vector 3: TCP MSS Clamping to PMTU**: Clamps TCP SYN packet sizes to mobile MTU boundaries, defeating OS-level TCP fingerprinting.
- **Vector 4: DNS Leak & DPI Cloaking**: Redirects port 53 DNS queries to neutral Cloudflare `1.1.1.1`, defeating carrier domain inspection.
- **Vector 5: IPv6 EUI-64 Leak Shield**: Drops unmasked global IPv6 forwarding containing PC MAC addresses.
- **Vector 6: BPF Hardware Tether Offload Disable**: Disables `tether_offload_disabled=1` so 100% of tethered traffic is forced through Netfilter/iptables.
- **Vector 7: Platform Tether Provisioning Shield**: Enforces `net.tethering.noprovisioning=true` at the system property level.
- **⚡ Master Carrier Bypass**: Global 1-click toggle to control all anti-detection vectors simultaneously.

#### 3. 📦 1-Click Magisk Module Updater (GitHub Releases)
- **Direct GitHub Releases Integration**: Queries `vishalhoc/magisk-virtualap-m326b` for new releases.
- **In-App Download & Install**: Downloads the latest zip asset directly to device and executes `magisk --install-module` in real-time.
- **Live Terminal Log Console**: Displays real-time download and Magisk installation output inside the Web Control Panel.
- **Native Magisk App Channel**: Integrated `updateJson` in `module.prop` for native update badges in Magisk Manager.

#### 4. 🏷️ Attribution & Compatibility
- Author strictly preserved as **hoc** (`author=hoc`).
- 100% systemless, non-destructive, zero NVRAM risk.
