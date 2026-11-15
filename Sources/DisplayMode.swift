// "Optimiser pour la diffusion vidéo HD": give the Mac display the shape of
// the stream sent to the Cast device, and put everything back afterwards.

import CoreGraphics
import Foundation

/// Cast receivers don't report their screen size; what they show is the
/// mirroring stream, which is 16:9 at 1080p or 720p.
func destinationResolution(maxHeight: Int) -> (Int, Int) {
    maxHeight >= 1080 ? (1920, 1080) : (1280, 720)
}

func describe(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth > m.width ? " HiDPI" : ""
    return "\(m.width)x\(m.height)\(hidpi) @\(Int(m.refreshRate.rounded()))Hz"
}

/// True when the display's current mode already has the target's aspect ratio
/// (within 1%, so 1366x768 counts as 16:9).
func hasAspectRatio(_ display: CGDirectDisplayID, of target: (Int, Int)) -> Bool {
    guard let m = CGDisplayCopyDisplayMode(display), m.height > 0 else { return false }
    let a = Double(m.width) / Double(m.height), t = Double(target.0) / Double(target.1)
    return abs(a - t) / t < 0.01
}

enum DisplayModeError: LocalizedError {
    case virtualDisplayFailed
    case configurationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .virtualDisplayFailed:
            return "impossible de créer l'écran virtuel 16:9"
        case .configurationFailed(let e):
            return "changement de résolution refusé (erreur \(e.rawValue))"
        }
    }
}

/// The main display, or the built-in one when the main display is `excluded`.
func mainPhysicalDisplay(excluding excluded: CGDirectDisplayID) -> CGDirectDisplayID {
    let main = CGMainDisplayID()
    if main != excluded { return main }
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    let others = ids.prefix(Int(count)).filter { $0 != excluded }
    return others.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? others.first ?? main
}

/// A 16:9 screen that exists only in software. The Mac's display mirrors it,
/// so the desktop takes its shape (with black bars on the physical panel).
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    /// `extended` gives it another serial number: macOS remembers the arrangement
    /// (mirrored or not) per display identity.
    init?(width: Int, height: Int, extended: Bool = false) {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.main
        d.name = "Cast Mirror \(width)x\(height)"
        d.maxPixelsWide = UInt32(width * 2)
        d.maxPixelsHigh = UInt32(height * 2)
        d.sizeInMillimeters = CGSize(width: Double(width) * 0.28, height: Double(height) * 0.28)
        d.vendorID = 0xCA57
        d.productID = UInt32(height)
        d.serialNum = extended ? 2 : 1
        d.terminationHandler = { _, _ in log("virtual display terminated") }
        display = CGVirtualDisplay(descriptor: d)
        guard display.displayID != 0 else { log("virtual display: no display ID"); return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt32(width * 2), height: UInt32(height * 2), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60),
        ]
        guard display.apply(settings) else { log("virtual display \(display.displayID): settings refused"); return nil }
    }
}

/// Manages the 16:9 virtual display used for casting, and puts everything back.
///
/// - Mirroring ("Optimiser pour la diffusion vidéo HD"): a display already in the stream's
///   aspect ratio is left alone. Any other mirrors a virtual display of the stream's size,
///   which is what gets captured, so the picture always fills the TV at full resolution.
/// - Extended desktop: the virtual display is a second screen placed right of the main one,
///   and the TV shows it.
final class DisplayOptimizer {
    /// `mirrored` is the physical display mirroring it, nil for an extended desktop.
    private var virtual: (display: VirtualDisplay, mirrored: CGDirectDisplayID?, target: (Int, Int))?
    /// Virtual display waiting for macOS to accept its configuration.
    private var pending: VirtualDisplay?
    private var generation = 0

    var virtualDisplayID: CGDirectDisplayID? { virtual?.display.displayID ?? pending?.displayID }

    /// Mirroring. Calls `completion` on the main queue with the display to capture.
    func apply(display: CGDirectDisplayID, target: (Int, Int),
               completion: @escaping (Result<CGDirectDisplayID, Error>) -> Void) {
        if let v = virtual, v.mirrored == display, v.target == target {
            completion(.success(v.display.displayID))
            return
        }
        restore()
        if hasAspectRatio(display, of: target) {
            log("display \(display): already \(CGDisplayCopyDisplayMode(display).map(describe) ?? "?"), unchanged")
            completion(.success(display))
            return
        }
        create(target: target, mirrored: display, completion: completion) { id in
            try self.configure { CGConfigureDisplayMirrorOfDisplay($0, display, id) }
        }
    }

    /// Extended desktop. Calls `completion` on the main queue with the display to capture.
    func extend(target: (Int, Int), completion: @escaping (Result<CGDirectDisplayID, Error>) -> Void) {
        if let v = virtual, v.mirrored == nil, v.target == target {
            completion(.success(v.display.displayID))
            return
        }
        restore()
        create(target: target, mirrored: nil, completion: completion) { id in
            // Right of the main display, tops aligned (macOS moves it if that overlaps another screen).
            let physical = mainPhysicalDisplay(excluding: id)
            let bounds = CGDisplayBounds(physical)
            try self.configure { config in
                // macOS may put a new display in a mirror set on its own: take it out first.
                var err = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                if err == .success, CGDisplayMirrorsDisplay(physical) == id {
                    err = CGConfigureDisplayMirrorOfDisplay(config, physical, kCGNullDirectDisplay)
                }
                guard err == .success else { return err }
                return CGConfigureDisplayOrigin(config, id, Int32(bounds.maxX), Int32(bounds.minY))
            }
            guard CGDisplayIsInMirrorSet(id) == 0 else { throw DisplayModeError.configurationFailed(.failure) }
        }
    }

    func restore() {
        generation += 1
        pending = nil
        guard let v = virtual else { return }
        virtual = nil
        if let mirrored = v.mirrored {
            do {
                try configure { CGConfigureDisplayMirrorOfDisplay($0, mirrored, kCGNullDirectDisplay) }
            } catch {
                log("unmirror failed: \(error.localizedDescription)")
            }
        }
        log("virtual display \(v.display.displayID) removed")
        _ = v.display  // released here, which removes it from the system
    }

    /// Creates the virtual display, then runs `configure` until macOS accepts it.
    ///
    /// A display created a moment ago is not always ready to be configured
    /// (CGCompleteDisplayConfiguration fails with 1001 in the app). Let the run loop
    /// process its arrival and try again for up to 3 seconds.
    private func create(target: (Int, Int), mirrored: CGDirectDisplayID?,
                        completion: @escaping (Result<CGDirectDisplayID, Error>) -> Void,
                        configure step: @escaping (CGDirectDisplayID) throws -> Void) {
        guard let v = VirtualDisplay(width: target.0, height: target.1, extended: mirrored == nil) else {
            completion(.failure(DisplayModeError.virtualDisplayFailed))
            return
        }
        let id = v.displayID
        let what = mirrored.map { "display \($0): mirroring virtual display \(id)" } ?? "extended desktop on virtual display \(id)"
        pending = v
        let token = generation

        func attempt(_ n: Int) {
            guard token == generation, let v = pending else { return }  // restore() was called meanwhile
            do {
                if n == 1 { selectHiDPIMode(id, target) }
                try step(id)
                pending = nil
                virtual = (v, mirrored, target)
                log("\(what) \(CGDisplayCopyDisplayMode(id).map(describe) ?? "?") (attempt \(n))")
                completion(.success(id))
            } catch {
                if n < 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt(n + 1) }
                } else {
                    log("\(what) failed after \(n) attempts: \(error.localizedDescription)")
                    pending = nil
                    completion(.failure(error))
                }
            }
        }
        DispatchQueue.main.async { attempt(1) }
    }

    /// Prefers the HiDPI mode: sharp text, on the TV and on the Mac's own panel.
    private func selectHiDPIMode(_ id: CGDirectDisplayID, _ target: (Int, Int)) {
        let modes = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
            as? [CGDisplayMode]) ?? []
        if let mode = modes.filter({ $0.width == target.0 && $0.height == target.1 })
            .max(by: { $0.pixelWidth < $1.pixelWidth }) {
            try? setMode(id, mode)
        }
    }

    private func setMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) throws {
        try configure { CGConfigureDisplayWithDisplayMode($0, display, mode, nil) }
    }

    /// For this login session only: a crash never leaves the Mac configured for good.
    private func configure(_ change: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else {
            log("CGBeginDisplayConfiguration: \(err.rawValue)")
            throw DisplayModeError.configurationFailed(err)
        }
        err = change(config)
        guard err == .success else {
            log("display configuration change: \(err.rawValue)")
            CGCancelDisplayConfiguration(config)
            throw DisplayModeError.configurationFailed(err)
        }
        err = CGCompleteDisplayConfiguration(config, .forSession)
        guard err == .success else {
            log("CGCompleteDisplayConfiguration: \(err.rawValue)")
            throw DisplayModeError.configurationFailed(err)
        }
    }
}
