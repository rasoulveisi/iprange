# OpenWrt Configuration Guide

A comprehensive guide for configuring OpenWrt routers, including network settings, firewall IPSet management, and automated IP list updates.

## Table of Contents

- [Network Configuration](#network-configuration)
- [Firewall IPSet Management](#firewall-ipset-management)
- [IPSet Updater Script](#ipset-updater-script)
- [Troubleshooting](#troubleshooting)

---

## Network Configuration

### Router and Modem IP Settings

Configure your router and modem with the following IP addresses:

- **Router IP**: `192.168.20.1`
- **Modem IP**: `192.168.10.1`

These settings ensure proper network segmentation and routing.

---

## Firewall IPSet Management

IPSet is a framework inside the Linux kernel that allows you to manage IP addresses, networks, ports, MAC addresses, and other sets. In OpenWrt, IPSets are managed through the UCI (Unified Configuration Interface) and can be used for firewall rules and policy-based routing.

> **Important Note:** When you add an IPSet through the OpenWrt web UI (LuCI), it gets added to the firewall configuration, but it won't appear in the `ipset list` command until the firewall is restarted and the IPSet is properly initialized.

### Create an IPSet

To create a new IPSet, you need to:

1. **Create the runtime IPSet** (temporary, until firewall restart):

```bash
ipset create iran hash:net family inet maxelem 2048
```

2. **Add IPSet to UCI configuration** (persistent):

```bash
uci add firewall ipset
uci set firewall.@ipset[-1].name='iran'
uci set firewall.@ipset[-1].family='ipv4'
uci set firewall.@ipset[-1].match='dst_net'
uci commit firewall
```

3. **Restart the firewall** to apply changes:

```bash
/etc/init.d/firewall restart
```

**Parameters explained:**

- `name`: The name of your IPSet
- `family`: `ipv4` for IPv4 addresses, `ipv6` for IPv6
- `match`: `dst_net` for destination matching, `src_net` for source matching

### View IPSet Contents

Check your IPSet configuration and contents:

```bash
# View UCI configuration
uci show firewall | grep iran

# View runtime IPSet (nftables)
nft -t list sets table inet fw4

# View runtime IPSet (legacy ipset command)
ipset list iran
```

### Add IP Addresses to IPSet

#### Method 1: Add to runtime IPSet (temporary)

```bash
ipset add iran 185.94.96.12/32
```

#### Method 2: Add to UCI configuration (persistent)

```bash
# Add a single IP or CIDR range
uci add_list firewall.@ipset[0].entry="185.188.104.0/24"

# Commit and restart
uci commit firewall
/etc/init.d/firewall restart
```

**Note:** Replace `@ipset[0]` with the correct index if you have multiple IPSets. Use `uci show firewall | grep ipset` to find the correct index.

### Remove IP Addresses from IPSet

To remove a specific IP entry from the UCI configuration:

```bash
# Find the entry ID first
uci show firewall | grep -A 5 iran

# Delete the specific entry (replace $UCI_ID with actual ID)
uci delete firewall."$UCI_ID".entry 2>/dev/null
uci commit firewall
/etc/init.d/firewall restart
```

### Delete an IPSet Completely

To completely remove an IPSet:

1. **Destroy the runtime IPSet:**

```bash
ipset destroy iran
```

2. **Remove from nftables:**

```bash
nft delete set inet fw4 iran
```

3. **Remove from UCI configuration:**

```bash
# Edit the firewall config
nano /etc/config/firewall
```

Delete the entire IPSet block:

```
config ipset
        option name 'iran'
        option family 'ipv4'
```

4. **Commit and restart:**

```bash
uci commit firewall
/etc/init.d/firewall restart
```

---

## IPSet Updater Script

An automated script to update IPSet entries from a GitHub-hosted IP list.

### Features

- ✅ Downloads IP ranges from a GitHub repository
- ✅ **Safely updates** OpenWrt IPSet configuration (only removes/adds changed entries)
- ✅ Automatically restarts firewall to apply changes
- ✅ Error handling and logging
- ✅ **PBR-friendly**: Preserves existing configuration if download fails
- ✅ Cleanup on exit

### Installation

#### Method 1: Install locally on OpenWrt

1. SSH into your OpenWrt router
2. Download and run the installation script:

```bash
wget -O - https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install-ipset-updater.sh | sh
```

This will install the `ipset-update` command on your system.

#### Method 2: Run directly from GitHub

Run the updater directly without installation:

```bash
wget -O - https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/ipset-update.sh | sh
```

### Prerequisites

Before running the script, you need to create the IPSet in OpenWrt:

```bash
# Add a new ipset
uci add firewall ipset

# Configure the ipset (replace @ipset[-1] with the actual index if needed)
uci set firewall.@ipset[-1].name='iran'
uci set firewall.@ipset[-1].family='ipv4'
uci set firewall.@ipset[-1].match='src_net'

# Commit the changes
uci commit firewall
/etc/init.d/firewall restart
```

### Usage

#### If installed locally:

```bash
ipset-update
```

#### If running directly:

```bash
wget -O - https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/ipset-update.sh | sh
```

### Configuration Options

Edit the script to customize:

- `URL`: The GitHub raw URL of your IP list
- `SET_NAME`: The name of your IPSet (default: 'iran')
- `TEMP_FILE`: Temporary file location (default: '/tmp/ip_list.txt')
- `ERROR_LOG`: Error log location (default: '/tmp/script_errors.log')

### IP List Format

The IP list should contain one IP range per line in CIDR notation:

```
89.235.96.0/22
89.198.0.0/17
213.195.52.0/22
# Comments are ignored
31.214.172.0/22
```

Empty lines and lines starting with `#` are ignored.

---

## Troubleshooting

### IPSet not found error

**Error:** "IPSet named 'iran' not found in config"

**Solution:** Make sure you've created the IPSet as described in the [Create an IPSet](#create-an-ipset) section. Verify with:

```bash
uci show firewall | grep ipset
```

### IPSet not appearing in `ipset list`

**Problem:** IPSet exists in UCI config but doesn't show in `ipset list`

**Solution:**

1. Restart the firewall: `/etc/init.d/firewall restart`
2. Verify the IPSet name matches exactly (case-sensitive)
3. Check firewall logs: `logread | grep firewall`

### PBR (Policy-Based Routing) not working

This script is designed to be **PBR-safe**. It will only remove IP ranges that are no longer in your GitHub list and add new ones.

If your IPSet becomes empty:

1. Check if your GitHub repository is accessible
2. Verify the IP list format (one CIDR range per line)
3. Check the error log at `/tmp/script_errors.log`
4. If download fails, existing entries remain intact

### Checking current IPSet status

```bash
# Check UCI configuration
uci show firewall | grep iran

# Check runtime IPSet (after firewall restart)
ipset list iran

# Check nftables sets
nft -t list sets table inet fw4
```

### Firewall restart issues

If the firewall fails to restart:

```bash
# Check firewall status
/etc/init.d/firewall status

# View firewall logs
logread | tail -50

# Test firewall configuration
/etc/init.d/firewall reload
```

### Network connectivity issues

If you're unable to download the IP list:

```bash
# Test connectivity
ping -c 3 raw.githubusercontent.com

# Test DNS resolution
nslookup raw.githubusercontent.com

# Check wget/curl availability
which wget
which curl
```

---

## License

MIT License - feel free to modify and distribute.
