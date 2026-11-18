#!/bin/bash
echo ""
echo "=== EMERGENCY CLEANUP - Removing all eGPU kexts ==="
echo ""

echo "[1] Removing kexts from /Library/Extensions/..."
sudo rm -rf /Library/Extensions/Lilu.kext
sudo rm -rf /Library/Extensions/WhateverGreen.kext
sudo rm -rf /Library/Extensions/AMDPolaris6FDFInjector.kext
echo "  Done."

echo ""
echo "[2] Clearing boot-args..."
sudo nvram -d boot-args 2>/dev/null
echo "  Done."

echo ""
echo "[3] Rebuilding kext cache..."
sudo kextcache -i / 2>&1
echo "  Done."

echo ""
echo "[4] Touching extensions to invalidate caches..."
sudo touch /System/Library/Extensions/ 2>/dev/null
sudo touch /Library/Extensions/ 2>/dev/null
echo "  Done."

echo ""
echo "=== CLEANUP COMPLETE ==="
echo "  REBOOT NOW to restore Metal support on Intel GPU."
echo "  After reboot your desktop should be normal again."
echo ""
