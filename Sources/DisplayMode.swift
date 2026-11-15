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

/// A 16:9 screen that exists only in software. The Mac's display mirrors it,
/// so the desktop takes its shape (with black bars on the physical panel).
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    init?(width: Int, height: Int) {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.main
        d.name = "Cast Mirror \(width)x\(height)"
        d.maxPixelsWide = UInt32(width * 2)
        d.maxPixelsHigh = UInt32(height * 2)
        d.sizeInMillimeters = CGSize(width: Double(width) * 0.28, height: Double(height) * 0.28)
        d.vendorID = 0xCA57
        d.productID = UInt32(height)
        d.serialNum = 1
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

/// Puts the Mac display in the shape of the stream, and back.
///
/// A display already in that aspect ratio is left alone. Any other gets a virtual
/// display of the stream's size, which it mirrors; the stream is then captured from
/// the virtual display, so the picture always fills the TV at full resolution.
final class DisplayOptimizer {
    private var virtual: (display: VirtualDisplay, mirrored: CGDirectDisplayID, target: (Int, Int))?
    /// Virtual display waiting for macOS to accept the mirroring.
    private var pending: VirtualDisplay?
    private var generation = 0

    var virtualDisplayID: CGDirectDisplayID? { virtual?.display.displayID ?? pending?.displayID }

    /// Calls `completion` on the main queue with the display to capture. Call from the main thread.
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

        guard let v = VirtualDisplay(width: target.0, height: target.1) else {
            completion(.failure(DisplayModeError.virtualDisplayFailed))
            return
        }
        let id = v.displayID
        pending = v
        let token = generation

        // A display created a moment ago is not always ready to be part of a mirror set
        // (CGCompleteDisplayConfiguration fails with 1001 in the app). Let the run loop
        // process its arrival and try again for up to 3 seconds.
        func attempt(_ n: Int) {
            guard token == generation, let v = pending else { return }  // restore() was called meanwhile
            do {
                if n == 1 {
                    // Prefer the HiDPI mode (sharper on the Mac's own panel).
                    let modes = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
                        as? [CGDisplayMode]) ?? []
                    if let mode = modes.filter({ $0.width == target.0 && $0.height == target.1 })
                        .max(by: { $0.pixelWidth < $1.pixelWidth }) {
                        try? setMode(id, mode)
                    }
                }
                try configure { CGConfigureDisplayMirrorOfDisplay($0, display, id) }
                pending = nil
                virtual = (v, display, target)
                log("display \(display): mirroring virtual display \(id) \(CGDisplayCopyDisplayMode(id).map(describe) ?? "?") (attempt \(n))")
                completion(.success(id))
            } catch {
                if n < 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt(n + 1) }
                } else {
                    log("display \(display): mirroring virtual display \(id) failed after \(n) attempts: \(error.localizedDescription)")
                    pending = nil
                    completion(.failure(error))
                }
            }
        }
        DispatchQueue.main.async { attempt(1) }
    }

    func restore() {
        generation += 1
        pending = nil
        guard let v = virtual else { return }
        virtual = nil
        do {
            try configure { CGConfigureDisplayMirrorOfDisplay($0, v.mirrored, kCGNullDirectDisplay) }
        } catch {
            log("unmirror failed: \(error.localizedDescription)")
        }
        log("display \(v.mirrored): virtual display removed")
        _ = v.display  // released here, which removes it from the system
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
