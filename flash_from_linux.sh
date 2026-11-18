#!/bin/bash
# =============================================================================
#  RX 580 2048SP (6FDF) -> RX 570 (67DF) flash helper
#
#  Run this from the live Linux session, with the eGPU plugged in:
#
#      sudo bash flash_from_linux.sh
#
#  What it does, in order:
#    1. Authorises the Thunderbolt enclosure and finds the card
#    2. Dumps the card's current VBIOS twice and checks both dumps match
#    3. Patches a copy of that dump with vbios_patch.py
#    4. Stops and asks before writing anything to the card
#    5. Flashes, then reads the ROM back and compares it to what we wrote
#
#  Nothing is written to the card before step 4. Backups land in ./backups
#  next to this script, so they survive the reboot back into macOS.
# =============================================================================

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$KIT_DIR/backups"
STAMP="$(date +%Y%m%d_%H%M%S)"

# The live medium is FAT, so nothing on it is executable. Work from a
# copy of the flash tool in /tmp instead.
FLASH="/tmp/amdvbflash"

say()  { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}  [WARN]${NC} $*"; }
die()  { echo -e "${RED}  [STOP]${NC} $*"; exit 1; }

# -----------------------------------------------------------------------------
#  Preflight
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0"
[ -f "$KIT_DIR/amdvbflash" ]     || die "amdvbflash missing from $KIT_DIR"
[ -f "$KIT_DIR/vbios_patch.py" ] || die "vbios_patch.py missing from $KIT_DIR"

cp "$KIT_DIR/amdvbflash" "$FLASH" && chmod +x "$FLASH" || die "could not stage amdvbflash"

# The live session mounts its boot partition read-only. Flip it to
# read-write so the backups land on disk and not in RAM.
if ! mkdir -p "$BACKUP_DIR" 2>/dev/null || ! touch "$BACKUP_DIR/.write_test" 2>/dev/null; then
    KIT_MOUNT="$(df --output=target "$KIT_DIR" | tail -1)"
    mount -o remount,rw "$KIT_MOUNT" 2>/dev/null
fi

# Still read-only? Fall back to the big LINUXROOT partition next door.
if ! mkdir -p "$BACKUP_DIR" 2>/dev/null || ! touch "$BACKUP_DIR/.write_test" 2>/dev/null; then
    mkdir -p /mnt/ubuntu_part
    mount -L LINUXROOT /mnt/ubuntu_part 2>/dev/null || die "No writable place for backups. Not continuing without one."
    BACKUP_DIR="/mnt/ubuntu_part/egpu_backups"
    mkdir -p "$BACKUP_DIR" || die "cannot write to $BACKUP_DIR"
fi
rm -f "$BACKUP_DIR/.write_test"
ok "Backups go to $BACKUP_DIR"

# -----------------------------------------------------------------------------
#  Step 1: Thunderbolt + card detection
# -----------------------------------------------------------------------------
say "Step 1/5: Looking for the eGPU"

# Enclosures that show up unauthorised stay invisible on the PCI bus
# until this flag is set. Harmless if they are already authorised.
for auth in /sys/bus/thunderbolt/devices/*/authorized; do
    [ -f "$auth" ] || continue
    if [ "$(cat "$auth")" = "0" ]; then
        echo 1 > "$auth" 2>/dev/null && ok "Authorised $(dirname "$auth" | xargs basename)"
    fi
done

# Give the PCI tunnel a moment to come up, then rescan
sleep 3
echo 1 > /sys/bus/pci/rescan 2>/dev/null
sleep 2

echo ""
lspci -nn | grep -i -E "1002:" || true
echo ""

if lspci -n | grep -q "1002:67df"; then
    die "Card already reports 1002:67DF. It looks flashed already, nothing to do."
fi
lspci -n | grep -q "1002:6fdf" || die "No 1002:6FDF card on the PCI bus. Is the enclosure powered and plugged in?"
ok "Found the 2048SP (1002:6FDF)"

# The amdgpu driver holds the card while loaded. Let go of it so the
# flash tool has the device to itself. The desktop runs on the Intel GPU.
CARD_ADDR="$(lspci -Dn | awk '/1002:6fdf/ {print $1; exit}')"
if [ -e "/sys/bus/pci/devices/$CARD_ADDR/driver/unbind" ]; then
    echo "$CARD_ADDR" > "/sys/bus/pci/devices/$CARD_ADDR/driver/unbind" 2>/dev/null \
        && ok "Detached the Linux GPU driver from $CARD_ADDR"
fi

echo ""
"$FLASH" -i
echo ""

# With the Intel iGPU as the only other graphics device, the card is
# adapter 0. Let that be overridden in case the list above says otherwise.
read -r -p "Adapter number of the RX 580 from the list above [0]: " ADAPTER
ADAPTER="${ADAPTER:-0}"

# -----------------------------------------------------------------------------
#  Step 2: Back up the stock VBIOS, twice
# -----------------------------------------------------------------------------
say "Step 2/5: Backing up the card's current VBIOS"

STOCK="$BACKUP_DIR/stock_${STAMP}.rom"
CHECK="/tmp/stock_check.rom"

"$FLASH" -s "$ADAPTER" "$STOCK" || die "VBIOS dump failed"
"$FLASH" -s "$ADAPTER" "$CHECK" || die "second VBIOS dump failed"

# Two reads that disagree mean the link is flaky. Do not flash over that.
cmp -s "$STOCK" "$CHECK" || die "The two dumps differ. Reads are unreliable, not flashing."
sync
ok "Stock VBIOS saved: $STOCK"
sha256sum "$STOCK"

# -----------------------------------------------------------------------------
#  Step 3: Patch a copy
# -----------------------------------------------------------------------------
say "Step 3/5: Patching a copy of the dump"

PATCHED="$BACKUP_DIR/patched_${STAMP}.rom"
python3 "$KIT_DIR/vbios_patch.py" "$STOCK" "$PATCHED" || die "Patcher refused this ROM. Nothing was written to the card."
sync
ok "Patched ROM ready: $PATCHED"

# -----------------------------------------------------------------------------
#  Step 4: Point of no return
# -----------------------------------------------------------------------------
say "Step 4/5: Ready to flash"
echo ""
echo -e "  This writes ${YELLOW}$(basename "$PATCHED")${NC} to adapter ${YELLOW}$ADAPTER${NC}."
echo "  Do not unplug the enclosure or cut power while it runs."
echo "  The stock ROM is saved and can be flashed back the same way."
echo ""
read -r -p "  Type FLASH to continue, anything else to quit: " ANSWER
[ "$ANSWER" = "FLASH" ] || die "Cancelled. The card was not modified."

# -----------------------------------------------------------------------------
#  Step 5: Flash and verify
# -----------------------------------------------------------------------------
say "Step 5/5: Flashing"

"$FLASH" -unlockrom "$ADAPTER" || warn "unlockrom reported an error, continuing"

if ! "$FLASH" -p "$ADAPTER" "$PATCHED"; then
    # The tool can refuse because the new ROM carries a different device
    # ID than the card. That mismatch is the whole point here, so offer
    # the forced path, but only on a second explicit yes.
    warn "Normal flash was refused."
    read -r -p "  Type FORCE to retry with -f, anything else to quit: " ANSWER
    [ "$ANSWER" = "FORCE" ] || die "Stopped. Dump the ROM again to see what state the card is in."
    "$FLASH" -f -p "$ADAPTER" "$PATCHED" || die "Forced flash failed. Do NOT power off. Flash $STOCK back with: $FLASH -f -p $ADAPTER $STOCK"
fi

# Read the chip back and compare byte for byte with what we meant to write
VERIFY="$BACKUP_DIR/readback_${STAMP}.rom"
"$FLASH" -s "$ADAPTER" "$VERIFY" || die "Could not read the ROM back after flashing"
sync

if cmp -s "$VERIFY" "$PATCHED"; then
    ok "Readback matches the patched ROM"
else
    die "Readback does NOT match. Do NOT power off. Flash stock back with: $FLASH -f -p $ADAPTER $STOCK"
fi

echo ""
echo -e "${GREEN}  Flash complete.${NC}"
echo "  Shut down, power-cycle the enclosure, then boot macOS."
echo "  The card reports its new ID only after it has lost power once."
echo ""
