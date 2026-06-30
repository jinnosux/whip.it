// whip.swift — Slap your MacBook, it cracks a whip.
//
// Reads the undocumented Apple Silicon accelerometer (Bosch BMI286) over IOKit HID,
// detects sharp impacts ("slaps"), and plays a whip sound.
//
// Build:  swiftc -O whip.swift -o whip
// Run:    sudo ./whip                          (reading the SPU HID device usually needs root)
//         sudo ./whip --sound whip.mp3 --sensitivity 0.15 --cooldown 0.75
//
// Sensor facts (verified on Mac16,x / M4):
//   device: AppleSPUHIDDevice, usagePage 0xFF00, usage 3 (accelerometer)
//   report: 22 bytes, X/Y/Z = int32 LE at byte offsets 6/10/14, value / 65536 = g

import Foundation
import IOKit
import IOKit.hid
import AppKit

// ---- config (override via flags) ----
struct Config {
    var soundPath = "whip.mp3"   // path to your whip sound (mp3/wav/aiff)
    var sensitivity = 0.15       // g of deviation-from-gravity that counts as a slap (lower = touchier)
    var cooldown = 0.75          // seconds to ignore further hits after one fires
    var scaleVolume = true       // louder slap -> louder sound
    var verbose = false
}

func parseArgs() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--sound", "-s":        if let v = it.next() { c.soundPath = v }
        case "--sensitivity", "-t":  if let v = it.next(), let d = Double(v) { c.sensitivity = d }
        case "--cooldown", "-c":     if let v = it.next(), let d = Double(v) { c.cooldown = d }
        case "--no-volume":          c.scaleVolume = false
        case "--verbose", "-v":      c.verbose = true
        case "--help", "-h":
            print("""
            whip — slap your MacBook, it cracks a whip
              --sound, -s <path>        sound file to play (default whip.mp3)
              --sensitivity, -t <g>     impact threshold in g (default 0.15, lower = touchier)
              --cooldown, -c <sec>      min seconds between sounds (default 0.75)
              --no-volume               don't scale volume by slap strength
              --verbose, -v             print live accelerometer magnitude
            """)
            exit(0)
        default: break
        }
    }
    return c
}

setbuf(stdout, nil)   // unbuffered so output appears live (and survives Ctrl-C)
let config = parseArgs()

// ---- sound playback (NSSound, fire-and-forget, allows overlap) ----
let soundURL = URL(fileURLWithPath: config.soundPath)
guard FileManager.default.fileExists(atPath: soundURL.path) else {
    FileHandle.standardError.write(Data("error: sound file not found at \(soundURL.path)\n".utf8))
    FileHandle.standardError.write(Data("       drop a whip.mp3 next to this binary, or pass --sound <path>\n".utf8))
    exit(1)
}
// keep references so ARC doesn't deallocate sounds mid-play
var liveSounds: [NSSound] = []
func playWhip(strength: Double) {
    guard let s = NSSound(contentsOf: soundURL, byReference: true) else { return }
    // always play at full volume — slap intensity shouldn't affect loudness
    s.volume = 1.0
    liveSounds.append(s)
    liveSounds = liveSounds.filter { $0.isPlaying || $0 === s }
    s.play()
}

// ---- detection state ----
var baseline = (x: 0.0, y: 0.0, z: 0.0)   // slow EMA = gravity vector
var haveBaseline = false
var lastFire = Date.distantPast
let baselineAlpha = 0.02                    // how fast the gravity estimate adapts

func handleSample(_ x: Double, _ y: Double, _ z: Double) {
    if !haveBaseline {
        baseline = (x, y, z); haveBaseline = true; return
    }
    // deviation from gravity = the dynamic part of the motion
    let dx = x - baseline.x, dy = y - baseline.y, dz = z - baseline.z
    let mag = (dx*dx + dy*dy + dz*dz).squareRoot()

    // adapt baseline slowly so it tracks gravity, not the slap
    baseline = (baseline.x + baselineAlpha*dx,
                baseline.y + baselineAlpha*dy,
                baseline.z + baselineAlpha*dz)

    if config.verbose { print(String(format: "mag %.3f g", mag)) }

    let now = Date()
    if mag >= config.sensitivity, now.timeIntervalSince(lastFire) >= config.cooldown {
        lastFire = now
        print(String(format: "🩼 SLAP  %.2f g", mag))
        playWhip(strength: mag)
    }
}

// ---- HID input report callback ----
func i32LE(_ p: UnsafePointer<UInt8>, _ off: Int) -> Int32 {
    return Int32(bitPattern:
        UInt32(p[off]) | UInt32(p[off+1]) << 8 | UInt32(p[off+2]) << 16 | UInt32(p[off+3]) << 24)
}

var sawFirstReport = false
// NB: the SPU device delivers ONLY through the timestamp callback variant.
let reportCallback: IOHIDReportWithTimeStampCallback = { _, _, _, _, _, report, length, _ in
    if !sawFirstReport { sawFirstReport = true; print("📡 receiving sensor reports (len \(length))") }
    guard length >= 18 else { return }   // need offsets up to 14..17
    let x = Double(i32LE(report, 6))  / 65536.0
    let y = Double(i32LE(report, 10)) / 65536.0
    let z = Double(i32LE(report, 14)) / 65536.0
    handleSample(x, y, z)
}

// buffer must stay alive for the lifetime of the callback
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

// The sensor stays powered down until these are set on the *driver* (AppleSPUHIDDriver),
// not the device. This is the step that actually starts the report stream.
func wakeSensors() {
    guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        setSensorProp(svc, "SensorPropertyReportingState", 1)
        setSensorProp(svc, "SensorPropertyPowerState", 1)
        setSensorProp(svc, "ReportInterval", 1000)   // microseconds
        IOObjectRelease(svc)
    }
}

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
        guard up == 0xFF00, u == 3 else { continue }       // accelerometer
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }

        let buf = ReportBuffer(REPORT_BUF_SZ)
        buffers.append(buf)
        buf.bytes.withUnsafeMutableBufferPointer { ptr in
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, ptr.baseAddress!, ptr.count, reportCallback, nil)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        openedDevices.append(device)
        ok = true
        print("✅ accelerometer connected")
    }
    return ok
}

wakeSensors()
if !openAccelerometer() {
    FileHandle.standardError.write(Data("error: could not open the accelerometer (AppleSPUHIDDevice).\n".utf8))
    FileHandle.standardError.write(Data("       run with sudo — the SPU sensor needs root.\n".utf8))
    exit(1)
}

print("whip armed — slap your MacBook (Ctrl-C to quit)")
print(String(format: "  sensitivity %.2f g · cooldown %.2fs · sound %@",
             config.sensitivity, config.cooldown, config.soundPath))
CFRunLoopRun()
