// main.swift — Whip.app menu-bar GUI (runs in the user session)
//
// Listens for the daemon's "slap" Darwin notification and plays whip.mp3.
// Provides the menu-bar UI: enable/disable, sensitivity slider, install/uninstall
// the background service. No sensor access here — that's whipd (root).

import Cocoa

let kSlapNotif = "com.jinnosuke.whip.slap"
let kSensNotif = "com.jinnosuke.whip.sensitivity"
let kEnableNotif = "com.jinnosuke.whip.enabled"
let kDefaultsSensitivity = "sensitivity"
let kDefaultsEnabled = "enabled"
let kDaemonPlist = "/Library/LaunchDaemons/com.jinnosuke.whip.plist"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var slapToken: Int32 = 0
    var enabled = true
    var sensitivity = 0.15            // g
    var liveSounds: [NSSound] = []
    let soundURL = Bundle.main.url(forResource: "whip", withExtension: "mp3")
    var slider: NSSlider!
    var sliderLabel: NSTextField!
    var installItem: NSMenuItem!
    var uninstallItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        let d = UserDefaults.standard
        if d.object(forKey: kDefaultsSensitivity) != nil { sensitivity = d.double(forKey: kDefaultsSensitivity) }
        if d.object(forKey: kDefaultsEnabled) != nil { enabled = d.bool(forKey: kDefaultsEnabled) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💥"
        buildMenu()

        // listen for slaps from the daemon
        notify_register_dispatch(kSlapNotif, &slapToken, .main) { [weak self] token in
            guard let self, self.enabled else { return }
            var state: UInt64 = 0
            notify_get_state(token, &state)
            let strength = state > 0 ? Double(state) / 1000.0 : self.sensitivity
            self.playWhip(strength: strength)
        }

        pushSensitivityToDaemon()
        setDaemonEnabled(enabled)   // sync the sensor to our current state
    }

    // Park the sensor when the app closes — no point sensing with nothing to play sound.
    func applicationWillTerminate(_ note: Notification) {
        setDaemonEnabled(false)
    }

    // ---- menu ----
    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false   // we manage install/uninstall enabled state ourselves
        menu.delegate = self            // refresh service state each time the menu opens

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // sensitivity slider in a custom view
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 58))
        let caption = NSTextField(labelWithString: "Sensitivity")
        caption.frame = NSRect(x: 14, y: 34, width: 140, height: 16)
        caption.font = .menuFont(ofSize: 0)
        container.addSubview(caption)

        sliderLabel = NSTextField(labelWithString: "")
        sliderLabel.frame = NSRect(x: 150, y: 34, width: 60, height: 16)
        sliderLabel.alignment = .right
        sliderLabel.font = .menuFont(ofSize: 0)
        sliderLabel.textColor = .secondaryLabelColor
        container.addSubview(sliderLabel)

        // higher slider value = touchier (lower g threshold). invert for display.
        slider = NSSlider(value: gToSlider(sensitivity), minValue: 0, maxValue: 1,
                          target: self, action: #selector(sliderChanged))
        slider.frame = NSRect(x: 14, y: 8, width: 196, height: 20)
        slider.isContinuous = true
        container.addSubview(slider)

        let sliderItem = NSMenuItem()
        sliderItem.view = container
        menu.addItem(sliderItem)
        updateSliderLabel()

        menu.addItem(.separator())
        installItem = NSMenuItem(title: "Install Background Service…", action: #selector(installService), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)
        uninstallItem = NSMenuItem(title: "Uninstall Background Service…", action: #selector(uninstallService), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)
        let test = NSMenuItem(title: "Test Sound", action: #selector(testSound), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WhipIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshServiceItems()
    }

    // True when the LaunchDaemon plist is present (world-readable, no privileges needed).
    func serviceInstalled() -> Bool {
        FileManager.default.fileExists(atPath: kDaemonPlist)
    }

    // Reflect install state in the menu: check + grey-out Install when present, and vice versa.
    func refreshServiceItems() {
        let installed = serviceInstalled()
        installItem.state = installed ? .on : .off
        installItem.isEnabled = !installed
        uninstallItem.isEnabled = installed
    }

    // NSMenuDelegate — re-check just before the menu shows, in case the service
    // was installed or removed outside the app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshServiceItems()
    }

    // map g threshold (0.05 touchy .. 0.6 firm) to slider 0..1 (1 = touchy)
    func gToSlider(_ g: Double) -> Double { (0.6 - g) / (0.6 - 0.05) }
    func sliderToG(_ s: Double) -> Double { 0.6 - s * (0.6 - 0.05) }

    func updateSliderLabel() {
        sliderLabel.stringValue = String(format: "%.2f g", sensitivity)
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        statusItem.button?.title = enabled ? "💥" : "💤"
        UserDefaults.standard.set(enabled, forKey: kDefaultsEnabled)
        setDaemonEnabled(enabled)   // wake or sleep the sensor
    }

    // Tell the daemon to wake (1) or sleep (0) the sensor.
    func setDaemonEnabled(_ on: Bool) {
        var token: Int32 = 0
        if notify_register_check(kEnableNotif, &token) == UInt32(NOTIFY_STATUS_OK) {
            notify_set_state(token, on ? 1 : 0)
            notify_post(kEnableNotif)
            notify_cancel(token)
        }
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        sensitivity = sliderToG(sender.doubleValue)
        updateSliderLabel()
        UserDefaults.standard.set(sensitivity, forKey: kDefaultsSensitivity)
        pushSensitivityToDaemon()
    }

    func pushSensitivityToDaemon() {
        var token: Int32 = 0
        if notify_register_check(kSensNotif, &token) == UInt32(NOTIFY_STATUS_OK) {
            notify_set_state(token, UInt64(sensitivity * 1000))
            notify_post(kSensNotif)
            notify_cancel(token)
        }
    }

    // ---- audio ----
    @objc func testSound() { playWhip(strength: 0.4) }

    func playWhip(strength: Double) {
        guard let url = soundURL, let s = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep(); return
        }
        // always play at full volume — slap intensity shouldn't affect loudness
        s.volume = 1.0
        liveSounds.append(s)
        liveSounds = liveSounds.filter { $0.isPlaying || $0 === s }
        s.play()
    }

    // ---- service install/uninstall via one admin prompt ----
    @objc func installService() {
        guard let script = Bundle.main.path(forResource: "install-daemon", ofType: "sh") else {
            alert("install-daemon.sh missing from app bundle."); return
        }
        runPrivileged("/bin/sh \(shellQuote(script)) \(shellQuote(Bundle.main.bundlePath))",
                      ok: "Background service installed. Slap away!")
    }

    @objc func uninstallService() {
        runPrivileged("launchctl bootout system/com.jinnosuke.whip 2>/dev/null; rm -f /Library/LaunchDaemons/com.jinnosuke.whip.plist /usr/local/bin/whipd",
                      ok: "Background service removed.")
    }

    func runPrivileged(_ shellCommand: String, ok: String) {
        let osa = "do shell script \(appleScriptString(shellCommand)) with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", osa]
        let err = Pipe(); task.standardError = err
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 { self?.refreshServiceItems(); self?.alert(ok) }
                else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
                    self?.alert("Failed: \(msg)")
                }
            }
        }
        do { try task.run() } catch { alert("Could not run installer: \(error)") }
    }

    // ---- helpers ----
    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    func alert(_ text: String) {
        let a = NSAlert(); a.messageText = "WhipIt"; a.informativeText = text; a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
