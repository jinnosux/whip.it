// whipd.swift — the whip daemon (runs as root)
//
// Reads the Apple Silicon accelerometer over IOKit HID, detects slaps, and
// broadcasts a Darwin notification ("com.jinnosuke.whip.slap") with the slap
// strength encoded in the notification state. It plays NO audio and has NO UI —
// that's the GUI app's job, because audio/UI need the user's login session
// while the sensor needs root. Darwin notifications cross that boundary cleanly.
//
// Build: swiftc -O whipd.swift -o whipd
// Runs under launchd as root (see com.jinnosuke.whip.plist).

import Foundation
import IOKit
import IOKit.hid

let kSlapNotif = "com.jinnosuke.whip.slap"          // daemon -> GUI: a slap happened
let kSensNotif = "com.jinnosuke.whip.sensitivity"   // GUI -> daemon: change threshold
let kEnableNotif = "com.jinnosuke.whip.enabled"     // GUI -> daemon: wake (1) / sleep (0) the sensor

// ---- tunables (sensitivity is live-updated by the GUI) ----
var sensitivity = 0.15              // g of deviation-from-gravity that counts as a slap
let cooldown = 0.75                 // seconds to ignore further hits after one fires
let REPORT_INTERVAL_US: Int32 = 10000   // 100 Hz; streaming is gated by ReportingState, not this

setbuf(stdout, nil)
setbuf(stderr, nil)

// ---- Darwin notification plumbing ----
// token we post slaps on (state carries strength in milli-g)
var slapToken: Int32 = 0
notify_register_check(kSlapNotif, &slapToken)

// listen for sensitivity changes from the GUI (state = milli-g)
var sensToken: Int32 = 0
notify_register_dispatch(kSensNotif, &sensToken, DispatchQueue.main) { token in
    var state: UInt64 = 0
    if notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK), state > 0 {
        sensitivity = Double(state) / 1000.0
        print("sensitivity updated -> \(sensitivity) g")
    }
}

func emitSlap(strength: Double) {
    notify_set_state(slapToken, UInt64(strength * 1000))
    notify_post(kSlapNotif)
}

// listen for enable/disable from the GUI (state 1 = wake sensor, 0 = sleep it)
var enableToken: Int32 = 0
notify_register_dispatch(kEnableNotif, &enableToken, DispatchQueue.main) { token in
    var state: UInt64 = 0
    notify_get_state(token, &state)
    if state == 1 { wakeSensors(); print("enabled -> sensor awake") }
    else          { sleepSensors(); print("disabled -> sensor asleep") }
}

// ---- detection state ----
var baseline = (x: 0.0, y: 0.0, z: 0.0)   // slow EMA = gravity vector
var haveBaseline = false
var lastFire = Date.distantPast
let baselineAlpha = 0.02

func handleSample(_ x: Double, _ y: Double, _ z: Double) {
    if !haveBaseline { baseline = (x, y, z); haveBaseline = true; return }
    let dx = x - baseline.x, dy = y - baseline.y, dz = z - baseline.z
    let mag = (dx*dx + dy*dy + dz*dz).squareRoot()
    baseline = (baseline.x + baselineAlpha*dx,
                baseline.y + baselineAlpha*dy,
                baseline.z + baselineAlpha*dz)
    if debug, mag > 0.02 { print(String(format: "mag %.3f g", mag)) }
    let now = Date()
    if mag >= sensitivity, now.timeIntervalSince(lastFire) >= cooldown {
        lastFire = now
        print(String(format: "SLAP %.2f g", mag))
        emitSlap(strength: mag)
    }
}

// ---- HID report parsing (X/Y/Z = int32 LE at 6/10/14, /65536 = g) ----
func i32LE(_ p: UnsafePointer<UInt8>, _ off: Int) -> Int32 {
    Int32(bitPattern: UInt32(p[off]) | UInt32(p[off+1]) << 8 | UInt32(p[off+2]) << 16 | UInt32(p[off+3]) << 24)
}

let debug = ProcessInfo.processInfo.environment["WHIPD_DEBUG"] != nil
var sawFirstReport = false
// NB: the SPU device delivers ONLY through the timestamp callback variant.
let reportCallback: IOHIDReportWithTimeStampCallback = { _, _, _, _, _, report, length, _ in
    if !sawFirstReport { sawFirstReport = true; print("receiving sensor reports (len \(length))") }
    guard length >= 18 else { return }
    handleSample(Double(i32LE(report, 6))  / 65536.0,
                 Double(i32LE(report, 10)) / 65536.0,
                 Double(i32LE(report, 14)) / 65536.0)
}

let REPORT_BUF_SZ = 4096
final class ReportBuffer { var bytes: [UInt8]; init(_ n: Int) { bytes = [UInt8](repeating: 0, count: n) } }
var buffers: [ReportBuffer] = []
var openedDevices: [IOHIDDevice] = []

func setSensorProp(_ entry: io_registry_entry_t, _ key: String, _ value: Int32) {
    var v = value
    if let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
        IORegistryEntrySetCFProperty(entry, key as CFString, num)
    }
}

// Sensor power/reporting is controlled on the *driver* (AppleSPUHIDDriver), not the
// device — this is what actually starts/stops the report stream. wakeSensors() turns
// it on; sleepSensors() powers it down so it draws nothing when disabled/closed.
func setDriverState(reporting: Int32, power: Int32, interval: Int32? = nil) {
    guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        setSensorProp(svc, "SensorPropertyReportingState", reporting)
        setSensorProp(svc, "SensorPropertyPowerState", power)
        if let interval { setSensorProp(svc, "ReportInterval", interval) }
        IOObjectRelease(svc)
    }
}
func wakeSensors()  { setDriverState(reporting: 1, power: 1, interval: REPORT_INTERVAL_US) }
func sleepSensors() { setDriverState(reporting: 0, power: 0) }

// Open the AppleSPUHIDDevice accelerometer (PrimaryUsagePage 0xFF00 / PrimaryUsage 3).
func openAccelerometer() -> Bool {
    guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return false }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(iter) }

    var ok = false
    while case let service = IOIteratorNext(iter), service != 0 {
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
        let up = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let u  = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        guard up == 0xFF00, u == 3 else { continue }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }

        let buf = ReportBuffer(REPORT_BUF_SZ)
        buffers.append(buf)
        buf.bytes.withUnsafeMutableBufferPointer { ptr in
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, ptr.baseAddress!, ptr.count, reportCallback, nil)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        openedDevices.append(device)
        ok = true
        print("accelerometer connected")
    }
    return ok
}

wakeSensors()

if !openAccelerometer() {
    FileHandle.standardError.write(Data("whipd: could not open AppleSPUHIDDevice — needs root\n".utf8))
    exit(1)
}
// Park the sensor on shutdown (e.g. `launchctl bootout` during uninstall, or Ctrl-C).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { print("shutting down — sensor asleep"); sleepSensors(); exit(0) }
    src.resume()
    return src
}
_ = signalSources   // keep alive

print("whipd armed (sensitivity \(sensitivity) g)\(debug ? " [debug]" : "")")
CFRunLoopRun()
