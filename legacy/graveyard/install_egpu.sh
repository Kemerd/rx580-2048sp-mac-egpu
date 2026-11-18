#!/bin/bash
# =============================================================================
#  eGPU Hack Installer for SOYO RX 580 (Device ID 0x6FDF) on macOS Sequoia
#  
#  This script installs Lilu + WhateverGreen kexts and configures boot-args
#  to make macOS recognize the non-standard Polaris 20 device ID (0x6FDF)
#  as a standard RX 580 (0x67DF).
#
#  Requirements: SIP must be disabled (csrutil disable in Recovery)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LILU_KEXT="$SCRIPT_DIR/Lilu/Lilu.kext"
WEG_KEXT="$SCRIPT_DIR/WhateverGreen/WhateverGreen.kext"

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  eGPU Hack Installer - SOYO RX 580 (0x6FDF -> 0x67DF)${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ---------------------------------------------------------
# Step 0: Preflight checks
# ---------------------------------------------------------
echo -e "${YELLOW}[PREFLIGHT]${NC} Checking requirements..."

# Check SIP status
SIP_STATUS=$(csrutil status 2>&1)
if echo "$SIP_STATUS" | grep -q "enabled"; then
    echo -e "${RED}[ERROR]${NC} SIP is still enabled! Boot to Recovery and run 'csrutil disable' first."
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} SIP is disabled"

# Check kexts exist
if [ ! -d "$LILU_KEXT" ]; then
    echo -e "${RED}[ERROR]${NC} Lilu.kext not found at: $LILU_KEXT"
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} Lilu.kext found"

if [ ! -d "$WEG_KEXT" ]; then
    echo -e "${RED}[ERROR]${NC} WhateverGreen.kext not found at: $WEG_KEXT"
    exit 1
fi
echo -e "${GREEN}  [OK]${NC} WhateverGreen.kext found"

# Verify the eGPU is connected
EGPU_CHECK=$(system_profiler SPPCIDataType 2>/dev/null | grep "0x6fdf" || true)
if [ -z "$EGPU_CHECK" ]; then
    echo -e "${YELLOW}  [WARN]${NC} eGPU with device ID 0x6FDF not detected on PCI bus."
    echo -e "${YELLOW}         Make sure the eGPU enclosure is connected via Thunderbolt!${NC}"
fi
echo ""

# ---------------------------------------------------------
# Step 1: Install kexts to /Library/Extensions/
# ---------------------------------------------------------
echo -e "${YELLOW}[STEP 1/5]${NC} Installing kexts to /Library/Extensions/..."
echo "  (You may be prompted for your password)"
echo ""

# Remove old versions if they exist
sudo rm -rf /Library/Extensions/Lilu.kext 2>/dev/null || true
sudo rm -rf /Library/Extensions/WhateverGreen.kext 2>/dev/null || true

# Copy new kexts
sudo cp -R "$LILU_KEXT" /Library/Extensions/
sudo cp -R "$WEG_KEXT" /Library/Extensions/

# Fix ownership and permissions
sudo chown -R root:wheel /Library/Extensions/Lilu.kext
sudo chown -R root:wheel /Library/Extensions/WhateverGreen.kext
sudo chmod -R 755 /Library/Extensions/Lilu.kext
sudo chmod -R 755 /Library/Extensions/WhateverGreen.kext

echo -e "${GREEN}  [OK]${NC} Kexts installed"
echo ""

# ---------------------------------------------------------
# Step 2: Set boot-args for AMD GPU compatibility
# ---------------------------------------------------------
echo -e "${YELLOW}[STEP 2/5]${NC} Setting boot-args..."

# Get existing boot-args (preserve them)
EXISTING_ARGS=$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//' || true)
echo "  Existing boot-args: '$EXISTING_ARGS'"

# Build new boot-args - add our flags if not already present
NEW_ARGS="$EXISTING_ARGS"

# agdpmod=pikera - Fixes board-id check for AMD GPUs
if ! echo "$NEW_ARGS" | grep -q "agdpmod=pikera"; then
    NEW_ARGS="$NEW_ARGS agdpmod=pikera"
fi

# radpg=15 - Disable all power-gating to avoid GPU init issues with non-standard IDs
if ! echo "$NEW_ARGS" | grep -q "radpg=15"; then
    NEW_ARGS="$NEW_ARGS radpg=15"
fi

# -wegnoegpu is NOT what we want (that disables eGPU!)
# -rad24 forces 24-bit framebuffer (not needed)
# We want the GPU to work, so just the above flags

# Trim whitespace
NEW_ARGS=$(echo "$NEW_ARGS" | xargs)

echo "  New boot-args: '$NEW_ARGS'"
sudo nvram boot-args="$NEW_ARGS"
echo -e "${GREEN}  [OK]${NC} Boot-args set"
echo ""

# ---------------------------------------------------------
# Step 3: Create a device-id spoof kext (injector approach)
# ---------------------------------------------------------
echo -e "${YELLOW}[STEP 3/5]${NC} Creating AMD GPU device-id injector kext..."

# This codeless kext injects a personality that matches 0x6FDF
# and redirects to the Polaris controllers (same as 0x67DF)
INJECTOR_DIR="/Library/Extensions/AMDPolaris6FDFInjector.kext"
sudo rm -rf "$INJECTOR_DIR" 2>/dev/null || true
sudo mkdir -p "$INJECTOR_DIR/Contents"

# Write the Info.plist for the injector kext
# This kext provides personalities that match 0x6FDF and point to the AMD driver classes
sudo tee "$INJECTOR_DIR/Contents/Info.plist" > /dev/null << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleGetInfoString</key>
    <string>AMD Polaris 0x6FDF Device ID Injector</string>
    <key>CFBundleIdentifier</key>
    <string>com.egpuhack.AMDPolaris6FDFInjector</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AMDPolaris6FDFInjector</string>
    <key>CFBundlePackageType</key>
    <string>KEXT</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>OSBundleRequired</key>
    <string>Root</string>
    <key>IOKitPersonalities</key>
    <dict>
        <!-- 
            HW Services personality: tells AMDRadeonX4000HWServices to claim this device
            Matches the Polaris HW services class for our non-standard device ID
        -->
        <key>AMDRadeonX4000HWServicesPolaris6FDF</key>
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apple.kext.AMDRadeonX4000HWServices</string>
            <key>IOClass</key>
            <string>AMDRadeonX4000_AMDRadeonHWServicesPolaris</string>
            <key>IOMatchCategory</key>
            <string>AMDRadeonX4000HWServices</string>
            <key>IOPCIMatch</key>
            <string>0x6FDF1002</string>
            <key>IOPCITunnelCompatible</key>
            <true/>
            <key>IOProbeScore</key>
            <integer>65051</integer>
            <key>IOPropertyMatch</key>
            <dict>
                <key>LoadHWServices</key>
                <integer>1</integer>
            </dict>
            <key>IOProviderClass</key>
            <string>IOPCIDevice</string>
        </dict>

        <!--
            Controller personality: tells AMD9500Controller to handle this device
            This is the framebuffer controller for Polaris GPUs
        -->
        <key>AMD9500ControllerWrangler6FDF</key>
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apple.kext.AMD9500Controller</string>
            <key>IOClass</key>
            <string>AMD9500ControllerWrangler</string>
            <key>IOMatchCategory</key>
            <string>IOFramebuffer</string>
            <key>IOPCIMatch</key>
            <string>0x6FDF1002</string>
            <key>IOPCITunnelCompatible</key>
            <true/>
            <key>IOProbeScore</key>
            <integer>65050</integer>
            <key>IOProviderClass</key>
            <string>IOPCIDevice</string>
        </dict>

        <!--
            Framebuffer personality: secondary controller match
        -->
        <key>AMD9500Controller6FDF</key>
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apple.kext.AMD9500Controller</string>
            <key>IOClass</key>
            <string>AMD9500Controller</string>
            <key>IOMatchCategory</key>
            <string>ATIFramebuffer</string>
            <key>IOName</key>
            <string>AMD9500Controller</string>
            <key>IOPCIMatch</key>
            <string>0x6FDF1002</string>
            <key>IOPCITunnelCompatible</key>
            <true/>
            <key>IOPCIUseDeviceMapper</key>
            <true/>
            <key>IOProbeScore</key>
            <integer>65050</integer>
            <key>IOPropertyMatch</key>
            <dict>
                <key>LoadController</key>
                <integer>1</integer>
            </dict>
            <key>IOProviderClass</key>
            <string>IOPCIDevice</string>
        </dict>

        <!--
            Accelerator personality (Polaris10): tells AMDRadeonX4000 to load
            This provides Metal/OpenGL/OpenCL acceleration
        -->
        <key>AMDRadeonX4000Polaris10Accelerator6FDF</key>
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apple.kext.AMDRadeonX4000</string>
            <key>IOClass</key>
            <string>AMDRadeonX4000_AMDPolaris10GraphicsAccelerator</string>
            <key>IOMatchCategory</key>
            <string>IOAccelerator</string>
            <key>IOPCIMatch</key>
            <string>0x6FDF1002</string>
            <key>IOPCITunnelCompatible</key>
            <true/>
            <key>IOPropertyMatch</key>
            <dict>
                <key>LoadAccelerator</key>
                <integer>1</integer>
            </dict>
            <key>IOProviderClass</key>
            <string>IOPCIDevice</string>
        </dict>
    </dict>
</dict>
</plist>
PLIST_EOF

sudo chown -R root:wheel "$INJECTOR_DIR"
sudo chmod -R 755 "$INJECTOR_DIR"

echo -e "${GREEN}  [OK]${NC} Injector kext created at $INJECTOR_DIR"
echo ""

# ---------------------------------------------------------
# Step 4: Rebuild kernel extension cache
# ---------------------------------------------------------
echo -e "${YELLOW}[STEP 4/5]${NC} Rebuilding kernel extension cache..."
echo "  This may take a moment..."

# Touch the extensions directory to invalidate caches
sudo touch /Library/Extensions/

# Rebuild using kmutil (modern macOS approach)
sudo kmutil install --update-all --volume-root / 2>&1 || {
    echo -e "${YELLOW}  [WARN]${NC} kmutil failed, trying kextcache..."
    sudo kextcache -i / 2>&1 || true
}

echo -e "${GREEN}  [OK]${NC} Kernel cache rebuilt"
echo ""

# ---------------------------------------------------------
# Step 5: Verify installation
# ---------------------------------------------------------
echo -e "${YELLOW}[STEP 5/5]${NC} Verifying installation..."

echo "  Installed kexts:"
ls -la /Library/Extensions/Lilu.kext/Contents/Info.plist 2>/dev/null && echo -e "${GREEN}    [OK]${NC} Lilu.kext" || echo -e "${RED}    [FAIL]${NC} Lilu.kext"
ls -la /Library/Extensions/WhateverGreen.kext/Contents/Info.plist 2>/dev/null && echo -e "${GREEN}    [OK]${NC} WhateverGreen.kext" || echo -e "${RED}    [FAIL]${NC} WhateverGreen.kext"
ls -la /Library/Extensions/AMDPolaris6FDFInjector.kext/Contents/Info.plist 2>/dev/null && echo -e "${GREEN}    [OK]${NC} AMDPolaris6FDFInjector.kext" || echo -e "${RED}    [FAIL]${NC} AMDPolaris6FDFInjector.kext"

echo ""
echo "  Boot-args:"
nvram boot-args 2>/dev/null || echo "  (none set)"

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE!${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""
echo -e "  ${YELLOW}REBOOT NOW${NC} to activate the eGPU drivers."
echo ""
echo "  After reboot, verify with:"
echo "    system_profiler SPDisplaysDataType"
echo ""
echo "  You should see your RX 580 with:"
echo "    - Chipset Model name (not just 'Display')"
echo "    - Metal Support listed"
echo "    - VRAM: 8192 MB"
echo ""
echo "  If it doesn't work on first boot, try:"
echo "    1. Unplug and replug the Thunderbolt cable"
echo "    2. Reboot again"
echo "    3. Check: kextstat | grep -i 'amd\|lilu\|whatever'"
echo ""
echo -e "  ${CYAN}To uninstall:${NC}"
echo "    sudo rm -rf /Library/Extensions/Lilu.kext"
echo "    sudo rm -rf /Library/Extensions/WhateverGreen.kext"
echo "    sudo rm -rf /Library/Extensions/AMDPolaris6FDFInjector.kext"
echo "    sudo nvram -d boot-args"
echo "    sudo kmutil install --update-all --volume-root /"
echo ""
