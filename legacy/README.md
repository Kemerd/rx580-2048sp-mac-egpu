# Legacy: the software route

Everything in here predates the VBIOS flash. None of it is needed once the
card reports `1002:67DF`. It is kept as a record of what was tried, so nobody
has to try it again.

> [!CAUTION]
> These scripts modify NVRAM, `/Library/Extensions` and the macOS system
> volume. They need SIP and authenticated-root disabled, and they were written
> for one specific Mac. Read them before you run them. Better yet, do not run them.

## `kernel-collection-patch/`

`patch.sh` adds `0x6FDF1002` to the `IOPCIMatch` lists of `AMDRadeonX4000`,
`AMD9500Controller` and `AMDRadeonX4000HWServices` inside
`SystemKernelExtensions.kc`, then blesses a new snapshot.

- **What you get:** the card appears as `AMD Radeon Polaris`, 8 GB, Metal 3.
  Good for compute and offscreen rendering.
- **What you do not get:** display output. Connecting a monitor to the card
  panics the Mac inside `AMDRadeonX4000`.
- **What it costs:** SIP off, authenticated-root off, a broken system volume
  seal, and the patch is erased by every macOS update.
- **Also seen:** hot-plugging the unflashed card with this patch active hung
  WindowServer until the watchdog restarted it.

Tested on Sequoia 15.7.5 (24G624). To undo it properly, install a macOS update
(which lays down a fresh sealed system volume), confirm the seal is intact in
`diskutil apfs list`, and only then re-enable SIP and authenticated-root from
Recovery. Re-enabling authenticated-root on a broken seal can leave the Mac
unbootable.

## `graveyard/`

| Script | Idea | Why it failed |
|---|---|---|
| `install_egpu.sh` | Lilu + WhateverGreen + a codeless injector kext, plus `agdpmod=pikera radpg=15` boot-args | The kexts never loaded from the kernel collection, and the boot-args broke Metal on the Intel iGPU |
| `cleanup.sh` | Undo `install_egpu.sh` | This one works. It is the only reason the desktop came back |
| `mod_amd_drivers.sh` | Add `6FDF` to the AMD kexts' `Info.plist` files | The loaded drivers come from the prelinked kernel collection, not these plists |
| `spoof_deviceid.sh` | Spoof `device-id` through the NVRAM `device-properties` variable | Apple's firmware does not apply it to devices behind Thunderbolt |
| `inject_props.py` | Set `Load*` properties on the IORegistry entry from userspace and re-probe | `kIOReturnUnsupported` and `kIOReturnNotPrivileged` |

`install_egpu.sh` expects `Lilu.kext` and `WhateverGreen.kext` next to it.
They are not included here; get them from
[acidanthera](https://github.com/acidanthera) if you insist.
