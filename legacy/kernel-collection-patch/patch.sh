#!/bin/bash
# =============================================================================
#
#  eGPU Polaris macOS Kernel Collection Patch
#
#  Patches SystemKernelExtensions.kc to add AMD device ID 0x6FDF1002
#  (non-standard Polaris 20 variant used by SOYO, Yeston, and other
#  Chinese-market RX 580 cards) to Apple's AMD Polaris driver match lists.
#
#  This enables Metal 3 acceleration for eGPU compute and offscreen rendering.
#
#  Requirements:
#    - Intel Mac with Thunderbolt 3/4
#    - macOS Sequoia (tested on 15.7.5 build 24G624)
#    - SIP disabled (csrutil disable)
#    - Authenticated Root disabled (csrutil authenticated-root disable)
#    - AMD Polaris GPU with device ID 0x6FDF in an eGPU enclosure
#
#  WARNING: This patches your system kernel collection. A backup is created
#  automatically. If something goes wrong, boot to Recovery and restore
#  the backup, or reinstall macOS.
#
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MNT="/System/Volumes/Update/mnt1"

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  eGPU Polaris macOS Kernel Collection Patch${NC}"
echo -e "${CYAN}  Device ID: 0x6FDF -> added to Polaris match lists${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ----------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------
echo -e "${YELLOW}[PREFLIGHT]${NC} Checking requirements..."

# Architecture check
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo -e "${RED}  [FAIL]${NC} This patch is for Intel Macs only (got: $ARCH)"
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} Intel Mac detected"

# SIP check
if csrutil status 2>&1 | grep -q "enabled"; then
    echo -e "${RED}  [FAIL]${NC} SIP is enabled."
    echo "         Boot to Recovery (Cmd+R) and run: csrutil disable"
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} SIP disabled"

# Authenticated Root check
if csrutil authenticated-root status 2>&1 | grep -q "enabled"; then
    echo -e "${RED}  [FAIL]${NC} Authenticated Root is enabled."
    echo "         Boot to Recovery (Cmd+R) and run: csrutil authenticated-root disable"
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} Authenticated Root disabled"

# Check for the eGPU
EGPU=$(system_profiler SPPCIDataType 2>/dev/null | grep -c "0x6fdf" || true)
if [ "$EGPU" -eq 0 ]; then
    echo -e "${YELLOW}  [WARN]${NC} No GPU with device ID 0x6FDF detected on PCI bus."
    echo "         Make sure the eGPU is connected via Thunderbolt."
fi

# Find the system volume device
SYSVOL=$(df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/s[0-9]*$//')
if [ -z "$SYSVOL" ]; then
    echo -e "${RED}  [FAIL]${NC} Could not determine system volume device."
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} System volume: $SYSVOL"
echo ""

# ----------------------------------------------------------------
# Mount
# ----------------------------------------------------------------
echo -e "${YELLOW}[1/4]${NC} Mounting system volume..."
sudo mkdir -p "$MNT"
sudo mount -t apfs -o nobrowse "$SYSVOL" "$MNT" 2>&1
echo -e "${GREEN}  [OK]${NC} Mounted at $MNT"
echo ""

KC="$MNT/System/Library/KernelCollections/SystemKernelExtensions.kc"

if [ ! -f "$KC" ]; then
    echo -e "${RED}  [FAIL]${NC} SystemKernelExtensions.kc not found!"
    sudo diskutil unmount "$MNT" 2>/dev/null || true
    exit 1
fi

# ----------------------------------------------------------------
# Backup
# ----------------------------------------------------------------
echo -e "${YELLOW}[2/4]${NC} Backing up kernel collection..."
BACKUP_DIR="$SCRIPT_DIR/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
sudo cp "$KC" "$BACKUP_DIR/SystemKernelExtensions.kc.bak.$TIMESTAMP"
echo -e "${GREEN}  [OK]${NC} Backup saved to backups/SystemKernelExtensions.kc.bak.$TIMESTAMP"
echo ""

# ----------------------------------------------------------------
# Patch
# ----------------------------------------------------------------
echo -e "${YELLOW}[3/4]${NC} Patching kernel collection PRELINK_INFO..."

sudo python3 << PYEOF
import plistlib
import subprocess
import struct
import sys

KC_PATH = "$KC"

# ---- Read the KC ----
with open(KC_PATH, 'rb') as f:
    data = bytearray(f.read())
print(f"  KC size: {len(data):,} bytes")

# ---- Find PRELINK_INFO section via otool ----
result = subprocess.run(
    ['otool', '-l', KC_PATH],
    capture_output=True, text=True
)

prelink_offset = None
prelink_size = None
in_prelink = False
found_segment = False

for line in result.stdout.split('\n'):
    line = line.strip()
    if 'segname __PRELINK_INFO' in line and not found_segment:
        in_prelink = True
        found_segment = True
        continue
    if in_prelink:
        if line.startswith('fileoff') and prelink_offset is None:
            prelink_offset = int(line.split()[-1])
        elif line.startswith('filesize') and prelink_size is None:
            prelink_size = int(line.split()[-1])
        if prelink_offset is not None and prelink_size is not None:
            break

if prelink_offset is None or prelink_size is None:
    print("  ERROR: Could not find __PRELINK_INFO section!")
    sys.exit(1)

print(f"  PRELINK_INFO at offset {prelink_offset}, size {prelink_size:,}")

# ---- Parse the PRELINK_INFO plist ----
prelink_raw = bytes(data[prelink_offset:prelink_offset + prelink_size]).rstrip(b'\x00')
plist = plistlib.loads(prelink_raw)

# ---- Patch AMD kext personalities ----
TARGET_KEXTS = [
    'com.apple.kext.AMDRadeonX4000',
    'com.apple.kext.AMD9500Controller',
    'com.apple.kext.AMDRadeonX4000HWServices',
]

DEVICE_ID = '0x6FDF1002'
ANCHOR = '0x67DF1002'
patched = 0

for entry in plist['_PrelinkInfoDictionary']:
    bid = entry.get('CFBundleIdentifier', '')
    if bid not in TARGET_KEXTS:
        continue

    personalities = entry.get('IOKitPersonalities', {})
    for pname, pval in personalities.items():
        match = pval.get('IOPCIMatch', '')
        if ANCHOR in match and DEVICE_ID not in match:
            pval['IOPCIMatch'] = match.replace(ANCHOR, f'{ANCHOR} {DEVICE_ID}')
            print(f"  Patched: {bid} -> {pname}")
            patched += 1
        elif DEVICE_ID in match:
            print(f"  Already patched: {bid} -> {pname}")

if patched == 0:
    print("  Nothing new to patch.")
    sys.exit(0)

print(f"  Total personalities patched: {patched}")

# ---- Write back ----
new_prelink = plistlib.dumps(plist, fmt=plistlib.FMT_XML)

if len(new_prelink) > prelink_size:
    print(f"  ERROR: Patched data ({len(new_prelink):,}) exceeds section ({prelink_size:,})!")
    sys.exit(1)

padded = new_prelink + b'\x00' * (prelink_size - len(new_prelink))
data[prelink_offset:prelink_offset + prelink_size] = padded

with open(KC_PATH, 'wb') as f:
    f.write(bytes(data))

print(f"  Written {len(data):,} bytes to {KC_PATH}")
print("  Patch applied successfully!")
PYEOF

PATCH_EXIT=$?
if [ $PATCH_EXIT -ne 0 ]; then
    echo -e "${RED}  [FAIL]${NC} Patch failed! Restoring backup..."
    sudo cp "$BACKUP_DIR/SystemKernelExtensions.kc.bak.$TIMESTAMP" "$KC"
    sudo diskutil unmount "$MNT" 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}  [OK]${NC} Kernel collection patched"
echo ""

# ----------------------------------------------------------------
# Snapshot
# ----------------------------------------------------------------
echo -e "${YELLOW}[4/4]${NC} Creating new system snapshot..."
sudo bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot 2>&1
echo -e "${GREEN}  [OK]${NC} New snapshot created and blessed"

# Cleanup
sudo diskutil unmount "$MNT" 2>/dev/null || sudo umount "$MNT" 2>/dev/null || true

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}  PATCH COMPLETE!${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""
echo "  Reboot now with your eGPU connected via Thunderbolt."
echo ""
echo "  After reboot, verify with:"
echo "    system_profiler SPDisplaysDataType"
echo ""
echo "  You should see:"
echo "    Chipset Model: AMD Radeon Polaris"
echo "    VRAM (Total): 8 GB"
echo "    Metal Support: Metal 3"
echo ""
echo "  NOTE: Do NOT connect a display to the eGPU."
echo "  Display output will cause a kernel panic."
echo "  Use 'Prefer External GPU' in app settings for offscreen acceleration."
echo ""
