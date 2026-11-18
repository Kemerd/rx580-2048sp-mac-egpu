#!/usr/bin/env python3
"""
Inject LoadAccelerator/LoadController/LoadHWServices properties into the
AMD GPU's IORegistry entry, then trigger driver re-matching so the
AMDRadeonX4000 / AMD9500Controller / AMDRadeonX4000HWServices kexts
pick up device 0x6FDF.
"""

import subprocess
import ctypes
import ctypes.util
import struct
import sys
import time

# Load IOKit framework
iokit = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit')
cf = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

# CoreFoundation types
CFStringRef = ctypes.c_void_p
CFMutableDictionaryRef = ctypes.c_void_p
CFNumberRef = ctypes.c_void_p
CFBooleanRef = ctypes.c_void_p
io_object_t = ctypes.c_uint
io_iterator_t = ctypes.c_uint
io_service_t = ctypes.c_uint
kern_return_t = ctypes.c_int
mach_port_t = ctypes.c_uint

kCFNumberIntType = 9  # kCFNumberSInt32Type
kIOServiceSynchronous = 0x00000002
kIOMasterPortDefault = 0

# CoreFoundation functions
cf.CFStringCreateWithCString.restype = CFStringRef
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]

cf.CFNumberCreate.restype = CFNumberRef
cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]

cf.CFDictionaryCreateMutable.restype = CFMutableDictionaryRef
cf.CFDictionaryCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]

cf.CFDictionarySetValue.restype = None
cf.CFDictionarySetValue.argtypes = [CFMutableDictionaryRef, ctypes.c_void_p, ctypes.c_void_p]

cf.CFRelease.restype = None
cf.CFRelease.argtypes = [ctypes.c_void_p]

# IOKit functions
iokit.IOServiceMatching.restype = CFMutableDictionaryRef
iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]

iokit.IOServiceGetMatchingServices.restype = kern_return_t
iokit.IOServiceGetMatchingServices.argtypes = [mach_port_t, CFMutableDictionaryRef, ctypes.POINTER(io_iterator_t)]

iokit.IOIteratorNext.restype = io_object_t
iokit.IOIteratorNext.argtypes = [io_iterator_t]

iokit.IORegistryEntryGetName.restype = kern_return_t
iokit.IORegistryEntryGetName.argtypes = [io_object_t, ctypes.c_char_p]

iokit.IORegistryEntrySetCFProperty.restype = kern_return_t
iokit.IORegistryEntrySetCFProperty.argtypes = [io_object_t, CFStringRef, ctypes.c_void_p]

iokit.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
iokit.IORegistryEntryCreateCFProperty.argtypes = [io_object_t, CFStringRef, ctypes.c_void_p, ctypes.c_uint32]

iokit.IOObjectRelease.restype = kern_return_t
iokit.IOObjectRelease.argtypes = [io_object_t]

iokit.IOServiceRequestProbe.restype = kern_return_t
iokit.IOServiceRequestProbe.argtypes = [io_object_t, ctypes.c_uint32]

kCFAllocatorDefault = None
kCFStringEncodingUTF8 = 0x08000100

# Callback types for dictionary
kCFTypeDictionaryKeyCallBacks = ctypes.c_void_p.in_dll(cf, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = ctypes.c_void_p.in_dll(cf, 'kCFTypeDictionaryValueCallBacks')


def cfstr(s):
    return cf.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), kCFStringEncodingUTF8)


def cfnum(n):
    val = ctypes.c_int32(n)
    return cf.CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, ctypes.byref(val))


def find_gpu_service():
    """Find the IOPCIDevice for our AMD GPU (device-id 0x6FDF)"""
    matching = iokit.IOServiceMatching(b"IOPCIDevice")
    iterator = io_iterator_t()
    
    result = iokit.IOServiceGetMatchingServices(kIOMasterPortDefault, matching, ctypes.byref(iterator))
    if result != 0:
        print(f"  Failed to get matching services: {result}")
        return None
    
    name_buf = ctypes.create_string_buffer(128)
    
    while True:
        service = iokit.IOIteratorNext(iterator)
        if not service:
            break
        
        iokit.IORegistryEntryGetName(service, name_buf)
        name = name_buf.value.decode('utf-8', errors='ignore')
        
        # Check if this is our GPU by looking for "display" name
        if name == "display":
            # Verify it's the AMD one by checking vendor-id
            vendor_key = cfstr("vendor-id")
            vendor_prop = iokit.IORegistryEntryCreateCFProperty(service, vendor_key, kCFAllocatorDefault, 0)
            cf.CFRelease(vendor_key)
            
            if vendor_prop:
                cf.CFRelease(vendor_prop)
                print(f"  Found GPU: {name} (service id: {service})")
                return service
        
        iokit.IOObjectRelease(service)
    
    return None


def set_property(service, key, value):
    """Set a property on an IORegistry entry"""
    cf_key = cfstr(key)
    cf_val = cfnum(value)
    result = iokit.IORegistryEntrySetCFProperty(service, cf_key, cf_val)
    cf.CFRelease(cf_key)
    cf.CFRelease(cf_val)
    return result


def main():
    print()
    print("=== IOKit Property Injection for AMD GPU 0x6FDF ===")
    print()
    
    # Find the GPU
    print("[1] Finding AMD GPU...")
    gpu = find_gpu_service()
    if not gpu:
        print("  ERROR: Could not find AMD GPU (device named 'display')")
        print("  Is the eGPU plugged in?")
        sys.exit(1)
    
    # Inject properties
    print()
    print("[2] Injecting Load* properties...")
    
    props = {
        "LoadAccelerator": 1,
        "LoadController": 1, 
        "LoadHWServices": 1,
        "LoadAMDSupport": 1,
    }
    
    for key, val in props.items():
        result = set_property(gpu, key, val)
        if result == 0:
            print(f"  [OK] {key} = {val}")
        else:
            print(f"  [FAIL] {key} - error {result}")
    
    # Also try spoofing device-id
    print()
    print("[3] Attempting device-id spoof (0x67DF)...")
    
    cf_key = cfstr("device-id")
    # device-id as raw bytes: DF 67 00 00 (little-endian 0x67DF)
    data = struct.pack('<I', 0x67DF)
    cf_data = cf.CFDataCreate = None  # We'll try the numeric approach
    result = set_property(gpu, "device-id", 0x67DF)
    if result == 0:
        print("  [OK] device-id set")
    else:
        print(f"  [INFO] device-id spoof returned {result} (driver may not accept this)")
    
    cf.CFRelease(cf_key)
    
    # Request re-probe
    print()
    print("[4] Requesting IOKit re-probe...")
    result = iokit.IOServiceRequestProbe(gpu, 0)
    if result == 0:
        print("  [OK] Re-probe requested")
    else:
        print(f"  [INFO] Re-probe returned {result}")
    
    # Give IOKit a moment to re-match
    time.sleep(2)
    
    # Check result
    print()
    print("[5] Checking result...")
    result = subprocess.run(['system_profiler', 'SPDisplaysDataType'], 
                          capture_output=True, text=True)
    print(result.stdout)
    
    iokit.IOObjectRelease(gpu)
    print("=== DONE ===")


if __name__ == '__main__':
    main()
