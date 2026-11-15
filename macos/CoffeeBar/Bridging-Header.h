// Bridging header for the CoffeeBar app target.
// Private IOHID API used by ThermalMonitor to read Apple Silicon temperature sensors.
// IOKit exports these symbols, but the SDK ships no header for them.

#include <CoreFoundation/CoreFoundation.h>
// Public: IOHIDEventSystemClientRef and IOHIDEventSystemClientCopyServices.
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>

typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
