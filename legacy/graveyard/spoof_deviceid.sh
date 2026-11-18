#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${CYAN}=== Device-ID Spoof via NVRAM ===${NC}"
echo -e "  Spoofing GPU device-id: 0x6FDF -> 0x67DF"
echo ""

# The EFI device path for the eGPU:
# PciRoot(0x0)/Pci(0x1,0x1)/Pci(0x0,0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)
#
# We inject device-id = 0x67DF (little-endian: DF 67 00 00)
# into the GPU's IORegistry properties at firmware boot time.
#
# The NVRAM variable "device-properties" uses Apple's EFI device property protocol.
# Format: binary blob mapping EFI device paths to property key-value pairs.
#
# We'll use a Python script to build the binary because the format is precise.

python3 << 'PYEOF'
import struct
import subprocess
import sys

def encode_utf16(s):
    """Encode string as null-terminated UTF-16LE"""
    return s.encode('utf-16-le') + b'\x00\x00'

def build_pci_node(func, dev):
    """Build an ACPI/PCI device path node"""
    # Type 1 (Hardware), Subtype 1 (PCI)
    node = struct.pack('<BBHBB', 0x01, 0x01, 6, func, dev)
    return node

def build_acpi_root():
    """Build ACPI root device path node - PciRoot(0x0)"""
    # Type 2 (ACPI), Subtype 1 (ACPI Device Path)
    # HID = PNP0A03 (0x41D0, 0x0A03) for PCI root
    # UID = 0
    hid = 0x0A0341D0
    uid = 0x00000000
    node = struct.pack('<BBHII', 0x02, 0x01, 12, hid, uid)
    return node

def build_end_node():
    """Build end-of-device-path node"""
    return struct.pack('<BBH', 0x7F, 0xFF, 4)

def build_device_path():
    """Build the full EFI device path for our GPU"""
    # PciRoot(0x0)/Pci(0x1,0x1)/Pci(0x0,0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)
    path = build_acpi_root()
    path += build_pci_node(0x1, 0x1)   # Pci(0x1,0x1)
    path += build_pci_node(0x0, 0x0)   # Pci(0x0,0x0)
    path += build_pci_node(0x0, 0x1)   # Pci(0x1,0x0)
    path += build_pci_node(0x0, 0x0)   # Pci(0x0,0x0)
    path += build_pci_node(0x0, 0x1)   # Pci(0x1,0x0)
    path += build_pci_node(0x0, 0x0)   # Pci(0x0,0x0)
    path += build_end_node()
    return path

def build_property(name, value):
    """Build a single property entry (name as UTF-16LE + value bytes)"""
    name_data = encode_utf16(name)
    name_size = len(name_data)
    value_size = len(value)
    return struct.pack('<II', name_size, value_size) + name_data + value

def build_device_properties():
    """Build the full device-properties NVRAM blob"""
    device_path = build_device_path()
    
    # Property: device-id = 0x67DF (little-endian: DF 67 00 00)
    prop1 = build_property("device-id", struct.pack('<I', 0x67DF))
    
    # Calculate sizes
    properties_data = prop1
    num_properties = 1
    
    # Device entry: size(4) + device_path + num_properties(4) + properties
    device_entry_size = 4 + len(device_path) + 4 + len(properties_data)
    device_entry = struct.pack('<I', device_entry_size)
    device_entry += device_path
    device_entry += struct.pack('<I', num_properties)
    device_entry += properties_data
    
    # Full blob: size(4) + count(4) + entries
    num_devices = 1
    total_size = 4 + 4 + len(device_entry)
    blob = struct.pack('<II', total_size, num_devices)
    blob += device_entry
    
    return blob

# Build the binary blob
blob = build_device_properties()

# Convert to hex string for nvram command
# nvram expects %XX encoding for non-printable bytes
hex_str = ''.join(f'%{b:02x}' for b in blob)

print(f"Device properties blob size: {len(blob)} bytes")
print(f"Hex: {blob.hex()}")
print()

# Set the NVRAM variable
nvram_cmd = f'sudo nvram 4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14:device-properties={hex_str}'

print("Setting NVRAM device-properties...")
result = subprocess.run(nvram_cmd, shell=True, capture_output=True, text=True)
if result.returncode == 0:
    print("SUCCESS! device-properties set in NVRAM")
else:
    print(f"FAILED: {result.stderr}")
    sys.exit(1)

# Verify
print()
print("Verifying NVRAM variable exists...")
result = subprocess.run(['nvram', '4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14:device-properties'], 
                       capture_output=True, text=True)
if result.returncode == 0:
    print("VERIFIED - device-properties is set in NVRAM")
else:
    print("WARNING - could not verify")

PYEOF

echo ""
echo -e "${GREEN}=== DONE ===${NC}"
echo ""
echo -e "  ${YELLOW}REBOOT NOW${NC} with eGPU plugged in."
echo "  The firmware will inject device-id=0x67DF before macOS loads."
echo "  AMDSupport will see a standard RX 580 and load full drivers."
echo ""
echo "  To revert: sudo nvram -d 4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14:device-properties"
echo ""
