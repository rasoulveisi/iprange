#!/bin/sh

# Installation script for OpenWrt IPSet Updater
# This script downloads and installs the IPSet updater script

echo "Installing OpenWrt IPSet Updater..."
echo "==================================="

# Create the updater script
cat > /usr/bin/ipset-update << 'EOF'
#!/bin/sh

# OpenWrt IPSet Updater Script
# This script updates an IPSet with IP ranges from a GitHub repository

# 1. CONFIGURATION
# Replace with your RAW GitHub URL
URL="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/list.txt"
SET_NAME="iran"
TEMP_FILE="/tmp/ip_list.txt"
ERROR_LOG="/tmp/script_errors.log"

# Ensure cleanup of log on exit
trap 'rm -f "$TEMP_FILE" "$ERROR_LOG"' EXIT

echo "OpenWrt IPSet Updater - Starting..."
echo "=================================="

echo "Downloading IP list..."
if ! wget -O "$TEMP_FILE" "$URL"; then
    echo "Error: Failed to download file." >&2
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
    echo "  uci set firewall.@ipset[-1].match='src_net'" >&2
    echo "  uci commit firewall" >&2
    exit 1
fi

echo "Found '$SET_NAME' at config section '$UCI_ID'"

# ============================================================
# 3. GET CURRENT ENTRIES AND PREPARE NEW LIST
# ============================================================
echo "Reading current IPSet configuration..."

# Get current entries from UCI config
CURRENT_ENTRIES=$(uci get firewall."$UCI_ID".entry 2>/dev/null | tr ' ' '\n' | sort | uniq)
echo "Current entries: $(echo "$CURRENT_ENTRIES" | wc -l)"

# Read new entries from downloaded file
NEW_ENTRIES=""
while IFS= read -r IP; do
    # Skip empty lines or comments
    [ -z "$IP" ] && continue
    case "$IP" in \#*) continue ;; esac
    NEW_ENTRIES="$NEW_ENTRIES $IP"
done < "$TEMP_FILE"

NEW_ENTRIES=$(echo "$NEW_ENTRIES" | tr ' ' '\n' | sed '/^$/d' | sort | uniq)
echo "New entries to add: $(echo "$NEW_ENTRIES" | wc -l)"

# ============================================================
# 4. CALCULATE DIFFERENCES
# ============================================================
echo "Calculating changes..."

# Entries to remove (in current but not in new)
TO_REMOVE=""
for entry in $CURRENT_ENTRIES; do
    if ! echo "$NEW_ENTRIES" | grep -q "^$entry$"; then
        TO_REMOVE="$TO_REMOVE $entry"
    fi
done

# Entries to add (in new but not in current)
TO_ADD=""
for entry in $NEW_ENTRIES; do
    if ! echo "$CURRENT_ENTRIES" | grep -q "^$entry$"; then
        TO_ADD="$TO_ADD $entry"
    fi
done

echo "Entries to remove: $(echo "$TO_REMOVE" | wc -w)"
echo "Entries to add: $(echo "$TO_ADD" | wc -w)"

# ============================================================
# 5. APPLY CHANGES SAFELY
# ============================================================
echo "Applying changes..."

# Clear any old error log
: > "$ERROR_LOG"
error_count=0

# Remove old entries
for entry in $TO_REMOVE; do
    echo "Removing: $entry"
    uci del_list firewall."$UCI_ID".entry="$entry" 2>>"$ERROR_LOG" || error_count=$((error_count + 1))
done

# Add new entries
for entry in $TO_ADD; do
    echo "Adding: $entry"
    uci add_list firewall."$UCI_ID".entry="$entry" 2>>"$ERROR_LOG" || error_count=$((error_count + 1))
done

# 5. CHECK FOR ERRORS AND DISPLAY LOG
if [ "$error_count" -gt 0 ]; then
    echo "Encountered $error_count errors during import. See error log below:" >&2
    cat "$ERROR_LOG" >&2
else
    echo "Import completed without errors."
fi

# 6. COMMIT changes
echo "Committing changes to config file..." >&2
uci commit firewall

# 7. RESTART
echo "Restarting firewall to apply changes..." >&2
/etc/init.d/firewall restart

echo "=================================="
echo "Update completed successfully!"
echo "IPSet '$SET_NAME' has been updated with the latest IP ranges."
EOF

# Make it executable
chmod +x /usr/bin/ipset-update

echo "Installation completed!"
echo "======================="
echo "You can now run the updater with:"
echo "  ipset-update"
echo ""
echo "Or run it directly from GitHub:"
echo "  wget -O - https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/ipset-update.sh | sh"
