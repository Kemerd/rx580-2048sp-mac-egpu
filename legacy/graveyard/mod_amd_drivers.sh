#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  Direct AMD Driver Mod - Adding 0x6FDF to Polaris match list${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ----------------------------------------------------------
# Step 1: Mount system volume as writable
# ----------------------------------------------------------
echo -e "${YELLOW}[STEP 1/5]${NC} Mounting system volume as writable..."

# Check SIP
if csrutil status 2>&1 | grep -q "enabled"; then
    echo -e "${RED}  SIP is enabled. Cannot modify system files.${NC}"
    exit 1
fi

sudo mount -uw / 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}  Failed to mount / as writable. Trying alternate method...${NC}"
    SYSVOL=$(df / | tail -1 | awk '{print $1}' | sed 's/s[0-9]*$//')
    sudo mount -o nobrowse -t apfs "$SYSVOL" /System/Volumes/Update/mnt1 2>&1
    SYSROOT="/System/Volumes/Update/mnt1"
else
    SYSROOT=""
fi
echo -e "${GREEN}  [OK]${NC} System volume is writable"
echo ""

EXTDIR="${SYSROOT}/System/Library/Extensions"

# ----------------------------------------------------------
# Step 2: Backup original kexts
# ----------------------------------------------------------
echo -e "${YELLOW}[STEP 2/5]${NC} Backing up original Info.plist files..."

BACKUP_DIR="$HOME/Desktop/eGPU_Hack/kext_backups"
mkdir -p "$BACKUP_DIR"

for KEXT in AMDRadeonX4000 AMD9500Controller AMDRadeonX4000HWServices; do
    PLIST="$EXTDIR/${KEXT}.kext/Contents/Info.plist"
    if [ -f "$PLIST" ]; then
        cp "$PLIST" "$BACKUP_DIR/${KEXT}_Info.plist.bak"
        echo -e "${GREEN}  [OK]${NC} Backed up ${KEXT}"
    else
        echo -e "${RED}  [FAIL]${NC} ${KEXT} Info.plist not found at: $PLIST"
        exit 1
    fi
done
echo ""

# ----------------------------------------------------------
# Step 3: Add 0x6FDF1002 to IOPCIMatch strings
# ----------------------------------------------------------
echo -e "${YELLOW}[STEP 3/5]${NC} Patching IOPCIMatch to include 0x6FDF1002..."

DEVICE_ID="0x6FDF1002"
ANCHOR="0x67DF1002"

for KEXT in AMDRadeonX4000 AMD9500Controller AMDRadeonX4000HWServices; do
    PLIST="$EXTDIR/${KEXT}.kext/Contents/Info.plist"

    # Convert to XML for safe editing
    sudo plutil -convert xml1 "$PLIST"

    # Check if already patched
    if grep -q "6FDF1002" "$PLIST"; then
        echo -e "${GREEN}  [OK]${NC} ${KEXT} already has 0x6FDF1002"
        continue
    fi

    # Add our device ID right after the anchor (0x67DF1002)
    sudo sed -i '' "s/${ANCHOR}/${ANCHOR} ${DEVICE_ID}/g" "$PLIST"

    # Verify the patch
    if grep -q "6FDF1002" "$PLIST"; then
        echo -e "${GREEN}  [OK]${NC} ${KEXT} patched successfully"
    else
        echo -e "${RED}  [FAIL]${NC} ${KEXT} patch failed!"
        exit 1
    fi

    # Validate plist
    sudo plutil -lint "$PLIST" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}       ${NC} Plist validation: OK"
    else
        echo -e "${RED}  [FAIL]${NC} Plist corrupted! Restoring backup..."
        sudo cp "$BACKUP_DIR/${KEXT}_Info.plist.bak" "$PLIST"
        exit 1
    fi
done
echo ""

# ----------------------------------------------------------
# Step 4: Rebuild kernel cache
# ----------------------------------------------------------
echo -e "${YELLOW}[STEP 4/5]${NC} Rebuilding kernel cache..."
sudo kextcache -i / 2>&1
echo -e "${GREEN}  [OK]${NC} Cache rebuilt"
echo ""

# ----------------------------------------------------------
# Step 5: Bless the new snapshot
# ----------------------------------------------------------
echo -e "${YELLOW}[STEP 5/5]${NC} Creating new system snapshot..."
sudo bless --folder /System/Library/CoreServices --bootefi --create-snapshot 2>&1 || {
    echo -e "${YELLOW}  [WARN]${NC} bless snapshot failed (may not be needed)"
}
echo ""

echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}  PATCHING COMPLETE!${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""
echo "  Modified kexts:"
echo "    - AMDRadeonX4000.kext (acceleration/Metal)"
echo "    - AMD9500Controller.kext (framebuffer controller)"
echo "    - AMDRadeonX4000HWServices.kext (hardware services)"
echo ""
echo "  Backups saved to: $BACKUP_DIR"
echo ""
echo -e "  ${YELLOW}REBOOT NOW${NC} with eGPU connected."
echo ""
echo "  After reboot, check with:"
echo "    system_profiler SPDisplaysDataType"
echo ""
echo -e "  ${CYAN}To revert:${NC}"
echo "    sudo mount -uw /"
echo "    sudo cp ~/Desktop/eGPU_Hack/kext_backups/*_Info.plist.bak back to the kexts"
echo ""
