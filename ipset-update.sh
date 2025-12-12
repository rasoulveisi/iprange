#!/bin/sh

# OpenWrt IPSet Updater Script
# This script updates an IPSet with IP ranges from a GitHub repository
# Repository: https://github.com/ownopenwrt/openwrt
# Usage: wget -O - https://raw.githubusercontent.com/ownopenwrt/openwrt/main/ipset-update.sh | sh

# 1. CONFIGURATION
URL="https://raw.githubusercontent.com/ownopenwrt/openwrt/main/list.txt"
SET_NAME="iran"
TEMP_FILE="/tmp/ip_list.txt"
ERROR_LOG="/tmp/script_errors.log"

# Ensure cleanup of log on exit
trap 'rm -f "$TEMP_FILE" "$ERROR_LOG"' EXIT

echo "OpenWrt IPSet Updater - Starting..."
echo "=================================="

# Check required commands
command -v wget >/dev/null || { echo "Error: wget not found." >&2; exit 1; }
command -v uci >/dev/null || { echo "Error: uci not found." >&2; exit 1; }
command -v ipset >/dev/null || { echo "Error: ipset not found." >&2; exit 1; }

echo "Downloading IP list from GitHub..."
if ! wget -q -O "$TEMP_FILE" "$URL"; then
    echo "Error: Failed to download file from $URL" >&2
    exit 1
fi

if [ ! -s "$TEMP_FILE" ]; then
    echo "Error: Downloaded file is empty." >&2
    exit 1
fi

# 2. FIND THE CORRECT UCI SECTION
UCI_ID=$(uci show firewall | grep ".name='$SET_NAME'" | awk -F. '{print $2}')

if [ -z "$UCI_ID" ]; then
    echo "Error: IPSet named '$SET_NAME' not found in config." >&2
    echo "Please create it first using:" >&2
    echo "  uci add firewall ipset" >&2
    echo "  uci set firewall.@ipset[-1].name='$SET_NAME'" >&2
    echo "  uci set firewall.@ipset[-1].family='ipv4'" >&2
    echo "  uci set firewall.@ipset[-1].match='dst_net'" >&2
    echo "  uci commit firewall" >&2
    echo "  /etc/init.d/firewall restart" >&2
    exit 1
fi

echo "Found '$SET_NAME' at config section '$UCI_ID'"

# 3. ENSURE RUNTIME IPSET EXISTS
# Check if ipset exists in runtime, create if not
if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
    echo "Runtime IPSet '$SET_NAME' not found. Creating it..."
    # Get maxelem from config or use default
    MAXELEM=$(uci get firewall."$UCI_ID".maxelem 2>/dev/null || echo "2048")
    if ! ipset create "$SET_NAME" hash:net family inet maxelem "$MAXELEM" 2>>"$ERROR_LOG"; then
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
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    CURRENT_ENTRIES_RUNTIME=$(ipset list "$SET_NAME" | grep -E '^[0-9]' | awk '{print $1}' | sort | uniq)
fi

# Merge both lists (union) to get all current entries
CURRENT_ENTRIES=$(printf "%s\n%s" "$CURRENT_ENTRIES_UCI" "$CURRENT_ENTRIES_RUNTIME" | sort | uniq)
CURRENT_COUNT=$(echo "$CURRENT_ENTRIES" | grep -v '^$' | wc -l)
echo "Current entries in config: $CURRENT_COUNT"

# 5. READ NEW ENTRIES FROM DOWNLOADED FILE
NEW_ENTRIES=""
while IFS= read -r IP; do
    # Skip empty lines or comments
    [ -z "$IP" ] && continue
    case "$IP" in \#*) continue ;; esac
    # Skip IPv6 entries (only process IPv4)
    echo "$IP" | grep -q ':' && continue
    NEW_ENTRIES="$NEW_ENTRIES $IP"
done < "$TEMP_FILE"

NEW_ENTRIES=$(echo "$NEW_ENTRIES" | tr ' ' '\n' | sed '/^$/d' | sort | uniq)
NEW_COUNT=$(echo "$NEW_ENTRIES" | grep -v '^$' | wc -l)
echo "New entries from GitHub: $NEW_COUNT"

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

# Remove old entries from both UCI config and runtime ipset
if [ "$REMOVE_COUNT" -gt 0 ]; then
    echo "Removing $REMOVE_COUNT entries..."
    for entry in $TO_REMOVE; do
        [ -z "$entry" ] && continue
        # Remove from UCI config
        uci del_list firewall."$UCI_ID".entry="$entry" 2>>"$ERROR_LOG" || error_count=$((error_count + 1))
        # Remove from runtime ipset
        if ipset list "$SET_NAME" >/dev/null 2>&1; then
            ipset del "$SET_NAME" "$entry" 2>>"$ERROR_LOG" || true
        fi
    done
fi

# Add new entries to both UCI config and runtime ipset
if [ "$ADD_COUNT" -gt 0 ]; then
    echo "Adding $ADD_COUNT entries..."
    for entry in $TO_ADD; do
        [ -z "$entry" ] && continue
        # Add to UCI config (persistent)
        if ! uci add_list firewall."$UCI_ID".entry="$entry" 2>>"$ERROR_LOG"; then
            echo "Error adding $entry to UCI config" >&2
            error_count=$((error_count + 1))
            continue
        fi
        # Add to runtime ipset (immediate)
        if ipset list "$SET_NAME" >/dev/null 2>&1; then
            if ! ipset add "$SET_NAME" "$entry" 2>>"$ERROR_LOG"; then
                echo "Warning: Could not add $entry to runtime ipset (may already exist)" >&2
            fi
        fi
    done
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
