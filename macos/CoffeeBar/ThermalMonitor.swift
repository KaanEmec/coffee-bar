import Foundation
import IOKit

enum Sensor { case cpuDie, battery }
struct Reading { let sensor: Sensor; let celsius: Double }

/// Reads CPU die and battery temperatures without root. Apple Silicon: private IOHID sensors.
/// Intel: AppleSMC. Battery: IORegistry AppleSmartBattery, else the HID "gas gauge battery" sensor.
final class ThermalMonitor {
    let isAppleSilicon: Bool

    // HID objects are CF objects; ARC owns them. The client must outlive its services.
    private var hidClient: IOHIDEventSystemClient?
    private var cpuServices: [IOHIDServiceClient] = []
    private var batteryService: IOHIDServiceClient?
    private var smc: io_connect_t = 0
    private var smcKeys: [String] = []

    var thermalCritical: Bool { ProcessInfo.processInfo.thermalState == .critical }

    init() {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // True on Apple Silicon even when running under Rosetta.
        isAppleSilicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        openHID()
        if !isAppleSilicon { openSMC() }
    }

    deinit {
        if smc != 0 { IOServiceClose(smc) }
    }

    func read() -> [Reading] {
        var readings: [Reading] = []
        let cpu = isAppleSilicon
            ? cpuServices.compactMap { hidTemperature($0) }.max()
            : smcKeys.compactMap { smcTemperature($0) }.max()
        if let cpu { readings.append(Reading(sensor: .cpuDie, celsius: cpu)) }
        if let battery = smartBatteryTemperature() ?? batteryService.flatMap({ self.hidTemperature($0) }) {
            readings.append(Reading(sensor: .battery, celsius: battery))
        }
        return readings
    }

    // MARK: - IOHID (Apple Silicon die sensors, battery fallback)

    private static let temperatureEvent: Int64 = 15        // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16  // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    private func openHID() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        hidClient = client
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (IOHIDEventSystemClientCopyServices(client) as? [AnyObject] ?? [])
            .map { unsafeBitCast($0, to: IOHIDServiceClient.self) }
        var tdie: [IOHIDServiceClient] = []
        var fallback: [IOHIDServiceClient] = []
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String else { continue }
            if name.hasPrefix("PMU tdie") {
                tdie.append(service)
            } else if name.contains("tdie") || name.contains("MTR Temp") {
                fallback.append(service)
            } else if name.contains("gas gauge battery") {
                batteryService = service
            }
        }
        cpuServices = tdie.isEmpty ? fallback : tdie
    }

    private func hidTemperature(_ service: IOHIDServiceClient) -> Double? {
        guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0) else { return nil }
        return plausible(IOHIDEventGetFloatValue(event, Self.temperatureField))
    }

    // MARK: - AppleSMC (Intel die sensors)

    /// Raw SMCKeyData_t (80 bytes). Offsets: key 0, keyInfo.dataSize 28, keyInfo.dataType 32,
    /// result 40, data8 (command) 42, bytes 48.
    private func openSMC() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &smc) == kIOReturnSuccess else { smc = 0; return }
        smcKeys = ["TC0D", "TC0E", "TC0F"].filter { smcTemperature($0) != nil }
        if smcKeys.isEmpty && smcTemperature("TC0P") != nil { smcKeys = ["TC0P"] }
    }

    private func smcTemperature(_ key: String) -> Double? {
        guard smc != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: fourCC(key), toByteOffset: 0, as: UInt32.self)
            $0[42] = 9                                                     // kSMCGetKeyInfo
        }
        guard let info = smcCall(input) else { return nil }
        let (dataSize, dataType) = info.withUnsafeBytes {
            ($0.load(fromByteOffset: 28, as: UInt32.self), $0.load(fromByteOffset: 32, as: UInt32.self))
        }
        guard dataSize == 2, dataType == fourCC("sp78") else { return nil }
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: dataSize, toByteOffset: 28, as: UInt32.self)
            $0[42] = 5                                                     // kSMCReadKey
        }
        guard let out = smcCall(input) else { return nil }
        let raw = Int16(bitPattern: UInt16(out[48]) << 8 | UInt16(out[49]))  // sp78: signed 8.8, big-endian
        return plausible(Double(raw) / 256)
    }

    private func smcCall(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(smc, 2, inBytes.baseAddress, 80, outBytes.baseAddress, &outputSize)  // kSMCHandleYPCEvent
            }
        }
        return result == kIOReturnSuccess && output[40] == 0 ? output : nil
    }

    // MARK: - Battery

    /// Hundredths of °C. Older Macs: AppleSmartBattery → Temperature. Apple Silicon on macOS 27
    /// (checked on an M5 Pro): only AppleSmartBatteryPack → BatteryData → Temperature.
    private func smartBatteryTemperature() -> Double? {
        func property(_ className: String, _ key: String) -> Any? {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let value = property("AppleSmartBattery", "Temperature") as? Int
            ?? (property("AppleSmartBatteryPack", "BatteryData") as? [String: Any])?["Temperature"] as? Int
        return value.flatMap { plausible(Double($0) / 100) }
    }
}

private func plausible(_ celsius: Double) -> Double? {
    celsius > 0 && celsius <= 150 ? celsius : nil
}

private func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}
