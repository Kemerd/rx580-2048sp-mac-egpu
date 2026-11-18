#!/usr/bin/env python3
"""
=============================================================================
  RX 580 2048SP (1002:6FDF)  ->  RX 570 (1002:67DF) VBIOS patcher
=============================================================================

  Takes a VBIOS dump from the card and writes a patched copy next to it.
  The input file is never modified.

  Exactly three things change, everything else (clocks, voltages, fan
  curve, memory timings) stays byte-identical to the dump:

    1. Strap at 0xD4:   F0 FD E6 0F -> F0 7D E6 0F
       This is what the GPU actually reports on the PCI bus. One bit
       flips, and that bit is the difference between 6FDF and 67DF.

    2. Device ID in every PCIR header (legacy image + UEFI/GOP image):
       DF 6F -> DF 67, so the option ROM still matches the device.

    3. Legacy checksum byte at 0x21, recomputed so the legacy image
       sums to zero again.

  Usage:
      python3 vbios_patch.py <dump.rom> [output.rom]
=============================================================================
"""

import hashlib
import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
#  Constants for this specific card family
# ---------------------------------------------------------------------------
STRAP_OFFSET = 0xD4
STRAP_STOCK = bytes.fromhex("f0fde60f")    # reports 6FDF
STRAP_RX570 = bytes.fromhex("f07de60f")    # reports 67DF

VENDOR_AMD = 0x1002
DEVICE_OLD = 0x6FDF
DEVICE_NEW = 0x67DF

CHECKSUM_OFFSET = 0x21                     # ATOM legacy image checksum byte


def fail(message):
    """Bail out loudly. A half-patched ROM is worse than no ROM."""
    print(f"ABORT: {message}")
    sys.exit(1)


def walk_images(rom):
    """
    Yield (image_offset, pcir_offset, image_length) for each option ROM
    image in the file, following the chain until the 'last image' flag.
    """
    offset = 0
    while offset + 0x1A <= len(rom):
        # Every image starts with the 55 AA option ROM signature
        if rom[offset:offset + 2] != b"\x55\xaa":
            break

        # Pointer to the PCI data structure lives at 0x18 of the image
        pcir = offset + struct.unpack_from("<H", rom, offset + 0x18)[0]
        if rom[pcir:pcir + 4] != b"PCIR":
            break

        # Image length is stored in 512 byte blocks
        length = struct.unpack_from("<H", rom, pcir + 0x10)[0] * 512
        yield offset, pcir, length

        # Bit 7 of the indicator byte marks the final image
        if rom[pcir + 0x15] & 0x80 or length == 0:
            break
        offset += length


def legacy_sum(rom):
    """8 bit sum over the legacy image. A valid image sums to zero."""
    length = rom[2] * 512
    return sum(rom[:length]) & 0xFF


def main():
    if len(sys.argv) < 2:
        fail("usage: vbios_patch.py <dump.rom> [output.rom]")

    # -----------------------------------------------------------------------
    #  Load the dump and work out where the result goes
    # -----------------------------------------------------------------------
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_name(src.stem + "_67DF.rom")
    if dst.exists():
        fail(f"{dst} already exists, not overwriting it")

    original = src.read_bytes()
    rom = bytearray(original)
    print(f"Input : {src}  ({len(rom)} bytes)")
    print(f"SHA256: {hashlib.sha256(original).hexdigest()}")

    # -----------------------------------------------------------------------
    #  Sanity checks. If any of these miss, this is not the ROM we think
    #  it is and nothing gets written.
    # -----------------------------------------------------------------------
    if len(rom) not in (262144, 524288):
        fail(f"unexpected ROM size {len(rom)}, expected 256 KB or 512 KB")
    if rom[:2] != b"\x55\xaa":
        fail("missing 55 AA option ROM signature")

    strap = bytes(rom[STRAP_OFFSET:STRAP_OFFSET + 4])
    if strap == STRAP_RX570:
        fail("strap already reads F0 7D E6 0F, this ROM is already patched")
    if strap != STRAP_STOCK:
        fail(f"strap at 0xD4 is {strap.hex(' ')}, expected f0 fd e6 0f")

    # The stock dump should carry a valid checksum. If it does not, the
    # dump itself may be bad, so say so before touching anything.
    if legacy_sum(rom) != 0:
        print("WARNING: input legacy checksum is already invalid, dump may be corrupt")

    # -----------------------------------------------------------------------
    #  1. Strap
    # -----------------------------------------------------------------------
    rom[STRAP_OFFSET:STRAP_OFFSET + 4] = STRAP_RX570
    print(f"Strap  0x{STRAP_OFFSET:05X}: {STRAP_STOCK.hex(' ')} -> {STRAP_RX570.hex(' ')}")

    # -----------------------------------------------------------------------
    #  2. PCIR device IDs
    # -----------------------------------------------------------------------
    patched_headers = 0
    for image, pcir, length in walk_images(rom):
        vendor, device = struct.unpack_from("<HH", rom, pcir + 4)
        if vendor == VENDOR_AMD and device == DEVICE_OLD:
            struct.pack_into("<H", rom, pcir + 6, DEVICE_NEW)
            patched_headers += 1
            print(f"PCIR   0x{pcir:05X}: device {DEVICE_OLD:04X} -> {DEVICE_NEW:04X}")

    if patched_headers == 0:
        fail("no PCIR header with device ID 6FDF found")

    # -----------------------------------------------------------------------
    #  3. Legacy checksum
    # -----------------------------------------------------------------------
    old_checksum = rom[CHECKSUM_OFFSET]
    rom[CHECKSUM_OFFSET] = (old_checksum - legacy_sum(rom)) & 0xFF
    print(f"Csum   0x{CHECKSUM_OFFSET:05X}: {old_checksum:02X} -> {rom[CHECKSUM_OFFSET]:02X}")

    if legacy_sum(rom) != 0:
        fail("checksum did not come out to zero")

    # -----------------------------------------------------------------------
    #  Final audit: list every byte that differs so nothing sneaks in
    # -----------------------------------------------------------------------
    changed = [i for i in range(len(rom)) if rom[i] != original[i]]
    print(f"\n{len(changed)} bytes changed:")
    for i in changed:
        print(f"  0x{i:05X}: {original[i]:02X} -> {rom[i]:02X}")

    # Strap bit + one byte per PCIR header + checksum, nothing more
    if len(changed) != 1 + patched_headers + 1:
        fail("unexpected number of changed bytes")

    dst.write_bytes(rom)
    print(f"\nOutput: {dst}")
    print(f"SHA256: {hashlib.sha256(bytes(rom)).hexdigest()}")


if __name__ == "__main__":
    main()
