// Menu bar UI: pick a Cast device, a display, quality, latency, sound.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let browser = CastBrowser()
    private var devices: [CastDevice] = []
    private var session: MirrorSession?
    private var sessionDevice: CastDevice?
    private var phase: MirrorSession.Phase?
    private var lastError: String?
    private let defaults = UserDefaults.standard
    private let displayMode = DisplayOptimizer()
    /// Bumped by every start/stop, so a start still waiting for the display is dropped.
    private var startToken = 0
    /// Cast paused by sleep, resumed on wake (with a few retries while the network comes back).
    private var resumeDevice: CastDevice?
    private var resumeAttempts = 0
    private var asleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["audio": true, "maxHeight": 1080, "delayMs": 400, "displayID": 0,
                                     "optimizeForDestination": false, "extend": false])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        browser.onChange = { [weak self] devices in self?.devices = devices }
        browser.start(queue: .main)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: Sleep

    private var isCasting: Bool {
        if case .ended? = phase { return false }
        return phase != nil
    }

    /// Lid closed, "Suspendre", or the display turned off by hand: the capture can't go on.
    /// Stop cleanly while the displays can still be reconfigured, and resume on wake.
    @objc private func willSleep(_ n: Notification) {
        asleep = true
        guard isCasting, let d = sessionDevice else { return }
        log("\(n.name.rawValue): pausing cast to \(d.name)")
        pauseForSleep(d)
        teardown()
    }

    @objc private func didWake(_ n: Notification) {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }  // screensDidWake comes later
        guard asleep else { return }
        asleep = false
        displayMode.retryRestore()
        guard let d = resumeDevice else { return }
        log("\(n.name.rawValue): resuming cast to \(d.name)")
        resumeSoon(d, after: 3)  // let Wi-Fi reconnect
    }

    private func pauseForSleep(_ d: CastDevice) {
        resumeDevice = d
        resumeAttempts = 4
    }

    private func resumeSoon(_ d: CastDevice, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.asleep, self.resumeDevice?.id == d.id, !self.isCasting else { return }
            self.resumeAttempts -= 1
            self.start(d)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayMode.restore()
        guard let s = session else { return }
        s.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText))
        if session != nil {
            menu.addItem(item(L("Stop Casting"), #selector(stopCasting), key: "s"))
        }
        menu.addItem(.separator())

        menu.addItem(disabled(L("Cast to")))
        let found = Set(devices.map(\.name))
        let listed = devices + manualDevices.filter { !found.contains($0.name) }
        if listed.isEmpty {
            menu.addItem(disabled(L("  Searching for devices…")))
        }
        for d in listed {
            let i = item(d.name, #selector(castTo(_:)))
            i.representedObject = d
            i.state = (session != nil && sessionDevice?.id == d.id) ? .on : .off
            if let host = d.manualHost {
                i.toolTip = d.model.isEmpty ? host : "\(d.model) – \(host)"
            } else if !d.model.isEmpty {
                i.toolTip = d.model
            }
            menu.addItem(i)
        }
        let byIP = item(L("IP Address…"), #selector(castToAddress))
        byIP.toolTip = L("Cast to a device by its IP address, when it doesn't show up in the list.")
        menu.addItem(byIP)
        if !manualDevices.isEmpty {
            menu.addItem(item(L("Forget IP Addresses"), #selector(forgetAddresses)))
        }
        menu.addItem(.separator())

        let extend = defaults.bool(forKey: "extend")
        let (dw, dh) = destinationResolution(maxHeight: defaults.integer(forKey: "maxHeight"))
        let mode = NSMenu()
        for (ext, title) in [(false, L("Mirror Display")), (true, L("Extended Display (%ldx%ld)", dw, dh))] {
            let i = item(title, #selector(setExtend(_:)))
            i.tag = ext ? 1 : 0
            i.state = extend == ext ? .on : .off
            if ext {
                i.toolTip = L("The TV becomes a second display, right of the main one. Drag windows onto it while casting.")
            }
            mode.addItem(i)
        }
        menu.addItem(submenu(L("Mode"), mode))

        // Which display to mirror and how: irrelevant for an extended desktop.
        if !extend {
            let displays = physicalDisplays
            if displays.count > 1 {
                let sub = NSMenu()
                let chosen = currentDisplayID
                for id in displays {
                    let i = item(displayName(id), #selector(setDisplay(_:)))
                    i.tag = Int(id)
                    i.state = id == chosen ? .on : .off
                    sub.addItem(i)
                }
                menu.addItem(submenu(L("Display"), sub))
            }

            let optimize = NSMenu()
            let toDestination = defaults.bool(forKey: "optimizeForDestination")
            for (dest, title) in [(false, L("The Mac Display")), (true, L("The HD Video Stream (%ldx%ld)", dw, dh))] {
                let i = item(title, #selector(setOptimize(_:)))
                i.tag = dest ? 1 : 0
                i.state = toDestination == dest ? .on : .off
                if dest {
                    i.toolTip = L("While casting, the desktop takes the shape of the stream (16:9): the Mac display mirrors a virtual display of that size.")
                }
                optimize.addItem(i)
            }
            menu.addItem(submenu(L("Optimize For"), optimize))
        }

        let quality = NSMenu()
        for (h, title) in [(1080, "1080p"), (720, L("720p (lighter)"))] {
            let i = item(title, #selector(setQuality(_:)))
            i.tag = h
            i.state = defaults.integer(forKey: "maxHeight") == h ? .on : .off
            quality.addItem(i)
        }
        menu.addItem(submenu(L("Quality"), quality))

        let latency = NSMenu()
        for (ms, title) in [(200, L("Low (200 ms)")), (400, L("Normal (400 ms)")), (800, L("Steady (800 ms, weak Wi-Fi)"))] {
            let i = item(title, #selector(setLatency(_:)))
            i.tag = ms
            i.state = defaults.integer(forKey: "delayMs") == ms ? .on : .off
            latency.addItem(i)
        }
        menu.addItem(submenu(L("Latency"), latency))

        let audio = item(L("Cast Sound"), #selector(toggleAudio))
        audio.state = defaults.bool(forKey: "audio") ? .on : .off
        menu.addItem(audio)

        let login = item(L("Open at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item(L("Show Log"), #selector(openLog)))
        menu.addItem(item(L("Quit Cast Mirror"), #selector(quit), key: "q"))
    }

    private var statusText: String {
        let name = sessionDevice?.name ?? ""
        switch phase {
        case .connecting?: return L("Connecting to %@…", name)
        case .launching?: return L("Starting mirroring on %@…", name)
        case .negotiating?: return L("Negotiating with %@…", name)
        case .streaming?:
            return defaults.bool(forKey: "extend") ? L("Extending to %@", name) : L("Casting to %@", name)
        case .ended?, nil:
            if let d = resumeDevice {
                return asleep ? L("Paused (sleep): resumes on %@ at wake", d.name) : L("Resuming cast to %@…", d.name)
            }
            if let e = lastError { return L("Error: %@", e) }
            return devices.isEmpty ? L("No Cast device found") : L("Idle")
        }
    }

    private func updateIcon() {
        let casting = session != nil
        let image = NSImage(systemSymbolName: casting ? "tv.fill" : "tv", accessibilityDescription: "Cast Mirror")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = casting && phase != .streaming
    }

    // MARK: Actions

    @objc private func castTo(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CastDevice else { return }
        if isCasting, sessionDevice?.id == device.id { stopCasting(); return }
        resumeDevice = nil
        start(device)
    }

    /// Devices typed in by IP address, remembered for the next time.
    private var manualDevices: [CastDevice] {
        (defaults.array(forKey: "manualDevices") as? [[String: String]] ?? []).compactMap { e in
            guard let host = e["host"] else { return nil }
            return .manual(host: host, name: e["name"], model: e["model"] ?? "")
        }
    }

    private func remember(_ d: CastDevice) {
        guard let host = d.manualHost else { return }
        var list = (defaults.array(forKey: "manualDevices") as? [[String: String]] ?? []).filter { $0["host"] != host }
        list.insert(["host": host, "name": d.name, "model": d.model], at: 0)
        defaults.set(Array(list.prefix(5)), forKey: "manualDevices")
    }

    @objc private func castToAddress() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Cast to an IP Address")
        a.informativeText = L("Type the IP address of the Chromecast or TV. You can find it in the Google Home app, in the device's settings, or in your router's list of devices.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "192.168.1.20"
        field.stringValue = manualDevices.first?.manualHost ?? ""
        a.accessoryView = field
        a.addButton(withTitle: L("Cast"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let host = CastDevice.normalizedHost(field.stringValue) else {
            alert(L("“%@” is not a valid IP address.", field.stringValue))
            return
        }
        // Keep the name already known for this address until the device tells its own.
        let known = manualDevices.first { $0.manualHost == host }
        let device = known ?? .manual(host: host)
        remember(device)
        resumeDevice = nil
        start(device)
        CastDevice.lookUpName(host: host) { [weak self] name, model in
            guard let self, let name else { return }
            let named = CastDevice.manual(host: host, name: name, model: model ?? device.model)
            log("\(host) is \(name) (\(model ?? "?"))")
            self.remember(named)
            if self.sessionDevice?.id == named.id { self.sessionDevice = named }
            if self.resumeDevice?.id == named.id { self.resumeDevice = named }
        }
    }

    @objc private func forgetAddresses() {
        defaults.removeObject(forKey: "manualDevices")
    }

    @objc private func stopCasting() {
        resumeDevice = nil
        teardown()
    }

    private func teardown() {
        startToken += 1
        session?.stop()
        session = nil
        phase = nil
        lastError = nil
        displayMode.restore()
        updateIcon()
    }

    @objc private func setOptimize(_ sender: NSMenuItem) {
        defaults.set(sender.tag == 1, forKey: "optimizeForDestination")
        if sender.tag == 0 { displayMode.restore() }
        restartIfCasting()
    }

    @objc private func setExtend(_ sender: NSMenuItem) {
        defaults.set(sender.tag == 1, forKey: "extend")
        restartIfCasting()
    }

    @objc private func setDisplay(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "displayID")
        restartIfCasting()
    }

    @objc private func setQuality(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "maxHeight")
        restartIfCasting()
    }

    @objc private func setLatency(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "delayMs")
        restartIfCasting()
    }

    @objc private func toggleAudio() {
        defaults.set(!defaults.bool(forKey: "audio"), forKey: "audio")
        restartIfCasting()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(L("Could not change Open at Login: %@", error.localizedDescription))
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    /// Online displays, including ones mirroring our virtual display, excluding the virtual one.
    private var physicalDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { $0 != displayMode.virtualDisplayID && CGDisplayIsActive($0) != 0 }
    }

    private func displayName(_ id: CGDirectDisplayID) -> String {
        if let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s.localizedName }
        return CGDisplayIsBuiltin(id) != 0 ? L("Built-in Display") : L("Display %ld", Int(id))
    }

    private var currentDisplayID: CGDirectDisplayID {
        let id = CGDirectDisplayID(defaults.integer(forKey: "displayID"))
        let online = physicalDisplays
        if online.contains(id) { return id }
        return online.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? online.first ?? CGMainDisplayID()
    }

    private func restartIfCasting() {
        if session != nil, let d = sessionDevice { start(d) }
    }

    private func start(_ device: CastDevice) {
        session?.stop()
        session = nil
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert(L("Cast Mirror needs the “Screen & System Audio Recording” permission.\n\nTurn it on in System Settings › Privacy & Security, then relaunch the app."))
            return
        }
        var options = MirrorOptions()
        options.displayID = currentDisplayID
        options.maxHeight = defaults.integer(forKey: "maxHeight")
        options.targetDelayMs = defaults.integer(forKey: "delayMs")
        options.audio = defaults.bool(forKey: "audio")

        sessionDevice = device
        phase = .connecting
        lastError = nil
        startToken += 1
        let token = startToken
        updateIcon()

        // Done before the session is created: the stream size follows the display's new shape.
        let target = destinationResolution(maxHeight: options.maxHeight)
        let extend = defaults.bool(forKey: "extend")
        guard extend || defaults.bool(forKey: "optimizeForDestination") else {
            displayMode.restore()
            launch(device, options)
            return
        }
        let ready: (Result<CGDirectDisplayID, Error>) -> Void = { [weak self] result in
            guard let self, self.startToken == token else { return }
            switch result {
            case .success(let id):
                options.displayID = id
            case .failure(let error):
                log("optimize for HD stream failed: \(error.localizedDescription)")
                self.displayMode.restore()
                self.alert(L("16:9 virtual display unavailable: %@.\n\nCasting goes on, mirroring the Mac display as it is.", error.localizedDescription))
                guard self.startToken == token else { return }
            }
            self.launch(device, options)
        }
        if extend {
            displayMode.extend(target: target, completion: ready)
        } else {
            displayMode.apply(display: options.displayID, target: target, completion: ready)
        }
    }

    private func launch(_ device: CastDevice, _ options: MirrorOptions) {
        let s = MirrorSession(device: device, options: options)
        s.onPhase = { [weak self, weak s] p in
            guard let self, let s, self.session === s else { return }
            self.phase = p
            if case .ended(let reason) = p {
                self.session = nil
                self.lastError = reason
                self.displayMode.restore()
                if reason != nil {
                    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 || self.asleep {
                        // The capture died because the displays went to sleep.
                        log("cast ended while asleep: will resume on wake")
                        self.asleep = true
                        self.pauseForSleep(device)
                        self.lastError = nil
                        self.phase = nil
                    } else if self.resumeDevice?.id == device.id, self.resumeAttempts > 0 {
                        self.resumeSoon(device, after: 3)
                    }
                }
            } else if p == .streaming {
                self.resumeDevice = nil
            }
            self.updateIcon()
        }
        session = s
        updateIcon()
        s.start()
    }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Cast Mirror"
        a.informativeText = text
        a.runModal()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
