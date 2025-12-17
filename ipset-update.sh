#!/bin/sh

# OpenWrt IPSet Updater Script
# Clean, simple IPSet management with GeoIP support
# Repository: https://github.com/ownopenwrt/openwrt
# Usage: wget -O - "https://raw.githubusercontent.com/ownopenwrt/openwrt/main/ipset-update.sh?t=$(date +%s)" | sh

# CONFIGURATION
URL="https://raw.githubusercontent.com/ownopenwrt/openwrt/main/list.txt"
SET_NAME="iran"
MAXELEM="2048"
FAMILY="ipv4"
TEMP_FILE="/tmp/ip_list.txt"
ERROR_LOG="/tmp/script_errors.log"

# Include Iran GeoIP data automatically
INCLUDE_IRAN_GEOIP="true"

# Ensure cleanup of log on exit
trap 'rm -f "$TEMP_FILE" "$ERROR_LOG"' EXIT

# Utility functions
fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 30 "$url" 2>/dev/null
    else
        wget -q -O - --timeout=30 "$url" 2>/dev/null
    fi
}

fetch_geoip() {
    local country="$1"
    echo "Fetching GeoIP data for $country..."
    fetch_url "https://www.ipdeny.com/ipblocks/data/aggregated/${country}-aggregated.zone" 2>/dev/null
}

echo "OpenWrt IPSet Updater - Starting..."
echo "=================================="

# Check required commands
command -v wget >/dev/null || command -v curl >/dev/null || { echo "Error: wget or curl not found." >&2; exit 1; }
command -v uci >/dev/null || { echo "Error: uci not found." >&2; exit 1; }
command -v ipset >/dev/null || { echo "Error: ipset not found." >&2; exit 1; }

echo "Downloading IP list from GitHub..."
if ! fetch_url "$URL" > "$TEMP_FILE"; then
    echo "Error: Failed to download file from $URL" >&2
    exit 1
fi

# Add Iran GeoIP data if enabled
if [ "$INCLUDE_IRAN_GEOIP" = "true" ]; then
    echo "Adding Iran GeoIP data..."
    fetch_geoip "ir" >> "$TEMP_FILE"
fi

if [ ! -s "$TEMP_FILE" ]; then
    echo "Error: Downloaded file is empty." >&2
    exit 1
fi

# 1. FIND OR CREATE UCI FIREWALL CONFIG
UCI_ID=$(uci show firewall 2>/dev/null | grep ".name='$SET_NAME'" | awk -F. '{print $2}' | head -1)

if [ -z "$UCI_ID" ]; then
    echo "Creating UCI firewall configuration for '$SET_NAME'..."
    uci add firewall ipset >/dev/null 2>&1
    UCI_ID=$(uci show firewall 2>/dev/null | grep "@ipset\[-1\]" | awk -F. '{print $2}' | head -1)
    if [ -n "$UCI_ID" ]; then
        uci set firewall."$UCI_ID".name="$SET_NAME"
        uci set firewall."$UCI_ID".family="$FAMILY"
        uci set firewall."$UCI_ID".match="dst_net"
        uci set firewall."$UCI_ID".maxelem="$MAXELEM"
        uci commit firewall
        echo "UCI configuration created successfully"
    else
        echo "Error: Could not create UCI configuration" >&2
        exit 1
    fi
fi

echo "Using IPSet '$SET_NAME' (config section: $UCI_ID)"

# 2. ENSURE RUNTIME IPSET EXISTS
if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
    echo "Creating runtime IPSet '$SET_NAME'..."
    case "$FAMILY" in
        ipv4) FAMILY_FLAG="family inet" ;;
        ipv6) FAMILY_FLAG="family inet6" ;;
        *) FAMILY_FLAG="family inet" ;;
    esac

    if ! ipset create "$SET_NAME" hash:net $FAMILY_FLAG maxelem "$MAXELEM" 2>>"$ERROR_LOG"; then
        echo "Error: Could not create runtime IPSet" >&2
        exit 1
    fi
    echo "Runtime IPSet created successfully"
fi

# 3. READ AND PROCESS IP ENTRIES
NEW_ENTRIES=""
while IFS= read -r IP; do
    # Skip empty lines or comments
    [ -z "$IP" ] && continue
    case "$IP" in \#*) continue ;; esac

    # Filter based on configured family
    case "$FAMILY" in
        ipv4)
            # Skip IPv6 entries for IPv4-only sets
            echo "$IP" | grep -q ':' && continue
            ;;
        ipv6)
            # Skip IPv4 entries for IPv6-only sets
            echo "$IP" | grep -q ':' || continue
            ;;
        # For mixed family, accept both
    esac

    NEW_ENTRIES="$NEW_ENTRIES $IP"
done < "$TEMP_FILE"

NEW_ENTRIES=$(echo "$NEW_ENTRIES" | tr ' ' '\n' | sed '/^$/d' | sort | uniq)
NEW_COUNT=$(echo "$NEW_ENTRIES" | grep -v '^$' | wc -l)
echo "Loaded $NEW_COUNT IP ranges from sources"

# 4. UPDATE IPSET
echo "Updating IPSet '$SET_NAME'..."

# Clear existing entries
uci delete firewall."$UCI_ID".entry 2>/dev/null || true
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset flush "$SET_NAME" 2>/dev/null || true
fi

# Add new entries
if [ "$NEW_COUNT" -gt 0 ]; then
    echo "Adding $NEW_COUNT entries..."
    for IP in $NEW_ENTRIES; do
        [ -z "$IP" ] && continue

        # Add to UCI config
        uci add_list firewall."$UCI_ID".entry="$IP" 2>>"$ERROR_LOG"

        # Add to runtime IPSet
        ipset add "$SET_NAME" "$IP" 2>>"$ERROR_LOG"
    done
fi

# 5. COMMIT CHANGES AND RESTART FIREWALL
echo "Committing changes..."
uci commit firewall
/etc/init.d/firewall restart

# 6. VERIFY FINAL STATE
FINAL_COUNT=$(ipset list "$SET_NAME" 2>/dev/null | grep -E '^[0-9]' | wc -l || echo "0")
echo "=================================="
echo "Update completed successfully!"
echo "IPSet '$SET_NAME' now contains $FINAL_COUNT IP ranges"

# Show any errors that occurred
if [ -s "$ERROR_LOG" ]; then
    echo "Warnings (non-critical):"
    cat "$ERROR_LOG" >&2
fi

cmd_update() {
    echo "OpenWrt IPSet Updater - Starting Update..."
    echo "========================================"
    load_config "$IPSET_NAME"

# Data source functions (based on OpenWrt IPSet extras)
fetch_file() {
    local source_url="$1"
    echo "Downloading from: $source_url"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 30 "$source_url" || wget -q -O - --timeout=30 "$source_url" 2>/dev/null
    else
        wget -q -O - --timeout=30 "$source_url" 2>/dev/null
    fi
}

fetch_asn() {
    local asn="$1"
    echo "Fetching ASN $asn data from RIPEstat..."
    fetch_file "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$asn" | \
        jsonfilter -e '@["data"]["prefixes"][*]["prefix"]' 2>/dev/null || \
        echo "Error: Could not fetch ASN data" >&2
}

fetch_geoip() {
    local country="$1"
    echo "Fetching GeoIP data for $country from IPdeny..."
    (
        fetch_file "https://www.ipdeny.com/ipblocks/data/aggregated/${country}-aggregated.zone"
        fetch_file "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${country}-aggregated.zone"
    ) 2>/dev/null || echo "Error: Could not fetch GeoIP data" >&2
}

resolve_domain() {
    local domain="$1"
    echo "Resolving domain: $domain"
    if command -v resolveip >/dev/null 2>&1; then
        resolveip "$domain" 2>/dev/null
    else
        # Fallback to nslookup if resolveip not available
        nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | grep -v ':'
    fi
}

# Main command dispatcher
case "$COMMAND" in
    setup) cmd_setup ;;
    unset) cmd_unset ;;
    update|"") cmd_update ;;
    install) cmd_install ;;
    install-hotplug) cmd_install_hotplug ;;
    *)
        echo "Usage: $0 {setup|unset|update|install|install-hotplug} [ipset_name]" >&2
        echo "Commands:" >&2
        echo "  setup          - Create IPSet configuration and runtime set" >&2
        echo "  unset          - Remove IPSet configuration and runtime set" >&2
        echo "  update         - Update IPSet with new data (default)" >&2
        echo "  install        - Install script locally to /usr/bin/" >&2
        echo "  install-hotplug- Install hotplug script for automatic updates" >&2
        exit 1
        ;;
esac

# Check required commands
command -v wget >/dev/null || { echo "Error: wget not found." >&2; exit 1; }
command -v uci >/dev/null || { echo "Error: uci not found." >&2; exit 1; }
command -v ipset >/dev/null || { echo "Error: ipset not found." >&2; exit 1; }

# Collect IP entries from all configured sources
echo "Collecting IP entries from configured sources..."

# Clear temp file
: > "$TEMP_FILE"

# Process different data sources from UCI config
if [ -n "$UCI_CONFIG" ]; then
    echo "Processing UCI-configured sources..."

    # File sources
    uci get dhcp."$UCI_CONFIG".file 2>/dev/null | tr ' ' '\n' | while read -r source_url; do
        [ -z "$source_url" ] && continue
        echo "Processing file source: $source_url"
        fetch_file "$source_url" >> "$TEMP_FILE"
    done

    # ASN sources
    uci get dhcp."$UCI_CONFIG".asn 2>/dev/null | tr ' ' '\n' | while read -r asn; do
        [ -z "$asn" ] && continue
        echo "Processing ASN: $asn"
        fetch_asn "$asn" >> "$TEMP_FILE"
    done

    # GeoIP sources
    uci get dhcp."$UCI_CONFIG".geoip 2>/dev/null | tr ' ' '\n' | while read -r country; do
        [ -z "$country" ] && continue
        echo "Processing GeoIP: $country"
        fetch_geoip "$country" >> "$TEMP_FILE"
    done

    # Domain sources
    uci get dhcp."$UCI_CONFIG".domain 2>/dev/null | tr ' ' '\n' | while read -r domain; do
        [ -z "$domain" ] && continue
        echo "Processing domain: $domain"
        resolve_domain "$domain" >> "$TEMP_FILE"
    done
fi

# Fallback to default URL if no UCI sources configured
if [ ! -s "$TEMP_FILE" ]; then
    echo "No UCI sources configured, using default URL..."
    if ! fetch_file "$URL" > "$TEMP_FILE"; then
        echo "Error: Failed to download file from $URL" >&2
        exit 1
    fi
fi

if [ ! -s "$TEMP_FILE" ]; then
    echo "Error: No data collected from any source." >&2
    exit 1
fi

# 2. FIND THE CORRECT UCI SECTION
UCI_ID=$(uci show firewall 2>/dev/null | grep ".name='$SET_NAME'" | awk -F. '{print $2}' | head -1)

if [ -z "$UCI_ID" ]; then
    echo "Warning: IPSet named '$SET_NAME' not found in firewall config. Creating it..."
    uci add firewall ipset >/dev/null 2>&1
    UCI_ID=$(uci show firewall 2>/dev/null | grep "@ipset\[-1\]" | awk -F. '{print $2}' | head -1)
    if [ -n "$UCI_ID" ]; then
        uci set firewall."$UCI_ID".name="$SET_NAME"
        uci set firewall."$UCI_ID".family="$FAMILY"
        uci set firewall."$UCI_ID".match="dst_net"
        uci set firewall."$UCI_ID".maxelem="$MAXELEM"
        uci commit firewall
        echo "Created firewall configuration for '$SET_NAME'"
    else
        echo "Error: Could not create firewall configuration" >&2
        exit 1
    fi
fi

echo "Using '$SET_NAME' at config section '$UCI_ID'"

# 3. ENSURE RUNTIME IPSET EXISTS
# Check if ipset exists in runtime, create if not
if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
    echo "Runtime IPSet '$SET_NAME' not found. Creating it..."
    # Get maxelem from config
    MAXELEM=$(uci get firewall."$UCI_ID".maxelem 2>/dev/null || echo "$DEFAULT_MAXELEM")

    # Determine family flag
    case "$FAMILY" in
        ipv4) FAMILY_FLAG="family inet" ;;
        ipv6) FAMILY_FLAG="family inet6" ;;
        *) FAMILY_FLAG="family inet" ;;
    esac

    if ! ipset create "$SET_NAME" hash:net $FAMILY_FLAG maxelem "$MAXELEM" 2>>"$ERROR_LOG"; then
        echo "Warning: Could not create runtime IPSet. It will be created on firewall restart." >&2
    else
        echo "Runtime IPSet created successfully."
    fi
fi

# 4. GET CURRENT ENTRIES FROM BOTH UCI AND RUNTIME
echo "Reading current IPSet configuration..."

# Get current entries from UCI config
CURRENT_ENTRIES_UCI=$(uci get firewall."$UCI_ID".entry 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort | uniq)

# Get current entries from runtime ipset
CURRENT_ENTRIES_RUNTIME=""
RUNTIME_EXISTS=0
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    RUNTIME_EXISTS=1
    CURRENT_ENTRIES_RUNTIME=$(ipset list "$SET_NAME" | grep -E '^[0-9]' | awk '{print $1}' | sort | uniq)
    RUNTIME_COUNT=$(echo "$CURRENT_ENTRIES_RUNTIME" | grep -v '^$' | wc -l)
    echo "Current entries in runtime ipset: $RUNTIME_COUNT"
else
    echo "Runtime ipset does not exist yet."
fi

UCI_COUNT=$(echo "$CURRENT_ENTRIES_UCI" | grep -v '^$' | wc -l)
echo "Current entries in UCI config: $UCI_COUNT"

# Merge both lists (union) to get all current entries
CURRENT_ENTRIES=$(printf "%s\n%s" "$CURRENT_ENTRIES_UCI" "$CURRENT_ENTRIES_RUNTIME" | sort | uniq)

# 5. READ NEW ENTRIES FROM COLLECTED DATA
NEW_ENTRIES=""
while IFS= read -r IP; do
    # Skip empty lines or comments
    [ -z "$IP" ] && continue
    case "$IP" in \#*) continue ;; esac

    # Filter based on configured family
    case "$FAMILY" in
        ipv4)
            # Skip IPv6 entries for IPv4-only sets
            echo "$IP" | grep -q ':' && continue
            ;;
        ipv6)
            # Skip IPv4 entries for IPv6-only sets
            echo "$IP" | grep -q ':' || continue
            ;;
        # For mixed family, accept both
    esac

    NEW_ENTRIES="$NEW_ENTRIES $IP"
done < "$TEMP_FILE"

NEW_ENTRIES=$(echo "$NEW_ENTRIES" | tr ' ' '\n' | sed '/^$/d' | sort | uniq)
NEW_COUNT=$(echo "$NEW_ENTRIES" | grep -v '^$' | wc -l)
echo "New entries collected: $NEW_COUNT"

# 6. CALCULATE DIFFERENCES
echo "Calculating changes..."

# Entries to remove (in current but not in new)
TO_REMOVE=""
for entry in $CURRENT_ENTRIES; do
    [ -z "$entry" ] && continue
    if ! echo "$NEW_ENTRIES" | grep -q "^$entry$"; then
        TO_REMOVE="$TO_REMOVE $entry"
    fi
done

# Entries to add (in new but not in current)
TO_ADD=""
for entry in $NEW_ENTRIES; do
    [ -z "$entry" ] && continue
    if ! echo "$CURRENT_ENTRIES" | grep -q "^$entry$"; then
        TO_ADD="$TO_ADD $entry"
    fi
done

REMOVE_COUNT=$(echo "$TO_REMOVE" | tr ' ' '\n' | grep -v '^$' | wc -l)
ADD_COUNT=$(echo "$TO_ADD" | tr ' ' '\n' | grep -v '^$' | wc -l)
echo "Entries to remove: $REMOVE_COUNT"
echo "Entries to add: $ADD_COUNT"

# 7. APPLY CHANGES TO BOTH UCI CONFIG AND RUNTIME IPSET
echo "Applying changes..."

# Clear any old error log
: > "$ERROR_LOG"
error_count=0

# OPTIMIZATION: Clear all entries at once (much faster than one-by-one)
echo "Clearing existing entries..."
# Clear all entries from UCI config at once
uci delete firewall."$UCI_ID".entry 2>/dev/null || true

# Flush runtime ipset (much faster than deleting one by one)
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    echo "Flushing runtime ipset..."
    ipset flush "$SET_NAME" 2>/dev/null || true
else
    echo "Runtime ipset does not exist, will be populated after firewall restart."
fi

# Add all new entries to both UCI config and runtime ipset
if [ "$NEW_COUNT" -gt 0 ]; then
    echo "Adding $NEW_COUNT entries to UCI config and runtime ipset..."
    uci_added=0
    runtime_added=0
    
    for entry in $NEW_ENTRIES; do
        [ -z "$entry" ] && continue
        
        # Add to UCI config (persistent)
        if uci add_list firewall."$UCI_ID".entry="$entry" 2>>"$ERROR_LOG"; then
            uci_added=$((uci_added + 1))
        else
            echo "Error adding $entry to UCI config" >&2
            error_count=$((error_count + 1))
            continue
        fi
        
        # Add to runtime ipset (immediate) - ensure ipset exists first
        if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
            # Create ipset if it doesn't exist
            MAXELEM=$(uci get firewall."$UCI_ID".maxelem 2>/dev/null || echo "2048")
            if ipset create "$SET_NAME" hash:net family inet maxelem "$MAXELEM" 2>>"$ERROR_LOG"; then
                echo "Created runtime ipset '$SET_NAME'"
            else
                echo "Warning: Could not create runtime ipset, entries will be added after firewall restart" >&2
                continue
            fi
        fi
        
        # Now add to runtime ipset
        if ipset add "$SET_NAME" "$entry" 2>>"$ERROR_LOG"; then
            runtime_added=$((runtime_added + 1))
        else
            echo "Warning: Could not add $entry to runtime ipset (may already exist)" >&2
        fi
    done
    
    echo "Successfully added $uci_added entries to UCI config."
    echo "Successfully added $runtime_added entries to runtime ipset."
else
    echo "No new entries to add."
fi

# 8. CHECK FOR ERRORS AND DISPLAY LOG
if [ "$error_count" -gt 0 ]; then
    echo "Encountered $error_count errors during import. See error log below:" >&2
    cat "$ERROR_LOG" >&2
else
    echo "Import completed without errors."
fi

# 9. COMMIT UCI CHANGES
echo "Committing changes to firewall config..."
uci commit firewall

# 10. RESTART FIREWALL (ensures everything is synced)
echo "Restarting firewall to sync configuration..."
/etc/init.d/firewall restart

# 11. VERIFY FINAL STATE
FINAL_COUNT=$(ipset list "$SET_NAME" 2>/dev/null | grep -E '^[0-9]' | wc -l || echo "0")
echo "=================================="
echo "Update completed successfully!"
echo "IPSet '$SET_NAME' now contains $FINAL_COUNT IP ranges."
echo "Changes have been applied to both firewall config and runtime ipset."
