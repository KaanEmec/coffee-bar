//! Heat-fuse sensors (see files/ARCHITECTURE.md#windows-sensors).
//!
//! Zone: hottest ACPI thermal zone via a PDH wildcard counter.
//! Battery: `IOCTL_BATTERY_QUERY_INFORMATION` / `BatteryTemperature`, when the driver supports it.
//! Every failure means "sensor not available"; nothing here panics or reports errors.

use windows::core::{w, PCWSTR};
use windows::Win32::Devices::DeviceAndDriverInstallation::{
    GUID_DEVCLASS_BATTERY, SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW,
    SetupDiGetDeviceInterfaceDetailW, DIGCF_DEVICEINTERFACE, DIGCF_PRESENT,
    SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
};
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::Performance::{
    PdhAddEnglishCounterW, PdhCloseQuery, PdhCollectQueryData, PdhGetFormattedCounterArrayW,
    PdhOpenQueryW, PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_HCOUNTER, PDH_HQUERY,
};
use windows::Win32::System::Power::{
    BatteryTemperature, BATTERY_QUERY_INFORMATION,
    IOCTL_BATTERY_QUERY_INFORMATION, IOCTL_BATTERY_QUERY_TAG,
};
use windows::Win32::System::IO::DeviceIoControl;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Sensor {
    /// Hottest ACPI thermal zone.
    Zone,
    Battery,
}

#[derive(Clone, Copy, Debug)]
pub struct Reading {
    pub sensor: Sensor,
    pub celsius: f32,
}

/// An open PDH query with one wildcard counter and the divisor to get kelvin.
struct Zone {
    query: PDH_HQUERY,
    counter: PDH_HCOUNTER,
    /// 10.0 for "High Precision Temperature" (tenths of K), 1.0 for "Temperature" (K).
    per_kelvin: f64,
}

pub struct Thermal {
    zone: Option<Zone>,
    /// NUL-terminated device paths of batteries that reported a temperature in `new()`.
    batteries: Vec<Vec<u16>>,
    available: bool,
}

impl Drop for Thermal {
    fn drop(&mut self) {
        if let Some(z) = self.zone.take() {
            unsafe { PdhCloseQuery(z.query) };
        }
    }
}

impl Thermal {
    /// Opens whatever sensors exist. Never fails; check `available()`.
    pub fn new() -> Self {
        let mut t = Thermal { zone: None, batteries: Vec::new(), available: false };

        for (path, per_kelvin) in [
            (w!(r"\Thermal Zone Information(*)\High Precision Temperature"), 10.0),
            (w!(r"\Thermal Zone Information(*)\Temperature"), 1.0),
        ] {
            if let Some(z) = open_zone(path, per_kelvin) {
                if read_zone(&z).is_some() {
                    t.zone = Some(z);
                    break;
                }
                unsafe { PdhCloseQuery(z.query) };
            }
        }

        t.batteries = battery_paths().into_iter().filter(|p| battery_celsius(p).is_some()).collect();
        t.available = t.zone.is_some() || !t.batteries.is_empty();
        t
    }

    /// True if at least one sensor gave a reading when probed in `new()`.
    pub fn available(&self) -> bool {
        self.available
    }

    /// At most ONE reading per `Sensor` (the hottest zone; the first battery that reports).
    /// Sensors that fail to read are simply left out.
    pub fn read(&mut self) -> Vec<Reading> {
        let mut out = Vec::new();
        if let Some(c) = self.zone.as_ref().and_then(read_zone).filter(|c| plausible(*c)) {
            out.push(Reading { sensor: Sensor::Zone, celsius: c });
        }
        let battery = self.batteries.iter().filter_map(|p| battery_celsius(p)).find(|c| plausible(*c));
        if let Some(c) = battery {
            out.push(Reading { sensor: Sensor::Battery, celsius: c });
        }
        out
    }
}

fn plausible(c: f32) -> bool {
    c > 0.0 && c <= 150.0
}

fn kelvin_to_celsius(k: f64) -> f32 {
    (k - 273.15) as f32
}

fn tenths_kelvin_to_celsius(raw: f64) -> f32 {
    kelvin_to_celsius(raw / 10.0)
}

fn open_zone(path: PCWSTR, per_kelvin: f64) -> Option<Zone> {
    unsafe {
        let mut query = PDH_HQUERY::default();
        if PdhOpenQueryW(PCWSTR::null(), 0, &mut query) != 0 {
            return None;
        }
        let mut counter = PDH_HCOUNTER::default();
        if PdhAddEnglishCounterW(query, path, 0, &mut counter) != 0 {
            PdhCloseQuery(query);
            return None;
        }
        Some(Zone { query, counter, per_kelvin })
    }
}

/// Collects a sample and returns the hottest zone in °C (None if no valid instance).
fn read_zone(z: &Zone) -> Option<f32> {
    unsafe {
        if PdhCollectQueryData(z.query) != 0 {
            return None;
        }
        let (mut size, mut count) = (0u32, 0u32);
        // First call only reports the needed size (PDH_MORE_DATA); the result code is expected.
        PdhGetFormattedCounterArrayW(z.counter, PDH_FMT_DOUBLE, &mut size, &mut count, None);
        if size == 0 {
            return None;
        }
        // u64 elements keep the buffer 8-byte aligned for the item structs.
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let items = buf.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
        if PdhGetFormattedCounterArrayW(z.counter, PDH_FMT_DOUBLE, &mut size, &mut count, Some(items)) != 0 {
            return None;
        }
        (0..count as usize)
            .map(|i| &*items.add(i))
            .filter(|it| it.FmtValue.CStatus == 0 || it.FmtValue.CStatus == 1)
            .map(|it| kelvin_to_celsius(it.FmtValue.Anonymous.doubleValue / z.per_kelvin))
            .filter(|c| plausible(*c))
            .max_by(|a, b| a.total_cmp(b))
    }
}

/// Device paths (NUL-terminated UTF-16) of all present batteries.
fn battery_paths() -> Vec<Vec<u16>> {
    let mut paths = Vec::new();
    unsafe {
        let Ok(set) = SetupDiGetClassDevsW(
            Some(&GUID_DEVCLASS_BATTERY),
            PCWSTR::null(),
            None,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
        ) else {
            return paths;
        };
        for index in 0.. {
            let mut data = SP_DEVICE_INTERFACE_DATA {
                cbSize: size_of::<SP_DEVICE_INTERFACE_DATA>() as u32,
                ..Default::default()
            };
            if SetupDiEnumDeviceInterfaces(set, None, &GUID_DEVCLASS_BATTERY, index, &mut data).is_err() {
                break;
            }
            let mut needed = 0u32;
            let _ = SetupDiGetDeviceInterfaceDetailW(set, &data, None, 0, Some(&mut needed), None);
            if (needed as usize) < size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() {
                continue;
            }
            let mut buf = vec![0u32; (needed as usize).div_ceil(4)];
            let detail = buf.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
            (*detail).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
            if SetupDiGetDeviceInterfaceDetailW(set, &data, Some(detail), needed, None, None).is_err() {
                continue;
            }
            let start = std::ptr::addr_of!((*detail).DevicePath) as *const u16;
            let mut len = 0;
            while *start.add(len) != 0 {
                len += 1;
            }
            paths.push(std::slice::from_raw_parts(start, len + 1).to_vec());
        }
        let _ = SetupDiDestroyDeviceInfoList(set);
    }
    paths
}

/// Battery temperature in °C, or None if the driver does not support it.
fn battery_celsius(path: &[u16]) -> Option<f32> {
    unsafe {
        let h = CreateFileW(
            PCWSTR(path.as_ptr()),
            (GENERIC_READ | GENERIC_WRITE).0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            None,
        )
        .ok()?;
        let r = query_battery_temp(h);
        let _ = CloseHandle(h);
        r
    }
}

unsafe fn query_battery_temp(h: HANDLE) -> Option<f32> {
    let wait = 0u32;
    let mut tag = 0u32;
    let mut ret = 0u32;
    DeviceIoControl(
        h,
        IOCTL_BATTERY_QUERY_TAG,
        Some(&wait as *const u32 as *const _),
        size_of::<u32>() as u32,
        Some(&mut tag as *mut u32 as *mut _),
        size_of::<u32>() as u32,
        Some(&mut ret),
        None,
    )
    .ok()?;
    if tag == 0 {
        return None;
    }
    let q = BATTERY_QUERY_INFORMATION { BatteryTag: tag, InformationLevel: BatteryTemperature, AtRate: 0 };
    let mut raw = 0u32;
    DeviceIoControl(
        h,
        IOCTL_BATTERY_QUERY_INFORMATION,
        Some(&q as *const _ as *const _),
        size_of::<BATTERY_QUERY_INFORMATION>() as u32,
        Some(&mut raw as *mut u32 as *mut _),
        size_of::<u32>() as u32,
        Some(&mut ret),
        None,
    )
    .ok()?;
    if ret < 4 {
        return None;
    }
    Some(tenths_kelvin_to_celsius(raw as f64))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kelvin_conversions() {
        assert!((kelvin_to_celsius(273.15) - 0.0).abs() < 1e-3);
        assert!((kelvin_to_celsius(373.15) - 100.0).abs() < 1e-3);
        assert!((tenths_kelvin_to_celsius(3081.5) - 35.0).abs() < 1e-3);
        assert!((tenths_kelvin_to_celsius(3731.5) - 100.0).abs() < 1e-3);
    }

    #[test]
    fn plausibility() {
        assert!(!plausible(0.0));
        assert!(!plausible(-5.0));
        assert!(plausible(45.0));
        assert!(plausible(150.0));
        assert!(!plausible(150.1));
    }

    #[test]
    #[ignore]
    fn probe_this_machine() {
        let mut t = Thermal::new();
        println!("available = {}", t.available());
        println!("read = {:?}", t.read());
    }
}
