### 🌟 VirtualAP Fix & Connectivity Hub v3.2 (Created by hoc)

A complete systemless Magisk module created by **hoc** providing concurrent **Virtual AP (`ap0`)**, **Unified Downstream Network ADB Controller (192.168.42.1:5555)**, **Pure Direct Modem Passthrough (Filterless Wire-Speed WAN)**, **Multi-Vector Hotspot Detection Engine**, **Modular Carrier Hotspot Anti-Detection Suite**, **1-Click In-App GitHub Module Updater**, and multi-interface connectivity management with an integrated Web Control Panel on port 8088 for Samsung Galaxy M32 5G (`SM-M326B`, MediaTek Dimensity 720 / MT6853).

---

### ⚡ What's New in v3.2

#### 1. 🎯 Unified ADB Address & Port Across ALL Downstream Interfaces (`192.168.42.1:5555`)
- **Single Standardized Endpoint**: Eliminated confusing fragmented static IPs (`192.168.42.1` for ap0, `192.168.44.1` for rndis0, `192.168.45.1` for eth0, `192.168.43.1` for swlan0). 
- Every downstream connection (Virtual AP `ap0`, USB Tethering `rndis0`/`usb0`, USB Ethernet `eth0`, and Mobile Hotspot `swlan0`/`wlan0`) now universally standardizes on **`192.168.42.1:5555`**.
- Seamless 1-click connect command across all adapters:
  ```bash
  adb connect 192.168.42.1:5555
  ```
- **Dual-Path Reachability**: Clients can connect via the unified address `192.168.42.1:5555` or via the interface's native gateway IP on port 5555. Both route seamlessly to the local Android `adbd` listener.

#### 2. 🚀 Resolved Downstream Internet Speed Degradation When ADB is Enabled
- **Eliminated Subnet Collisions**: Removed disruptive per-interface `/24` subnet injections (`ip addr add $USB_IP/24 dev rndis0`) which were fighting with Android's native `netd` tethering DHCP subnets.
- Bound `192.168.42.1/32` directly to loopback (`lo`) accompanied by high-speed PREROUTING `REDIRECT --to-ports 5555`. This creates **zero route conflicts, zero ARP collisions, and zero packet loops**.
- **Cached Netfilter Locks**: Optimized watchdog maintenance in `service.sh` and `adb_helper.sh` to prevent high-frequency `iptables -w 2` lock contention every 10 seconds, eliminating kernel packet forwarding micro-stalls.

#### 3. ⚡ Pure Direct Modem Passthrough (Filterless Wire-Speed Internet)
- Dedicated toggle and engine that bridges cellular modem WAN (`rmnet+`, `v4-rmnet+`, `ccmni+`, `pdp+`) directly to downstream tethering clients (`ap0`, `rndis+`, `usb+`, `eth+`, `swlan+`, `wlan+`) with **zero intermediate filters**:
  - **Rule #1 FORWARD Bypass**: Installs `PURE_FORWARD` at Rule #1 of the `FORWARD` chain, instantly accepting downstream packets and return traffic before they ever touch `bw_FORWARD`, `tetherctrl_FORWARD`, quota policing, or Doze firewall chains.
  - **Direct Top-Priority NAT Masquerade**: Installs `PURE_NAT` at Rule #1 of `nat` `POSTROUTING` directly to cellular WAN interfaces.
  - **PMTU TCP MSS Auto-Clamping**: Automatically clamps TCP SYN MSS to prevent MTU mismatches and cellular packet fragmentation.
  - **Kernel Wire-Speed Forwarding**: Sets `net.ipv4.ip_forward=1`, `net.ipv4.conf.all.rp_filter=0`, and maximizes `netdev_max_backlog` to 10,000 packets.
  - **Zero DPI / Zero Carrier Inspection**: Unconstrained raw throughput directly from modem to PC.
- Dedicated Web Control Panel switch and live status badge: **`ACTIVE (FILTERLESS)`** in Tab 5 (Settings & Bypass).

#### 4. 🏷️ Attribution & Compatibility
- Author strictly preserved as **hoc** (`author=hoc`).
- 100% systemless, non-destructive, zero NVRAM risk.
- Compatible with Magisk v24.0+ on Samsung Galaxy M32 5G (Android 11, 12, and 13 OneUI).
