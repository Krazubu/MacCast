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

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["audio": true, "maxHeight": 1080, "delayMs": 400, "displayID": 0])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        browser.onChange = { [weak self] devices in self?.devices = devices }
        browser.start(queue: .main)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let s = session else { return }
        s.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText))
        if session != nil {
            menu.addItem(item("Arrêter la diffusion", #selector(stopCasting), key: "s"))
        }
        menu.addItem(.separator())

        menu.addItem(disabled("Diffuser sur"))
        if devices.isEmpty {
            menu.addItem(disabled("  Recherche des appareils…"))
        }
        for d in devices {
            let i = item(d.name, #selector(castTo(_:)))
            i.representedObject = d
            i.state = (session != nil && sessionDevice?.id == d.id) ? .on : .off
            if !d.model.isEmpty { i.toolTip = d.model }
            menu.addItem(i)
        }
        menu.addItem(.separator())

        // Displays
        let screens = NSScreen.screens
        if screens.count > 1 {
            let sub = NSMenu()
            let chosen = currentDisplayID
            for s in screens {
                guard let id = s.displayID else { continue }
                let i = item(s.localizedName, #selector(setDisplay(_:)))
                i.tag = Int(id)
                i.state = id == chosen ? .on : .off
                sub.addItem(i)
            }
            menu.addItem(submenu("Écran", sub))
        }

        let quality = NSMenu()
        for (h, title) in [(1080, "1080p"), (720, "720p (plus léger)")] {
            let i = item(title, #selector(setQuality(_:)))
            i.tag = h
            i.state = defaults.integer(forKey: "maxHeight") == h ? .on : .off
            quality.addItem(i)
        }
        menu.addItem(submenu("Qualité", quality))

        let latency = NSMenu()
        for (ms, title) in [(200, "Faible (200 ms)"), (400, "Normale (400 ms)"), (800, "Stable (800 ms, Wi-Fi faible)")] {
            let i = item(title, #selector(setLatency(_:)))
            i.tag = ms
            i.state = defaults.integer(forKey: "delayMs") == ms ? .on : .off
            latency.addItem(i)
        }
        menu.addItem(submenu("Latence", latency))

        let audio = item("Diffuser le son", #selector(toggleAudio))
        audio.state = defaults.bool(forKey: "audio") ? .on : .off
        menu.addItem(audio)

        let login = item("Ouvrir à la connexion", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Afficher le journal", #selector(openLog)))
        menu.addItem(item("Quitter Cast Mirror", #selector(quit), key: "q"))
    }

    private var statusText: String {
        let name = sessionDevice?.name ?? ""
        switch phase {
        case .connecting?: return "Connexion à \(name)…"
        case .launching?: return "Ouverture de la recopie sur \(name)…"
        case .negotiating?: return "Négociation avec \(name)…"
        case .streaming?: return "Diffusion sur \(name)"
        case .ended?, nil:
            if let e = lastError { return "Erreur : \(e)" }
            return devices.isEmpty ? "Aucun appareil Cast trouvé" : "Inactif"
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
        if session != nil, sessionDevice?.id == device.id { stopCasting(); return }
        start(device)
    }

    @objc private func stopCasting() {
        session?.stop()
        session = nil
        phase = nil
        lastError = nil
        updateIcon()
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
            alert("Impossible de modifier l'ouverture à la connexion : \(error.localizedDescription)")
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    private var currentDisplayID: CGDirectDisplayID {
        let id = CGDirectDisplayID(defaults.integer(forKey: "displayID"))
        let online = NSScreen.screens.compactMap(\.displayID)
        return online.contains(id) ? id : CGMainDisplayID()
    }

    private func restartIfCasting() {
        if session != nil, let d = sessionDevice { start(d) }
    }

    private func start(_ device: CastDevice) {
        session?.stop()
        session = nil
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert("Cast Mirror a besoin de l'autorisation « Enregistrement de l'écran et audio système ».\n\nActive-la dans Réglages Système › Confidentialité et sécurité, puis relance l'app.")
            return
        }
        var options = MirrorOptions()
        options.displayID = currentDisplayID
        options.maxHeight = defaults.integer(forKey: "maxHeight")
        options.targetDelayMs = defaults.integer(forKey: "delayMs")
        options.audio = defaults.bool(forKey: "audio")

        let s = MirrorSession(device: device, options: options)
        s.onPhase = { [weak self, weak s] p in
            guard let self, let s, self.session === s else { return }
            self.phase = p
            if case .ended(let reason) = p {
                self.session = nil
                self.lastError = reason
            }
            self.updateIcon()
        }
        session = s
        sessionDevice = device
        phase = .connecting
        lastError = nil
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
