# OpenWrt Complete Configuration Guide

A comprehensive guide for configuring OpenWrt routers from scratch, specifically tailored for Dual-WAN setups (WAN + WANB), IPv6 support, MWAN3 Failover/PBR, and automated Firewall IPSet management.

## Table of Contents

- [Part 1: Initial Network Configuration](#part-1-initial-network-configuration)
  - [Interfaces (IPv4 & IPv6)](#1-interfaces-etcconfignetwork)
  - [DHCP & DNS](#2-dhcp--dns-etcconfigdhcp)
  - [Firewall Zones](#3-firewall-zones-etcconfigfirewall)
  - [Applying Changes & No-IPv4 Fix](#4-applying-changes--the-no-ipv4-fix)
- [Part 2: Firewall IPSet Management](#part-2-firewall-ipset-management)
- [Part 3: Multi-WAN & Routing Logic (MWAN3)](#part-3-multi-wan--routing-logic-mwan3)
- [Part 4: IPSet Updater Script](#part-4-ipset-updater-script)
- [Troubleshooting](#troubleshooting)

---

## Part 1: Initial Network Configuration

This section covers setting up the router from a fresh state to handle a Dual-WAN environment:

- **Router LAN IP:** `192.168.20.1`
- **WAN (Primary):** Supports IPv4 & IPv6.
- **WANB (Backup/Modem):** IPv4 only (IPv6 disabled).

### 1. Interfaces (`/etc/config/network`)

Edit the network configuration to define your loopback, bridge, and WAN interfaces.

```bash
vi /etc/config/network
```

**Configuration Content:**

```lua
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config globals 'globals'
        option ula_prefix 'fda1:66d8:dae0::/48'
        option packet_steering '1'

config device
        option name 'br-lan'
        option type 'bridge'
        list ports 'lan2'
        list ports 'lan3'

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '192.168.20.1'
        option netmask '255.255.255.0'
        option ip6assign '60'

# Primary WAN: Handles IPv4
config interface 'wan'
        option device 'wan'
        option proto 'dhcp'
        option metric '10'

# Primary WAN: Handles IPv6
config interface 'wan6'
        option device 'wan'
        option proto 'dhcpv6'
        option reqaddress 'try'
        option reqprefix 'auto'
        option norelease '1'
        option metric '10'

# Backup WAN (Modem): IPv4 Only - Renamed to wanb
config interface 'wanb'
        option proto 'dhcp'
        option device 'lan1'
        option metric '20'
        option delegate '0' # Disables IPv6 delegation for this interface
```

### 2. DHCP & DNS (`/etc/config/dhcp`)

Configure `dnsmasq` to hand out IP addresses to your LAN clients.

```bash
vi /etc/config/dhcp
```

**Configuration Content:**

```lua
config dnsmasq
        option domainneeded '1'
        option boguspriv '1'
        option filterwin2k '0'
        option localise_queries '1'
        option rebind_protection '1'
        option rebind_localhost '1'
        option local '/lan/'
        option domain 'lan'
        option expandhosts '1'
        option nonegcache '0'
        option authoritative '1'
        option readethers '1'
        option leasefile '/tmp/dhcp.leases'
        option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
        option localservice '1'

config dhcp 'lan'
        option interface 'lan'
        option start '100'
        option limit '150'
        option leasetime '12h'
        option dhcpv4 'server'
        option dhcpv6 'server'
        option ra 'server'
        list ra_flags 'managed-config'
        list ra_flags 'other-config'

config dhcp 'wan'
        option interface 'wan'
        option ignore '1'

config odhcpd 'odhcpd'
        option maindhcp '0'
        option leasefile '/tmp/hosts/odhcpd'
        option leasetrigger '/usr/sbin/odhcpd-update'
        option loglevel '4'
```

### 3. Firewall Zones (`/etc/config/firewall`)

We must add `wanb` to the `wan` zone so traffic can flow out to the internet, and ensure LAN input is accepted.

```bash
vi /etc/config/firewall
```

**Configuration Snippet:**

```lua
config zone
        option name 'lan'
        list network 'lan'
        option input 'ACCEPT'    # CRITICAL for DHCP
        option output 'ACCEPT'
        option forward 'ACCEPT'

config zone
        option name 'wan'
        list network 'wan'
        list network 'wan6'
        list network 'wanb'      # Added wanb here
        option input 'REJECT'
        option output 'ACCEPT'
        option forward 'REJECT'
        option masq '1'
        option mtu_fix '1'
```

### 4. Applying Changes & The "No IPv4" Fix

**Issue:** Clients get IPv6 but no IPv4 (APIPA 169.254.x.x).
**Fix:** Restart DNSMasq _after_ the network is up.

1.  Restart Network: `service network restart`
2.  **Restart DNS:** `service dnsmasq restart`
3.  **Client:** `ipconfig /renew`

---

## Part 2: Firewall IPSet Management

You must create the `iran` IPSet before configuring MWAN3 rules, or MWAN3 will fail to load the rule.

1.  **Create runtime set:**

    ```bash
    ipset create iran hash:net family inet maxelem 2048
    ```

2.  **Add to persistent config:**

    ```bash
    uci add firewall ipset
    uci set firewall.@ipset[-1].name='iran'
    uci set firewall.@ipset[-1].family='ipv4'
    uci set firewall.@ipset[-1].match='dst_net'
    uci commit firewall
    ```

3.  **Apply:**
    ```bash
    /etc/init.d/firewall reload
    ```

---

## Part 3: Multi-WAN & Routing Logic (MWAN3)

This configuration achieves three goals:

1.  **Failover:** Primary traffic uses `wan`. If `wan` fails, it switches to `wanb`.
2.  **Policy Routing:** Traffic to `iran` IPs **always** uses `wanb`.
3.  **Smooth Switching:** Uses sticky sessions to keep video calls stable during minor link jitters.

### 1. Install MWAN3

```bash
opkg update
opkg install mwan3 luci-app-mwan3
```

### 2. Configure MWAN3 (`/etc/config/mwan3`)

**Note on smoothness:** We set `timeout` to 2 and `interval` to 3. This detects a failure within ~6-10 seconds. We use `sticky '1'` so if the WAN connection bounces momentarily, active calls attempt to hold onto their current interface rather than snapping back immediately.

```bash
echo > /etc/config/mwan3
vi /etc/config/mwan3
```

**Configuration Content:**

```lua
config globals 'globals'
        option mmx_mask '0x3F00'

# --- 1. Interfaces & Health Checks ---

config interface 'wan'
        option enabled '1'
        list track_ip '1.1.1.1'
        list track_ip '8.8.8.8'
        option reliability '1'
        option count '1'
        option timeout '2'
        option interval '3'
        option down '3'
        option up '3'
        option family 'ipv4'

config interface 'wanb'
        option enabled '1'
        list track_ip '208.67.222.222'
        list track_ip '8.8.4.4'
        option reliability '1'
        option count '1'
        option timeout '2'
        option interval '3'
        option down '3'
        option up '3'
        option family 'ipv4'

config interface 'wan6'
        option enabled '1'
        list track_ip '2001:4860:4860::8888'
        list track_ip '2606:4700:4700::1111'
        option reliability '1'
        option count '1'
        option timeout '2'
        option interval '3'
        option down '3'
        option up '3'
        option family 'ipv6'

# --- 2. Members (Weights & Metrics) ---
# Metric: Lower number = Higher Priority

config member 'wan_m1'
        option interface 'wan'
        option metric '1'
        option weight '3'

config member 'wanb_m1'
        option interface 'wanb'
        option metric '1'
        option weight '3'

config member 'wanb_m2'
        option interface 'wanb'
        option metric '2' # Backup priority
        option weight '3'

config member 'wan6_m1'
        option interface 'wan6'
        option metric '1'
        option weight '3'

# --- 3. Policies (Routing Logic) ---

# Policy: Iran Only (Force WANB)
config policy 'iran_wanb_force'
        list use_member 'wanb_m1'
        option last_resort 'unreachable'

# Policy: IPv4 Failover (WAN Primary -> WANB Backup)
config policy 'wan_failover_v4'
        list use_member 'wan_m1'
        list use_member 'wanb_m2'
        option last_resort 'unreachable'

# Policy: IPv6 (WAN6 Only - WANB has no v6)
config policy 'wan_v6_only'
        list use_member 'wan6_m1'
        option last_resort 'unreachable'

# --- 4. Rules (Applying Logic) ---
# Rules are processed top to bottom.

# Rule 1: Route 'iran' IPSet to WANB
config rule 'rule_iran'
        option proto 'all'
        option sticky '1'
        option ipset 'iran'
        option use_policy 'iran_wanb_force'
        option family 'ipv4'

# Rule 2: HTTPS Sticky (Helps video calls stay stable)
config rule 'https_sticky'
        option dest_port '443'
        option proto 'tcp'
        option sticky '1'
        option use_policy 'wan_failover_v4'
        option family 'ipv4'

# Rule 3: Default IPv4 (WAN -> Failover to WANB)
config rule 'default_v4'
        option dest_ip '0.0.0.0/0'
        option proto 'all'
        option sticky '1'
        option use_policy 'wan_failover_v4'
        option family 'ipv4'

# Rule 4: Default IPv6 (WAN6 Only)
config rule 'default_v6'
        option dest_ip '::/0'
        option proto 'all'
        option sticky '0'
        option use_policy 'wan_v6_only'
        option family 'ipv6'
```

### 3. Restart and Verify

```bash
service mwan3 restart
mwan3 status
```

---

## Part 4: IPSet Updater Script

A clean, simple IPSet management script with GeoIP support.

### Repository

[https://github.com/ownopenwrt/openwrt](https://github.com/ownopenwrt/openwrt)

### Features

- **Simple & Clean**: Single-purpose script for IPSet management
- **Iran GeoIP**: Automatically includes Iran IP ranges from GeoIP data
- **Cache-Busting**: Timestamp parameters prevent stale downloads
- **IPv4/IPv6 Support**: Configurable IP family filtering
- **Automatic Setup**: Creates UCI configuration automatically

### Installation & Usage

#### Quick Start (Iran IP ranges only)

**One-line run (No installation required):**

```bash
wget -O - "https://raw.githubusercontent.com/ownopenwrt/openwrt/main/ipset-update.sh?t=$(date +%s)" | sh
```

#### What It Does

The script automatically:

1. Downloads your IP list from `list.txt`
2. Adds Iran GeoIP data from IPdeny.com
3. Creates/updates the "iran" IPSet
4. Configures firewall rules

**Just run:**

```bash
wget -O - "https://raw.githubusercontent.com/ownopenwrt/openwrt/main/ipset-update.sh?t=$(date +%s)" | sh
```

#### Scheduled Updates

**Add to cron for daily updates:**

```bash
# Edit crontab
crontab -e

# Add this line for daily updates at 3 AM:
0 3 * * * wget -qO - "https://raw.githubusercontent.com/ownopenwrt/openwrt/main/ipset-update.sh?t=$(date +%s)" | sh >> /tmp/ipset-update.log 2>&1
```

#### Configuration Options

Edit the top of `ipset-update.sh` to customize:

```bash
# IPSet configuration
URL="https://raw.githubusercontent.com/ownopenwrt/openwrt/main/list.txt"  # Your IP list
SET_NAME="iran"          # IPSet name
MAXELEM="2048"          # Maximum entries
FAMILY="ipv4"           # ipv4 or ipv6

# Iran GeoIP (automatically includes Iran IP ranges)
INCLUDE_IRAN_GEOIP="true"  # Set to "false" to disable
```

#### Troubleshooting

**Check IPSet status:**

```bash
ipset list iran | head -10
```

**Check firewall config:**

```bash
uci show firewall | grep iran
```

**Manual verification:**

```bash
# Count entries in IPSet
ipset list iran | grep -E '^[0-9]' | wc -l

# Test Iran GeoIP data
curl -s "https://www.ipdeny.com/ipblocks/data/aggregated/ir-aggregated.zone" | head -5
```

---

## Troubleshooting

### Video Calls Drop completely on switch

If the ISP IP changes, the socket _must_ break. However, if using UDP (Zoom/WhatsApp), they usually reconnect fast.

- **Check:** Ensure `option sticky '1'` is enabled in the rules. This ensures that if the new link (wanb) is used, the call stays there and doesn't try to jump back to `wan` immediately if `wan` flickers up for 1 second.

### "Iran" traffic going through WAN

1.  Check if IPSet exists: `ipset list iran`.
2.  Check if MWAN3 rule is active: `mwan3 status`. Look for `rule_iran`.
3.  Ensure the IPSet was created _before_ restarting MWAN3.

### Clients have IPv6 but no IPv4

1.  Log into router.
2.  Run: `service dnsmasq restart`.
3.  Client: `ipconfig /renew`.

### License

MIT License - feel free to modify and distribute.
