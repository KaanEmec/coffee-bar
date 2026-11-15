// Bridging header for the CoffeeBar app target.
// Private IOKit HID functions that ThermalMonitor uses to read temperature sensors (the same set
// as freedomtan/sensors). Declared here with plain CF types and without the SDK's
// IOKit/hidsystem headers, so nothing clashes with Apple's declarations.
// The client, service and event objects are CF objects, so Swift manages them with ARC. These
// declarations carry no CF_RETURNS_RETAINED, so Swift imports the Create/Copy results as
// Unmanaged and ThermalMonitor takes them with takeRetainedValue().

#include <CoreFoundation/CoreFoundation.h>

CFTypeRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(CFTypeRef client, CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(CFTypeRef client);
CFTypeRef IOHIDServiceClientCopyProperty(CFTypeRef service, CFStringRef key);
CFTypeRef IOHIDServiceClientCopyEvent(CFTypeRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);
