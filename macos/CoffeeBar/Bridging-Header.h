// Bridging header for the CoffeeBar app target.
// ThermalMonitor reads temperature sensors through IOHID. The SDK declares the client and service
// types and some functions (hidsystem/IOHIDEventSystemClient.h, IOHIDServiceClient.h); the rest
// below are private (the same set as freedomtan/sensors). CF_RETURNS_RETAINED lets Swift manage
// the Create/Copy results with ARC.

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client, CFDictionaryRef _Nonnull matching);
CFTypeRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(CFTypeRef _Nonnull event, int32_t field);
